import Foundation
import Testing
@testable import Lyrelog

/// A transport that answers from a script and records what it was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String, [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(Int, String, [String: String])]) { self.answers = answers }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: (Int, String, [String: String])? = lock.withLock {
            requests.append(request)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        guard let (status, body, headers) = answer else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }

    var count: Int { lock.withLock { requests.count } }
}

let ok = (200, #"{"accepted":1,"rejected":[]}"#, [String: String]())

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrelog-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeQueue(maxFileEvents: Int = 100, maxTotalBytes: Int = 1_000_000, root: URL = temporaryDirectory()) -> DiskQueue {
    DiskQueue(root: root, limits: .init(maxFileBytes: 64 * 1024, maxFileEvents: maxFileEvents,
                                        maxTotalBytes: maxTotalBytes, maxAge: 3600))
}

struct ClassifierTests {
    @Test func responsesMapToOutcomes() {
        #expect(ResponseClassifier.classify(status: 200, body: Data(#"{"accepted":2,"rejected":[{"line":3}]}"#.utf8), retryAfter: nil) == .delivered(rejected: 1))
        #expect(ResponseClassifier.classify(status: 200, body: Data("garbage".utf8), retryAfter: nil) == .retry(after: nil))
        #expect(ResponseClassifier.classify(status: 429, body: Data(), retryAfter: "7") == .retry(after: 7))
        #expect(ResponseClassifier.classify(status: 503, body: Data(), retryAfter: nil) == .retry(after: nil))
        #expect(ResponseClassifier.classify(status: 507, body: Data(), retryAfter: nil) == .retry(after: nil))
        #expect(ResponseClassifier.classify(status: 401, body: Data(), retryAfter: nil) == .unauthorized)
        #expect(ResponseClassifier.classify(status: 400, body: Data(), retryAfter: nil) == .drop(status: 400))
        #expect(ResponseClassifier.classify(status: 413, body: Data(), retryAfter: nil) == .drop(status: 413))
    }

    @Test func retryAfterAcceptsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_000_000_000) // Sun, 09 Sep 2001 01:46:40 GMT
        #expect(ResponseClassifier.parseRetryAfter("12", now: now) == 12)
        #expect(ResponseClassifier.parseRetryAfter("Sun, 09 Sep 2001 01:47:40 GMT", now: now) == 60)
        #expect(ResponseClassifier.parseRetryAfter("soon", now: now) == nil)
        #expect(ResponseClassifier.parseRetryAfter("-3", now: now) == nil)
    }

    @Test func backoffGrowsIsCappedAndHonoursTheServer() {
        let top: (ClosedRange<Double>) -> Double = { $0.upperBound }
        #expect(Backoff.delay(attempt: 0, retryAfter: nil, random: top) == 1) // the spec: 1 s doubling to 5 min
        #expect(Backoff.delay(attempt: 3, retryAfter: nil, random: top) == 8)
        #expect(Backoff.delay(attempt: 30, retryAfter: nil, random: top) == 300)
        #expect(Backoff.delay(attempt: 0, retryAfter: 900, random: top) == 900)
    }
}

struct DiskQueueTests {
    @Test func filesSealAtTheEventLimitAndKeepOrder() async {
        let queue = makeQueue(maxFileEvents: 2)
        for index in 0..<5 { await queue.append(Data("{\"n\":\(index)}".utf8), to: .ready) }
        #expect(await queue.readyBatches().count == 2) // the 5th event is still in the open file
        await queue.seal()
        let batches = await queue.readyBatches()
        #expect(batches.count == 3)
        let first = await queue.contents(of: batches[0])!
        #expect(String(decoding: first, as: UTF8.self) == "{\"n\":0}\n{\"n\":1}\n")
    }

    @Test func filesMadeInTheSameMillisecondKeepTheirOrder() async throws {
        let queue = makeQueue(maxFileEvents: 1)
        for index in 0..<100 { await queue.append(Data("{\"n\":\(index)}".utf8), to: .ready) }
        let order = try await queue.readyBatches().map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
        #expect(order == (0..<100).map { "{\"n\":\($0)}\n" })
    }

    @Test func oldestFilesGoWhenOverTheDiskCap() async {
        let queue = makeQueue(maxFileEvents: 1, maxTotalBytes: 30)
        for index in 0..<10 {
            await queue.append(Data("{\"event\":\(index)}".utf8), to: .ready) // 12 bytes each
            try? await Task.sleep(for: .milliseconds(5))
        }
        let left = await queue.readyBatches()
        #expect(left.count == 2)
        #expect(await queue.droppedEvents == 8)
        #expect(String(decoding: await queue.contents(of: left.last!)!, as: UTF8.self) == "{\"event\":9}\n")
    }

