import CryptoKit
import Foundation
import Security
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// What can go wrong with the device's App Attest key, as far as the logic cares.
enum AppAttestError: Error, Equatable, Sendable {
    /// The key is gone or unusable (already attested, unattested, deleted with the app): make another.
    case invalidKey
    /// Apple's service couldn't be reached: try again later with the same key.
    case serverUnavailable
    /// Not on this device.
    case unsupported
    case other
}

/// `DCAppAttestService`, behind a protocol so the logic is tested with a fake.
protocol AppAttestProvider: Sendable {
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// What survives launches: the key id Apple gave (the key itself is in the Secure Enclave),
/// whether the server accepted its attestation, and when it last refused one.
struct AttestRecord: Codable, Equatable, Sendable {
    var keyID: String?
    var attested = false
    var refusedAt: Date?
}

/// Where the record is kept (the Keychain), behind a protocol for tests. `load` throws when the
/// Keychain can't be read now (before the first unlock), which is not the same as empty.
protocol AttestKeyStore: Sendable {
    func load() throws -> AttestRecord?
    func save(_ record: AttestRecord)
    func delete()
}

/// Gets and keeps the App Attest token that batches carry in `X-Lyrelog-Attestation`, so the
/// server stores their events as verified.
///
/// It never holds a batch: `header()` answers at once with the token it has (or nil) and, when
/// one is missing, ending or refused, starts one background refresh. One refresh at a time;
/// failures wait (30 s doubling to an hour, or the server's `Retry-After`). A 404 from the
/// challenge (App Attest isn't set up for the project), a refused ingest key or a device that
/// can't attest turn it off until the next launch. Never logs the token, the key id or the
/// attestation.
actor Attestation {
    static let headerName = "X-Lyrelog-Attestation"
    /// Renew when less than this is left (or half the token's life, if shorter).
    static let renewBefore: TimeInterval = 3600
    /// After the server refuses an attestation, no new key for a day.
    static let refusalPause: TimeInterval = 86_400
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = 3600

    private struct Token {
        let value: String
        let expiresAt: Date
        let issuedAt: Date
    }

    private let challengeURL: URL
    private let keyURL: URL
    private let tokenURL: URL
    private let apiKey: String
    private let transport: any HTTPTransport
    private let provider: any AppAttestProvider
    private let store: any AttestKeyStore
    private let now: @Sendable () -> Date

    private var token: Token?
    private var renewRequested = false
    private(set) var disabled = false
    private var running: Task<Void, Never>?
    private var failures = 0
    private var waitUntil: Date?
    /// Refreshes started (tests).
    private(set) var refreshes = 0
    /// `forget()` ran while a refresh was in flight: undo what it saves when it ends.
    private var forgetWhenDone = false

    /// `origin` is the ingest origin, the same the batches go to.
    init(origin: URL, apiKey: String, transport: any HTTPTransport, provider: any AppAttestProvider,
         store: any AttestKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        challengeURL = origin.appendingPathComponent("v1/attest/challenge")
        keyURL = origin.appendingPathComponent("v1/attest/key")
        tokenURL = origin.appendingPathComponent("v1/attest/token")
        self.apiKey = apiKey
        self.transport = transport
        self.provider = provider
        self.store = store
        self.now = now
    }

    /// The token for the next batch, or nil (the batch then goes without it). Starts a
    /// background refresh when it's needed; never waits for one.
    func header() -> String? {
        startIfNeeded()
        guard let token, token.expiresAt > now() else { return nil }
        return token.value
    }

    /// Starts a refresh if one is needed, without waiting (at launch).
    func prepare() {
        startIfNeeded()
    }

    /// A batch answer said `X-Lyrelog-Attestation: renew`: the token wasn't accepted. Batches
    /// go without one until a new one arrives.
    func renew() {
        guard !disabled else { return }
        if let token, now().timeIntervalSince(token.issuedAt) < 300 {
            // A token just issued and already refused: don't ask for one per batch.
            noteFailure(retryAfter: nil)
        }
        token = nil
        renewRequested = true
        startIfNeeded()
    }

    /// Consent was denied: forget the key and the token (a new key is made after a grant).
    func forget() {
        if let running {
            running.cancel()
            forgetWhenDone = true
        }
        token = nil
        renewRequested = false
        store.delete()
    }

    /// Returns once the refresh in flight, if any, has finished (tests).
    func idle() async {
        while let current = running { await current.value }
    }

    private var needsRefresh: Bool {
        guard !disabled, running == nil else { return false }
        if let waitUntil, now() < waitUntil { return false }
        guard let token else { return true }
        if renewRequested { return true }
        let left = token.expiresAt.timeIntervalSince(now())
        let life = token.expiresAt.timeIntervalSince(token.issuedAt)
        return left < min(Self.renewBefore, life / 2)
    }

    private func startIfNeeded() {
        guard needsRefresh else { return }
        refreshes += 1
        running = Task(priority: .utility) {
            let result = await self.obtain()
            self.finish(result)
        }
    }

    private enum Result {
        case token(String, expiresAt: Date)
        case disable(String)
        case retry(after: TimeInterval?)
    }

    private func finish(_ result: Result) {
        running = nil
        if forgetWhenDone {
            forgetWhenDone = false
            store.delete()
            return
        }
        switch result {
        case .token(let value, let expiresAt):
            token = Token(value: value, expiresAt: expiresAt, issuedAt: now())
            renewRequested = false
            failures = 0
            waitUntil = nil
        case .disable(let reason):
            disabled = true
            token = nil
            SDKLog.once("app-attest-off", "lyrelog: App Attest is off for this launch (\(reason)); events are stored unverified")
        case .retry(let after):
            noteFailure(retryAfter: after)
        }
    }

    private func noteFailure(retryAfter: TimeInterval?) {
        let doubling = min(Self.backoffCap, Self.backoffBase * pow(2, Double(min(failures, 16))))
        failures += 1
        waitUntil = now().addingTimeInterval(max(doubling, retryAfter ?? 0))
    }

    // MARK: - The exchange

    private func obtain() async -> Result {
        var record: AttestRecord
        do {
            record = try store.load() ?? AttestRecord()
        } catch {
            return .retry(after: nil) // the Keychain is locked (before the first unlock)
        }
        // Re-attesting (a key the server doesn't know, or Apple calls invalid) happens at most
        // once per refresh.
        for _ in 0..<2 {
            if Task.isCancelled { return .retry(after: nil) }
            if record.keyID == nil || !record.attested,
               let refusedAt = record.refusedAt, now().timeIntervalSince(refusedAt) < Self.refusalPause {
                return .retry(after: Self.refusalPause - now().timeIntervalSince(refusedAt))
            }
            let challenge: String
            switch await fetchChallenge() {
            case .success(let value): challenge = value
            case .failure(let result): return result
            }
            let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))

            if let keyID = record.keyID, record.attested {
                let assertion: Data
                do {
                    assertion = try await provider.generateAssertion(keyID, clientDataHash: clientDataHash)
                } catch let error as AppAttestError where error == .invalidKey {
                    record = forgetKey(record, refused: false)
                    continue
                } catch let error as AppAttestError where error == .unsupported {
                    return .disable("not supported on this device")
                } catch {
                    return .retry(after: nil)
                }
                let answer = await post(tokenURL, ["key_id": keyID, "assertion": assertion.base64EncodedString(),
                                                   "challenge": challenge])
                switch answer {
                case .ok(let data):
                    return Self.token(from: data).map { .token($0.0, expiresAt: $0.1) } ?? .retry(after: nil)
                case .unknown:
                    record = forgetKey(record, refused: false) // attest a new key
                    continue
                case .refused:
                    record = forgetKey(record, refused: true)
                    return .retry(after: nil)
                case .unauthorized(let status):
                    return .disable("the server answered \(status)")
                case .retry(let after):
                    return .retry(after: after)
                }
            } else {
                let keyID: String
                if let saved = record.keyID {
                    keyID = saved
                } else {
                    do {
                        keyID = try await provider.generateKey()
                    } catch let error as AppAttestError where error == .unsupported {
                        return .disable("not supported on this device")
                    } catch {
                        return .retry(after: nil)
                    }
                    record.keyID = keyID
                    record.attested = false
                    store.save(record)
                }
                let attestation: Data
                do {
                    attestation = try await provider.attestKey(keyID, clientDataHash: clientDataHash)
                } catch let error as AppAttestError where error == .invalidKey {
                    record = forgetKey(record, refused: false)
                    return .retry(after: nil)
                } catch let error as AppAttestError where error == .unsupported {
                    return .disable("not supported on this device")
                } catch {
                    return .retry(after: nil) // Apple's service: the same key again later
                }
                let answer = await post(keyURL, ["key_id": keyID, "attestation": attestation.base64EncodedString(),
                                                 "challenge": challenge])
                switch answer {
                case .ok(let data):
                    guard let (value, expiresAt) = Self.token(from: data) else {
                        // Attested by Apple, but the answer is unreadable: Apple won't attest
                        // this key twice, so the next try starts with a new one.
                        _ = forgetKey(record, refused: false)
                        return .retry(after: nil)
                    }
                    record.attested = true
                    record.refusedAt = nil
                    store.save(record)
                    return .token(value, expiresAt: expiresAt)
                case .refused:
                    _ = forgetKey(record, refused: true)
                    return .retry(after: nil)
                case .unknown:
                    return .disable("not set up for this project")
                case .unauthorized(let status):
                    return .disable("the server answered \(status)")
                case .retry(let after):
                    // Apple won't attest this key twice: the next try makes a new one.
                    _ = forgetKey(record, refused: false)
                    return .retry(after: after)
                }
            }
        }
        return .retry(after: nil)
    }

    private func forgetKey(_ record: AttestRecord, refused: Bool) -> AttestRecord {
        let fresh = AttestRecord(keyID: nil, attested: false, refusedAt: refused ? now() : record.refusedAt)
        if fresh.refusedAt == nil { store.delete() } else { store.save(fresh) }
        return fresh
    }

    private enum ChallengeOutcome {
        case success(String)
        case failure(Result)
    }

    private func fetchChallenge() async -> ChallengeOutcome {
        switch await post(challengeURL, [:]) {
        case .ok(let data):
            struct Body: Decodable { let challenge: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: data), !body.challenge.isEmpty else {
                return .failure(.retry(after: nil))
            }
            return .success(body.challenge)
        case .unknown:
            return .failure(.disable("not set up for this project"))
        case .unauthorized(let status):
            return .failure(.disable("the server answered \(status)"))
        case .refused:
            return .failure(.disable("the server answered 400"))
        case .retry(let after):
            return .failure(.retry(after: after))
        }
    }

    private static func token(from data: Data) -> (String, Date)? {
        struct Body: Decodable {
            let token: String
            let expires_at: Double
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), !body.token.isEmpty else { return nil }
        return (body.token, Date(timeIntervalSince1970: body.expires_at))
    }

    private enum Answer {
        case ok(Data)
        /// 400: the attestation or assertion was refused.
        case refused
        /// 404: not set up (challenge, key) or an unknown key (token).
        case unknown
        /// 401, 403, a redirect or another 4xx: it would fail the same way all launch.
        case unauthorized(Int)
        /// 408, 425, 429, 5xx, a network error.
        case retry(TimeInterval?)
    }

    private func post(_ url: URL, _ body: [String: String]) async -> Answer {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceContext.sdkVersion, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            let (data, response) = try await transport.send(request)
            let retryAfter = ResponseClassifier.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            switch response.statusCode {
            case 200..<300: return .ok(data)
            case 400: return .refused
            case 404: return .unknown
            case 408, 425, 429, 500...: return .retry(retryAfter)
            default: return .unauthorized(response.statusCode)
            }
        } catch {
            return .retry(nil)
        }
    }
}

