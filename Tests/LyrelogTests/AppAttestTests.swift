import CryptoKit
import Foundation
import Testing
@testable import Lyrelog

// MARK: - Fakes

/// Answers by path (`/v1/attest/challenge`, `/v1/events:batch`...), records every request, and
/// can hold the requests to one path until `open()`.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    typealias Reply = (Int, String, [String: String])
    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var fallback: [String: Reply] = [:]
    private(set) var requests: [URLRequest] = []
    private var heldPath: String?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(hold path: String? = nil) { heldPath = path }

    /// Answers to `path` in order; the last one repeats.
    func route(_ path: String, _ replies: Reply...) {
        lock.withLock {
            routes[path] = Array(replies.dropLast())
            fallback[path] = replies.last
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let hold = lock.withLock { () -> Bool in
            requests.append(request)
            return heldPath == path
        }
        if hold {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    guard heldPath == path else { return true }
                    held.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
        let reply: Reply? = lock.withLock {
            if var queued = routes[path], !queued.isEmpty {
                let first = queued.removeFirst()
                routes[path] = queued
                return first
            }
            return fallback[path]
        }
        guard let (status, body, headers) = reply else { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            heldPath = nil
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func requests(to path: String) -> [URLRequest] { lock.withLock { requests.filter { $0.url?.path == path } } }

    func json(_ request: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
    }
}

/// App Attest without the Secure Enclave: scripted errors, counts, and a gate on `generateKey`.
final class FakeAppAttest: AppAttestProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var keys = 0
    private(set) var generated = 0
    private(set) var attested: [(keyID: String, hash: Data)] = []
    private(set) var asserted: [(keyID: String, hash: Data)] = []
    var assertionErrors: [AppAttestError] = []
    var attestErrors: [AppAttestError] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var gated: Bool

    init(gated: Bool = false) { self.gated = gated }

    func generateKey() async throws -> String {
        if lock.withLock({ gated }) {
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
        }
        return lock.withLock {
            keys += 1
            generated += 1
            return "key+\(keys)/=="
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            attested.append((keyID, clientDataHash))
            if !attestErrors.isEmpty { throw attestErrors.removeFirst() }
            return Data("attestation-of-\(keyID)".utf8)
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            asserted.append((keyID, clientDataHash))
            if !assertionErrors.isEmpty { throw assertionErrors.removeFirst() }
            return Data("assertion-by-\(keyID)".utf8)
        }
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            gated = false
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    var counts: (generated: Int, attested: Int, asserted: Int) {
        lock.withLock { (generated, attested.count, asserted.count) }
    }
}

final class MemoryAttestStore: AttestKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: AttestRecord?
    init(_ record: AttestRecord? = nil) { self.record = record }
    func load() throws -> AttestRecord? { lock.withLock { record } }
    func save(_ record: AttestRecord) { lock.withLock { self.record = record } }
    func delete() { lock.withLock { record = nil } }
    var current: AttestRecord? { lock.withLock { record } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

// MARK: - Tests

struct AppAttestTests {
    static let challenge = "/v1/attest/challenge"
    static let key = "/v1/attest/key"
    static let token = "/v1/attest/token"
    static let batch = "/v1/events:batch"

    let origin = URL(string: "https://ingest.test")!
    let clock = TestClock()

    func challengeReply(_ value: String = "c-1") -> RoutingTransport.Reply {
        (200, #"{"challenge":"\#(value)"}"#, ["Content-Type": "application/json"])
    }

    func tokenReply(_ value: String, expiresIn: TimeInterval = 86_400) -> RoutingTransport.Reply {
        (200, #"{"token":"\#(value)","expires_at":\#(Int(clock.now.timeIntervalSince1970 + expiresIn))}"#, [:])
    }

    func setup(_ transport: RoutingTransport, provider: FakeAppAttest = FakeAppAttest(),
               store: MemoryAttestStore = MemoryAttestStore()) async -> (Uploader, Attestation, DiskQueue) {
        let clock = self.clock
        let attestation = Attestation(origin: origin, apiKey: "lyr_ing_x", transport: transport, provider: provider,
                                      store: store, now: { clock.now })
        let queue = makeQueue()
        let uploader = Uploader(endpoint: origin, apiKey: "lyr_ing_x", transport: transport, queue: queue,
                                attestation: attestation, jitter: { $0.upperBound })
        return (uploader, attestation, queue)
    }

    func send(_ uploader: Uploader, _ queue: DiskQueue) async -> Uploader.Report {
        await queue.append(Data(#"{"n":1}"#.utf8), to: .ready)
        await queue.seal()
        return await uploader.uploadReady(force: true)
    }

    func header(_ request: URLRequest?) -> String? { request?.value(forHTTPHeaderField: Attestation.headerName) }

    @Test func withoutATokenTheBatchGoesWithoutTheHeader() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply())
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest(gated: true) // the key never comes
        let (uploader, attestation, queue) = await setup(transport, provider: provider)
        let report = await send(uploader, queue)
        #expect(report.delivered == 1)
        #expect(header(transport.requests(to: Self.batch).first) == nil)
        provider.release()
        await attestation.idle()
    }

    @Test func nothingEverWaitsForAttestation() async throws {
        // The challenge request hangs: batches still go, one after another.
        let transport = RoutingTransport(hold: Self.challenge)
        transport.route(Self.batch, ok)
        let (uploader, attestation, queue) = await setup(transport)
        for _ in 0..<3 { #expect(await send(uploader, queue).delivered == 1) }
        #expect(transport.requests(to: Self.batch).count == 3)
        #expect(transport.requests(to: Self.challenge).count == 1) // one in flight, never more
        transport.open()
        await attestation.idle()
    }

    @Test func afterAttestationEveryBatchCarriesTheToken() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply("chal-A"))
        transport.route(Self.key, tokenReply("tok-1"))
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest()
        let store = MemoryAttestStore()
        let (uploader, attestation, queue) = await setup(transport, provider: provider, store: store)

        _ = await send(uploader, queue)
        await attestation.idle()
        _ = await send(uploader, queue)
        let batches = transport.requests(to: Self.batch)
        #expect(header(batches.first) == nil)
        #expect(header(batches.last) == "tok-1")

        let keyRequest = try #require(transport.requests(to: Self.key).first)
        let body = transport.json(keyRequest)
        #expect(body["key_id"] == "key+1/==") // exactly Apple's string
        #expect(body["challenge"] == "chal-A")
        #expect(body["attestation"] == Data("attestation-of-key+1/==".utf8).base64EncodedString())
        #expect(keyRequest.value(forHTTPHeaderField: "Authorization") == "Bearer lyr_ing_x")
        #expect(keyRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(transport.json(try #require(transport.requests(to: Self.challenge).first)).isEmpty)
        #expect(provider.attested.first?.hash == Data(SHA256.hash(data: Data("chal-A".utf8))))
        #expect(store.current == AttestRecord(keyID: "key+1/==", attested: true, refusedAt: nil))
        // Nothing the SDK said carries the token or the key id.
        #expect(SDKLog.recent.allSatisfy { !$0.contains("tok-1") && !$0.contains("key+1") })
    }

    @Test func renewAsksForANewTokenWithAnAssertion() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply("c-1"), challengeReply("c-2"))
        transport.route(Self.key, tokenReply("tok-1"))
        transport.route(Self.token, tokenReply("tok-2"))
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest()
        let (uploader, attestation, queue) = await setup(transport, provider: provider)
        _ = await send(uploader, queue)
        await attestation.idle()

        clock.advance(600) // the token isn't brand new: renew at once, no backoff
        transport.route(Self.batch, (200, #"{"accepted":1,"rejected":[]}"#, [Attestation.headerName: "renew"]), ok)
        _ = await send(uploader, queue) // sent with tok-1, answered "renew"
        await attestation.idle()
        _ = await send(uploader, queue)

        #expect(provider.counts.generated == 1 && provider.counts.asserted == 1)
        let tokenBody = transport.json(try #require(transport.requests(to: Self.token).first))
        #expect(tokenBody["key_id"] == "key+1/==")
        #expect(tokenBody["challenge"] == "c-2")
        #expect(tokenBody["assertion"] == Data("assertion-by-key+1/==".utf8).base64EncodedString())
        #expect(provider.asserted.first?.hash == Data(SHA256.hash(data: Data("c-2".utf8))))
        #expect(transport.requests(to: Self.batch).map(header) == [nil, "tok-1", "tok-2"])
    }

    @Test func renewsWhenLessThanAnHourIsLeft() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply())
        transport.route(Self.key, tokenReply("tok-1", expiresIn: 4 * 3600))
        transport.route(Self.token, tokenReply("tok-2", expiresIn: 4 * 3600))
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest()
        let (uploader, attestation, queue) = await setup(transport, provider: provider)
        _ = await send(uploader, queue)
        await attestation.idle()
        clock.advance(2 * 3600)
        _ = await send(uploader, queue)
        await attestation.idle()
        #expect(provider.counts.asserted == 0) // two hours left: no renewal
        clock.advance(3600 + 60)
        _ = await send(uploader, queue) // still tok-1 (59 min left), renewal starts
        await attestation.idle()
        _ = await send(uploader, queue)
        #expect(provider.counts.asserted == 1)
        #expect(transport.requests(to: Self.batch).map(header) == [nil, "tok-1", "tok-1", "tok-2"])
    }

    @Test func aChallenge404TurnsItOffForTheLaunch() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, (404, #"{"error":"app attest is not set up"}"#, [:]))
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest()
        let (uploader, attestation, queue) = await setup(transport, provider: provider)
        _ = await send(uploader, queue)
        await attestation.idle()
        clock.advance(7200)
        for _ in 0..<3 { _ = await send(uploader, queue) }
        await attestation.idle()
        #expect(await attestation.disabled)
        #expect(transport.requests(to: Self.challenge).count == 1)
        #expect(provider.counts.generated == 0)
        #expect(transport.requests(to: Self.batch).allSatisfy { header($0) == nil })
        #expect(transport.requests(to: Self.batch).count == 4)
    }

    @Test func aRefusedAttestationForgetsTheKeyAndWaitsADay() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply())
        transport.route(Self.key, (400, #"{"error":"attestation refused"}"#, [:]), tokenReply("tok-1", expiresIn: 3 * 86_400))
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest()
        let store = MemoryAttestStore()
        let (uploader, attestation, queue) = await setup(transport, provider: provider, store: store)
        _ = await send(uploader, queue)
        await attestation.idle()
        #expect(store.current?.keyID == nil)
        #expect(store.current?.refusedAt == clock.now)

        clock.advance(12 * 3600) // within the day: no new key, not even a challenge
        _ = await send(uploader, queue)
        await attestation.idle()
        #expect(provider.counts.generated == 1)
        #expect(transport.requests(to: Self.challenge).count == 1)

        clock.advance(12 * 3600 + 1)
        _ = await send(uploader, queue)
        await attestation.idle()
        #expect(provider.counts.generated == 2)
        #expect(provider.attested.last?.keyID == "key+2/==")
        #expect(store.current == AttestRecord(keyID: "key+2/==", attested: true, refusedAt: nil))
        _ = await send(uploader, queue)
        #expect(header(transport.requests(to: Self.batch).last) == "tok-1")
    }

    @Test func anUnknownKeyIsAttestedAgain() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply("c-1"), challengeReply("c-2"))
        transport.route(Self.token, (404, #"{"error":"unknown key"}"#, [:]))
        transport.route(Self.key, tokenReply("tok-new"))
        transport.route(Self.batch, ok)
        let provider = FakeAppAttest()
        let store = MemoryAttestStore(AttestRecord(keyID: "old-key", attested: true))
        let (uploader, attestation, queue) = await setup(transport, provider: provider, store: store)
        await attestation.prepare()
        await attestation.idle()
        _ = await send(uploader, queue)
        #expect(provider.asserted.map(\.keyID) == ["old-key"])
        #expect(provider.counts.generated == 1)
        #expect(transport.json(try #require(transport.requests(to: Self.key).first))["challenge"] == "c-2")
        #expect(store.current == AttestRecord(keyID: "key+1/==", attested: true, refusedAt: nil))
        #expect(header(transport.requests(to: Self.batch).last) == "tok-new")
    }

    @Test func anInvalidKeyFromAppleIsReplaced() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply())
        transport.route(Self.key, tokenReply("tok-new"))
        let provider = FakeAppAttest()
        provider.assertionErrors = [.invalidKey] // e.g. the app was reinstalled, the Keychain kept the id
        let store = MemoryAttestStore(AttestRecord(keyID: "gone", attested: true))
        let (_, attestation, _) = await setup(transport, provider: provider, store: store)
        await attestation.prepare()
        await attestation.idle()
        #expect(provider.counts.generated == 1)
        #expect(transport.requests(to: Self.token).isEmpty)
        #expect(await attestation.header() == "tok-new")
    }

    @Test func aRefusedAssertionForgetsTheKey() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply())
        transport.route(Self.token, (400, #"{"error":"assertion refused"}"#, [:]))
        let provider = FakeAppAttest()
        let store = MemoryAttestStore(AttestRecord(keyID: "k", attested: true))
        let (_, attestation, _) = await setup(transport, provider: provider, store: store)
        await attestation.prepare()
        await attestation.idle()
        #expect(store.current == AttestRecord(keyID: nil, attested: false, refusedAt: clock.now))
        #expect(await attestation.header() == nil)
    }

    @Test func serverTroubleBacksOffAndKeepsOneInFlight() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, (503, "", [:]), (429, "", ["Retry-After": "600"]), challengeReply())
        transport.route(Self.token, tokenReply("tok"))
        let provider = FakeAppAttest()
        let store = MemoryAttestStore(AttestRecord(keyID: "k", attested: true))
        let (_, attestation, _) = await setup(transport, provider: provider, store: store)
        await attestation.prepare()
        await attestation.idle()
        #expect(await attestation.header() == nil)
        await attestation.idle()
        #expect(transport.requests(to: Self.challenge).count == 1) // inside the 30 s wait
        clock.advance(31)
        _ = await attestation.header()
        await attestation.idle()
        #expect(transport.requests(to: Self.challenge).count == 2) // 429, Retry-After 600
        clock.advance(300)
        _ = await attestation.header()
        await attestation.idle()
        #expect(transport.requests(to: Self.challenge).count == 2)
        clock.advance(301)
        _ = await attestation.header()
        await attestation.idle()
        #expect(await attestation.header() == "tok")
        #expect(store.current?.keyID == "k") // a network problem never costs the key
    }

    @Test func aDenialForgetsTheKey() async throws {
        let transport = RoutingTransport()
        transport.route(Self.challenge, challengeReply())
        transport.route(Self.key, tokenReply("tok"))
        let store = MemoryAttestStore()
        let (_, attestation, _) = await setup(transport, store: store)
        await attestation.prepare()
        await attestation.idle()
        #expect(store.current?.keyID != nil)
        await attestation.forget()
        #expect(store.current == nil)
    }

    @Test func theEngineFlushesWhileAttestationHangs() async throws {
        let transport = RoutingTransport(hold: Self.challenge)
        transport.route(Self.batch, ok)
        let attestation = Attestation(origin: origin, apiKey: "k", transport: transport, provider: FakeAppAttest(),
                                      store: MemoryAttestStore())
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: temporaryDirectory(),
                            resolveEnvironment: nil, attestation: attestation)
        engine.enqueue(event("one"))
        await engine.flush()
        #expect(transport.requests(to: Self.batch).count == 1)
        #expect(header(transport.requests(to: Self.batch).first) == nil)
        engine.stop()
        transport.open()
        await attestation.idle()
    }

    @Test func offWhenConfiguredOffOrUnsupported() {
        #expect(Configuration(apiKey: "k").appAttest)
        // `swift test` runs on a Mac, where App Attest isn't supported: the engine runs without it.
        #expect(Attestation.system(origin: origin, apiKey: "k", transport: RoutingTransport()) == nil)
    }
}
