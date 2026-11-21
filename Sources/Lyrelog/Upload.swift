import Foundation
import os

/// What to do with a batch after a request. Decided by a pure function so it can be tested.
enum UploadOutcome: Equatable, Sendable {
    /// Stored. `rejected` lines were invalid and are gone for good (never resend them).
    case delivered(rejected: Int)
    /// Temporary problem: keep the batch and try again later.
    case retry(after: TimeInterval?)
    /// The batch itself is wrong (400, 413, 415...): resending would fail the same way.
    case drop(status: Int)
    /// The key is unknown or revoked: stop sending until the next launch, keep the data.
    case unauthorized
}

enum ResponseClassifier {
    static func classify(status: Int, body: Data, retryAfter: String?, now: Date = Date()) -> UploadOutcome {
        switch status {
        case 200..<300:
            struct Answer: Decodable {
                let accepted: Int
                let rejected: [Rejected]
                struct Rejected: Decodable { let line: Int }
            }
            // A 2xx we can't read may not mean "stored": retry; the server drops duplicates.
            guard let answer = try? JSONDecoder().decode(Answer.self, from: body) else {
                return .retry(after: nil)
            }
            return .delivered(rejected: answer.rejected.count)
        case 401, 403:
            return .unauthorized
        case 408, 425, 429, 500, 502, 503, 504:
            return .retry(after: parseRetryAfter(retryAfter, now: now))
        default:
            return status >= 500 ? .retry(after: parseRetryAfter(retryAfter, now: now)) : .drop(status: status)
        }
    }

    /// The server's words when a 429 is the organization's monthly quota, not the rate limit:
    /// the quota answer is a JSON object with `plan` and `limit` (and the `error` text), the rate
    /// limit's only has `error`. Anything else, JSON or not, is a plain 429 (nil).
    static func quotaMessage(status: Int, body: Data) -> String? {
        guard status == 429,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["plan"] != nil, object["limit"] != nil else { return nil }
        let text = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = text.isEmpty ? "this organization's monthly events are used" : text
        return error.hasSuffix(".") ? String(error.dropLast()) : error
    }

    /// The longest wait a `Retry-After` can ask for: an hour, the most the server ever sends.
    /// A proxy or a captive portal can answer anything ("1e30", "inf", a date years ahead);
    /// unbounded, it overflowed a `Duration` and trapped, or held sending until the next launch.
    static let maxRetryAfter: TimeInterval = 3600

    /// `Retry-After` is either seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds.isNaN || seconds < 0 ? nil : min(seconds, maxRetryAfter)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let wait = date.timeIntervalSince(now)
        return wait.isNaN ? nil : min(max(0, wait), maxRetryAfter)
    }
}

enum Backoff {
    static let base: TimeInterval = 1
    static let cap: TimeInterval = 300

    /// Full jitter: uniform(0, min(cap, base * 2^attempt)), but never sooner than the server asked.
    static func delay(attempt: Int, retryAfter: TimeInterval?, random: (ClosedRange<Double>) -> Double = { .random(in: $0) }) -> TimeInterval {
        let ceiling = min(cap, base * pow(2, Double(min(attempt, 16))))
        let jitter = random(0...ceiling)
        return max(jitter, retryAfter ?? 0)
    }
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Release the connection pool (the SDK stopped).
    func invalidate()
}