// MARK: - The system's pieces

extension Attestation {
    /// The real App Attest, or nil where it can't work: no DeviceCheck, `isSupported` false (Macs,
    /// the simulator, some devices), or an app extension (only watchOS extensions can attest).
    static func system(origin: URL, apiKey: String, transport: any HTTPTransport) -> Attestation? {
        #if canImport(DeviceCheck)
        guard DCAppAttestService.shared.isSupported else {
            SDKLog.once("app-attest-unsupported", "lyrelog: App Attest isn't supported here (a Mac, the simulator or an older device); events are stored unverified")
            return nil
        }
        #if !os(watchOS)
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            SDKLog.once("app-attest-extension", "lyrelog: App Attest isn't available in app extensions; events are stored unverified")
            return nil
        }
        #endif
        return Attestation(origin: origin, apiKey: apiKey, transport: transport,
                           provider: SystemAppAttest(), store: KeychainAttestStore())
        #else
        return nil
        #endif
    }
}

#if canImport(DeviceCheck)
struct SystemAppAttest: AppAttestProvider {
    func generateKey() async throws -> String {
        do { return try await DCAppAttestService.shared.generateKey() } catch { throw Self.map(error) }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        } catch {
            throw Self.map(error)
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> AppAttestError {
        guard let error = error as? DCError else { return .other }
        switch error.code {
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .serverUnavailable
        case .featureUnsupported: return .unsupported
        default: return .other
        }
    }
}
#endif

/// The record as one generic password, this device only, readable after the first unlock.
struct KeychainAttestStore: AttestKeyStore {
    struct Locked: Error {}

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lyrelog.sdk.app-attest",
            kSecAttrAccount as String: "key",
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    func load() throws -> AttestRecord? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try? JSONDecoder().decode(AttestRecord.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Locked()
        }
    }

    func save(_ record: AttestRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