    @Test func pendingEventsAreHeldThenPromotedOrRemoved() async {
        let queue = makeQueue()
        await queue.append(Data("{}".utf8), to: .pending)
        await queue.seal()
        #expect(await queue.readyBatches().isEmpty)
        await queue.promotePending()
        #expect(await queue.readyBatches().count == 1)
        await queue.append(Data("{}".utf8), to: .pending)
        await queue.removeAll()
        #expect(await queue.readyBatches().isEmpty)
    }
}

struct UploaderTests {
    func uploader(_ transport: FakeTransport, queue: DiskQueue) -> Uploader {
        // The longest wait the backoff allows, so "inside the window" is certain.
        Uploader(endpoint: URL(string: "https://ingest.test")!, apiKey: "lyr_ing_x", transport: transport, queue: queue,
                 jitter: { $0.upperBound })
    }

    func fill(_ queue: DiskQueue, batches: Int) async {
        for index in 0..<batches {
            await queue.append(Data("{\"n\":\(index)}".utf8), to: .ready)
            await queue.seal()
        }
    }

    @Test func deliversEveryBatchAsGzipWithTheKey() async throws {
        let queue = makeQueue()
        await fill(queue, batches: 3)
        let transport = FakeTransport([ok, ok, ok])
        let report = await uploader(transport, queue: queue).uploadReady(force: false)
        #expect(report.delivered == 3)
        #expect(await queue.readyBatches().isEmpty)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://ingest.test/v1/events:batch")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer lyr_ing_x")
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")
    }

    @Test func aRetryableFailureKeepsTheBatchAndBacksOff() async {
        let queue = makeQueue()
        await fill(queue, batches: 2)
        let transport = FakeTransport([(503, "", [:]), ok, ok])
        let sender = uploader(transport, queue: queue)
        let first = await sender.uploadReady(force: false)
        #expect(first.stoppedForRetry && first.delivered == 0)
        #expect(await queue.readyBatches().count == 2)
        // Inside the backoff window a normal round sends nothing...
        _ = await sender.uploadReady(force: false)
        #expect(transport.count == 1)
        // ...but a flush (going to the background) tries once more: our own backoff, not
        // the server's Retry-After (aForcedFlushRespectsRetryAfter), gives way to it.
        let forced = await sender.uploadReady(force: true)
        #expect(forced.delivered == 2)
    }

    @Test func networkErrorsAreRetried() async {
        let queue = makeQueue()
        await fill(queue, batches: 1)
        let report = await uploader(FakeTransport([]), queue: queue).uploadReady(force: true)
        #expect(report.stoppedForRetry)
        #expect(await queue.readyBatches().count == 1)
    }

    @Test func aBadBatchIsDroppedAndTheRestStillGoes() async {
        let queue = makeQueue()
        await fill(queue, batches: 2)
        let report = await uploader(FakeTransport([(400, "{}", [:]), ok]), queue: queue).uploadReady(force: false)
        #expect(report.dropped == 1 && report.delivered == 1)
        #expect(await queue.readyBatches().isEmpty)
    }

    @Test func aRejectedKeyStopsSendingButKeepsTheData() async {
        let queue = makeQueue()
        await fill(queue, batches: 2)
        let transport = FakeTransport([(401, "", [:]), ok, ok])
        let sender = uploader(transport, queue: queue)
        _ = await sender.uploadReady(force: true)
        _ = await sender.uploadReady(force: true)
        #expect(transport.count == 1)
        #expect(await sender.disabled)
        #expect(await queue.readyBatches().count == 2)
    }
}