extension HTTPTransport {
    func invalidate() {}
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    /// URLSession raises an Objective-C exception (no Swift code can catch it: the app dies)
    /// when a task is made after `invalidateAndCancel()`, and a round or an App Attest refresh
    /// can still be running when the SDK stops. Making a task and invalidating take this lock,
    /// so after `invalidate()` a send throws instead.
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // Low Data Mode and expensive (cellular) networks are allowed: batches are small and
        // gzipped, and holding them would only grow the queue.
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let running = OSAllocatedUnfairLock<(task: URLSessionDataTask?, cancelled: Bool)>(initialState: (nil, false))
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse?), any Error>) in
                let task = invalidated.withLockUnchecked { gone -> URLSessionDataTask? in
                    guard !gone else { return nil }
                    return session.dataTask(with: request) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: (data ?? Data(), response))
                        }
                    }
                }
                guard let task else {
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                let cancelled = running.withLockUnchecked { state in
                    state.task = task
                    return state.cancelled
                }
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            let task = running.withLockUnchecked { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func invalidate() {
        invalidated.withLockUnchecked { gone in
            gone = true
            session.invalidateAndCancel()
        }
    }
}

/// An upload never follows a redirect: the body and the key would go to another host. The 3xx
/// comes back as the answer, and the batch is dropped with a warning.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Whether the person agreed to send, read by the writer, the uploader and the install id at
/// the moment they act, so a change applies at once and can never be lost in a queue.
final class ConsentGate: Sendable {
    private let state: OSAllocatedUnfairLock<Consent>

    init(_ consent: Consent) {
        state = OSAllocatedUnfairLock(initialState: consent)
    }

    var value: Consent {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Sends sealed batches one at a time, oldest first. One round runs at a time: a periodic round
/// skips while another runs, a forced one (flush, background) waits for it and runs after.
///
/// A retryable failure stops the round and sets a backoff (1 s doubling to 5 min, full jitter).
/// A forced round ignores that backoff, never the server's `Retry-After`. A batch that keeps
/// failing goes to the back after `moveBackAfter` tries, so it can't hold the others, and is
/// dropped (counted) after `dropAfter` failures in rounds where other batches went through.
actor Uploader {
    struct Report: Equatable, Sendable {
        var delivered = 0
        var dropped = 0
        var stoppedForRetry = false
    }

    static let moveBackAfter = 3
    static let dropAfter = 5

    private let endpoint: URL?
    private let apiKey: String
    private let transport: any HTTPTransport
    private let queue: DiskQueue
    private let consent: ConsentGate
    private let clock = ContinuousClock()
    /// Failed attempts in a row, for the backoff. The monthly quota's 429 is not one: it waits
    /// for its `Retry-After` only (sdk-spec rule 4).
    private(set) var attempt = 0
    /// Failed uploads in a row (the quota's 429 aside), and whether the developer was told the
    /// uploads keep failing: once after `warnAfterFailures`, again only after a delivery.
    private var consecutiveFailures = 0
    private var failingWarned = false
    /// How many "uploads keep failing" warnings were logged (tests).
    private(set) var failingWarnings = 0
    static let warnAfterFailures = 3
    /// Our own backoff, skipped by a forced round.
    private var backoffUntil: ContinuousClock.Instant?
    /// What the server asked for (`Retry-After`), always respected.
    private var serverWaitUntil: ContinuousClock.Instant?
    private var running: Task<Report, Never>?
    /// Per batch file: failures, and failures while other batches were delivered.
    private var failures: [String: Int] = [:]
    private var strikes: [String: Int] = [:]
    private(set) var disabled = false
    /// Whether the developer was told the monthly quota is used up; a delivered batch clears
    /// it, so the next quota stop is told again.
    private var quotaWarned = false
    /// How many quota warnings were logged (tests).
    private(set) var quotaWarnings = 0
    private let jitter: @Sendable (ClosedRange<Double>) -> Double
    /// App Attest's token for `X-Lyrelog-Attestation`, when it's on. Asked at each send, never
    /// waited for.
    private let attestation: Attestation?

    /// `endpoint` is the ingest origin; nil (refused, see `Configuration.ingestURL`) keeps the
    /// data and never sends.
    init(endpoint: URL?, apiKey: String, transport: any HTTPTransport, queue: DiskQueue,
         consent: ConsentGate = ConsentGate(.granted), attestation: Attestation? = nil,
         jitter: @escaping @Sendable (ClosedRange<Double>) -> Double = { .random(in: $0) }) {
        self.jitter = jitter
        self.attestation = attestation
        self.endpoint = endpoint.map { $0.appendingPathComponent("v1/events:batch") }
        self.apiKey = apiKey
        self.transport = transport
        self.queue = queue
        self.consent = consent
        if endpoint == nil { disabled = true }
    }

    /// Whether a round started now would send anything (so the open file is worth sealing).
    func willAttempt(force: Bool) -> Bool {
        guard !disabled, consent.value == .granted else { return false }
        if let serverWaitUntil, clock.now < serverWaitUntil { return false }
        if !force, let backoffUntil, clock.now < backoffUntil { return false }
        return true
    }

    @discardableResult
    func uploadReady(force: Bool) async -> Report {
        while let current = running {
            guard force else { return Report() }
            _ = await current.value
            // The finished round may not have cleared itself yet when we resume first.
            if running == current { running = nil }
        }
        guard willAttempt(force: force) else { return Report() }
        let round = Task {
            let report = await self.round()
            self.running = nil
            return report
        }
        running = round
        return await round.value
    }

    private func round() async -> Report {
        var report = Report()
        let batches = await queue.readyBatches().enumerated().sorted { a, b in
            let backA = failures[a.element.lastPathComponent, default: 0] >= Self.moveBackAfter
            let backB = failures[b.element.lastPathComponent, default: 0] >= Self.moveBackAfter
            return backA == backB ? a.offset < b.offset : !backA
        }.map(\.element)

        for batch in batches {
            guard !disabled, consent.value == .granted else { break }
            let name = batch.lastPathComponent
            guard let body = await queue.contents(of: batch), !body.isEmpty else {
                await queue.remove(batch)
                continue
            }
            let (outcome, status, quota) = await send(body)
            switch outcome {
            case .delivered(let rejected):
                await queue.remove(batch)
                forget(name)
                report.delivered += 1
                attempt = 0
                backoffUntil = nil
                quotaWarned = false
                consecutiveFailures = 0
                failingWarned = false
                if rejected > 0 {
                    SDKLog.once("rejected", "lyrelog: the server rejected \(rejected) line(s) of a batch; they are not resent (first time this launch)")
                }
            case .drop(let status):
                await queue.drop(batch)
                forget(name)
                report.dropped += 1
                warnAboutDrop(status: status)
            case .unauthorized:
                disabled = true
                SDKLog.once("unauthorized", "lyrelog: the ingest key was refused (\(status ?? 0)); nothing more is sent until the next launch, the data stays on the device")
                return report
            case .retry(let after):
                if let quota {
                    // Not a failure: the organization's month is used up. Wait for what the
                    // server asked, without growing the backoff or the failure count.
                    warnAboutQuota(quota)
                    if let after { serverWaitUntil = clock.now + .seconds(after) }
                    report.stoppedForRetry = true
                    return report
                }
                noteFailure()
                // A failure the server answered, other than rate limiting, may be this batch's fault.
                if let status, status != 429 {
                    failures[name, default: 0] += 1
                    if report.delivered > 0 {
                        strikes[name, default: 0] += 1
                        if strikes[name, default: 0] >= Self.dropAfter {
                            await queue.drop(batch)
                            forget(name)
                            report.dropped += 1
                            SDKLog.once("poison", "lyrelog: dropped a batch the server kept failing (\(status)) while others went through")
                        }
                    }
                }
                if let after { serverWaitUntil = clock.now + .seconds(after) }
                backoffUntil = clock.now + .seconds(Backoff.delay(attempt: attempt, retryAfter: after, random: jitter))
                attempt += 1
                report.stoppedForRetry = true
                return report
            }
        }
        return report
    }

    /// One warning when uploads keep failing (no network, the server unreachable or answering
    /// errors), through the SDK's own log, never the app's; silent again until a delivery.
    private func noteFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.warnAfterFailures, !failingWarned else { return }
        failingWarned = true
        failingWarnings += 1
        SDKLog.say("lyrelog: \(consecutiveFailures) uploads in a row failed (no network, or the server unreachable); events are kept on disk, up to \(Self.describeKeeping(queue.limits)), and sent when it answers again")
    }

    private func forget(_ name: String) {
        failures[name] = nil
        strikes[name] = nil
    }

    /// Once per quota stop (until a batch is accepted again). The retry itself is unchanged: the
    /// batch stays queued and waits for `Retry-After` like any 429.
    private func warnAboutQuota(_ error: String) {
        guard !quotaWarned else { return }
        quotaWarned = true
        quotaWarnings += 1
        SDKLog.say("Lyrelog: \(error). Events are kept and sent when sending resumes; how many wait depends on the platform (here: on disk, up to \(Self.describeKeeping(queue.limits))).")
    }

    /// "20 MB and 7 days" for the queue's caps.
    static func describeKeeping(_ limits: DiskQueue.Limits) -> String {
        let megabytes = Double(limits.maxTotalBytes) / 1_048_576
        let size = megabytes >= 1 ? "\(Int(megabytes.rounded())) MB" : "\(max(1, limits.maxTotalBytes / 1024)) KB"
        let days = limits.maxAge / 86_400
        let age: String
        if days >= 1 {
            let whole = Int(days.rounded())
            age = whole == 1 ? "1 day" : "\(whole) days"
        } else {
            let hours = max(1, Int((limits.maxAge / 3600).rounded()))
            age = hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(size) and \(age)"
    }

    private func warnAboutDrop(status: Int) {
        switch status {
        case 300..<400:
            SDKLog.once("redirect", "lyrelog: the endpoint answered \(status) (a redirect, not followed); the batch was dropped. Check Configuration.endpoint")
        case 404:
            SDKLog.once("404", "lyrelog: the endpoint answered 404; the batch was dropped. Configuration.endpoint should be the ingest origin, e.g. https://ingest.lyrelog.com")
        default:
            SDKLog.once("drop-\(status)", "lyrelog: the server refused a batch (\(status)); it was dropped")
        }
    }

    /// The outcome, the HTTP status when the server answered, and the server's words when it
    /// was the monthly quota.
    private func send(_ body: Data) async -> (UploadOutcome, Int?, String?) {
        guard let endpoint else { return (.unauthorized, nil, nil) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceContext.sdkVersion, forHTTPHeaderField: "User-Agent")
        // Without a token yet the batch goes as it is: its events are stored unverified.
        if let token = await attestation?.header() {
            request.setValue(token, forHTTPHeaderField: Attestation.headerName)
        }
        if let compressed = try? Gzip.compress(body) {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = compressed
        } else {
            request.httpBody = body
        }
        do {
            let (data, response) = try await transport.send(request)
            if response.value(forHTTPHeaderField: Attestation.headerName)?.lowercased() == "renew" {
                await attestation?.renew()
            }
            let outcome = ResponseClassifier.classify(status: response.statusCode, body: data,
                                                      retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            return (outcome, response.statusCode, ResponseClassifier.quotaMessage(status: response.statusCode, body: data))
        } catch {
            return (.retry(after: nil), nil, nil)
        }
    }
}