/// The monthly quota stop: one warning until a batch is accepted again; the retry is a plain 429.
struct QuotaTests {
    static func quota(_ error: String) -> (Int, String, [String: String]) {
        (429, #"{"error":"\#(error)","plan":"free","limit":1000000,"used":1000123}"#,
         ["Content-Type": "application/json", "Retry-After": "0"])
    }
    static let rateLimited = (429, #"{"error":"rate limit for this project"}"#, ["Content-Type": "application/json", "Retry-After": "0"])

    func said(_ marker: String) -> [String] { SDKLog.recent.filter { $0.contains(marker) } }

    @Test func warnsOncePerQuotaStopAndAgainAfterADelivery() async {
        let marker = "quota-\(UUID().uuidString)"
        let queue = makeQueue()
        await UploaderTests().fill(queue, batches: 3)
        let transport = FakeTransport([Self.quota(marker), Self.quota(marker), ok, Self.quota(marker), Self.rateLimited])
        let sender = UploaderTests().uploader(transport, queue: queue)

        let first = await sender.uploadReady(force: true)
        let second = await sender.uploadReady(force: true)
        #expect(first.stoppedForRetry && second.stoppedForRetry)
        #expect(said(marker).count == 1)
        #expect(await queue.readyBatches().count == 3) // kept, retried as any 429

        let third = await sender.uploadReady(force: true) // ok, then the quota again
        #expect(third.delivered == 1 && third.stoppedForRetry)
        #expect(said(marker).count == 2)

        _ = await sender.uploadReady(force: true) // the rate limit says nothing
        #expect(said(marker).count == 2)
        #expect(await queue.readyBatches().count == 2)
        #expect(transport.count == 5)
        #expect(said(marker).first == "Lyrelog: \(marker). Events are kept and sent when sending resumes; how many wait depends on the platform (here: on disk, up to 976 KB and 1 hour).")
        #expect(said(marker).allSatisfy { !$0.contains("lyr_ing_x") })
    }

    @Test func aRateLimitNeverWarnsAndRetriesAsBefore() async {
        let queue = makeQueue()
        await UploaderTests().fill(queue, batches: 1)
        let transport = FakeTransport([Self.rateLimited, Self.rateLimited, (429, "not json", [:])])
        let sender = UploaderTests().uploader(transport, queue: queue)
        for _ in 0..<3 { #expect(await sender.uploadReady(force: true).stoppedForRetry) }
        #expect(await sender.quotaWarnings == 0)
        #expect(await queue.readyBatches().count == 1)
    }

    @Test func tellsTheQuotaFromTheRateLimit() {
        #expect(ResponseClassifier.quotaMessage(status: 429, body: Data(Self.quota("used up.").1.utf8)) == "used up")
        #expect(ResponseClassifier.quotaMessage(status: 429, body: Data(Self.rateLimited.1.utf8)) == nil)
        #expect(ResponseClassifier.quotaMessage(status: 429, body: Data("<html>busy</html>".utf8)) == nil)
        #expect(ResponseClassifier.quotaMessage(status: 429, body: Data(#"["plan","limit"]"#.utf8)) == nil)
        #expect(ResponseClassifier.quotaMessage(status: 503, body: Data(Self.quota("x").1.utf8)) == nil)
        // The retry is the same as any 429.
        #expect(ResponseClassifier.classify(status: 429, body: Data(Self.quota("x").1.utf8), retryAfter: "3600") == .retry(after: 3600))
    }

    @Test func describesTheDefaultCaps() {
        let defaults = Lyrelog.Configuration(apiKey: "k")
        let limits = DiskQueue.Limits(maxFileBytes: 1, maxFileEvents: 1, maxTotalBytes: defaults.maxDiskBytes,
                                      maxAge: TimeInterval(defaults.maxEventAge.components.seconds))
        #expect(Uploader.describeKeeping(limits) == "20 MB and 7 days")
    }
}

struct EngineTests {
    @Test func flushWritesEverythingLoggedBeforeItAndUploads() async throws {
        let transport = FakeTransport([ok])
        let root = temporaryDirectory()
        let engine = Engine(configuration: Configuration(endpoint: URL(string: "https://ingest.test")!, apiKey: "k",
                                                         uploadInterval: .seconds(3600)),
                            transport: transport, root: root)
        defer { engine.stop() }
        for index in 0..<50 {
            engine.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "m\(index)",
                                        attributes: ["i": .int(index)], payload: nil, userID: nil, sessionID: "s"))
        }
        await engine.flush()
        #expect(transport.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.httpBody != nil)
        #expect(await engine.queue.readyBatches().isEmpty)
    }

    @Test func pendingConsentKeepsEventsUntilGranted() async {
        let transport = FakeTransport([ok])
        let engine = Engine(configuration: Configuration(endpoint: URL(string: "https://ingest.test")!, apiKey: "k",
                                                         consent: .pending, uploadInterval: .seconds(3600)),
                            transport: transport, root: temporaryDirectory())
        defer { engine.stop() }
        engine.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "held",
                                    attributes: [:], payload: nil, userID: nil, sessionID: "s"))
        await engine.flush()
        #expect(transport.count == 0)
        engine.setConsent(.granted)
        await engine.flush()
        #expect(transport.count == 1)
    }
}
