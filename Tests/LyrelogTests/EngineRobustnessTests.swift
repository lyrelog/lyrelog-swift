import Foundation
import Testing
@testable import Lyrelog

// MARK: - Helpers

/// A transport that holds every request until `open()`, then answers with `respond`.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var bodies: [Data] = []
    private var startedCount = 0
    let respond: @Sendable (Data) -> (Int, String, [String: String])

    init(open: Bool = false, respond: @escaping @Sendable (Data) -> (Int, String, [String: String]) = { _ in ok }) {
        isOpen = open
        self.respond = respond
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody ?? Data()
        let mustWait = lock.withLock { () -> Bool in
            startedCount += 1
            return !isOpen
        }
        if mustWait {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
        lock.withLock { bodies.append(body) }
        let (status, text, headers) = respond(body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(text.utf8), response)
    }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    var started: Int { lock.withLock { startedCount } }
    var count: Int { lock.withLock { bodies.count } }
    var messages: [String] {
        lock.withLock { bodies }.flatMap { (try? ndjson($0)) ?? [] }.compactMap { $0["message"] as? String }
    }
    var lines: [[String: Any]] { lock.withLock { bodies }.flatMap { (try? ndjson($0)) ?? [] } }
}

func testConfiguration(consent: Consent = .granted, interval: Duration = .seconds(3600),
                       maxBatchEvents: Int = 500, maxDiskBytes: Int = 20 * 1024 * 1024) -> Configuration {
    var configuration = Configuration(endpoint: URL(string: "https://ingest.test")!, apiKey: "k", consent: consent,
                                      uploadInterval: interval, pauseUploadsInLowPowerMode: false,
                                      maxBatchEvents: maxBatchEvents, maxDiskBytes: maxDiskBytes,
                                      captureDiagnostics: false)
    configuration.environment = "test"
    return configuration
}

func event(_ message: String) -> PendingEvent {
    PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: message,
                 attributes: [:], payload: nil, userID: nil, sessionID: "s")
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Whether `operation` returns within `timeout`. The operation runs unstructured, so one that
/// never returns doesn't hang the test.
func finishes(within timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let result = OSAllocatedUnfairLockBox<Bool?>(nil)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Task {
            await operation()
            if result.setIfNil(true) { continuation.resume() }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if result.setIfNil(false) { continuation.resume() }
        }
    }
    return result.value ?? false
}

final class OSAllocatedUnfairLockBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func setIfNil<U>(_ value: U) -> Bool where T == U? {
        lock.withLock {
            guard stored == nil else { return false }
            stored = value
            return true
        }
    }
}

/// Events on disk under a queue root, in any area or file.
func linesOnDisk(_ root: URL) -> Int {
    var total = 0
    for area in ["ready", "pending"] {
        let directory = root.appendingPathComponent(area)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".ndjson") {
            let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
            total += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
    }
    return total
}

func filesOnDisk(_ root: URL, _ area: String = "ready") -> Int {
    let directory = root.appendingPathComponent(area)
    return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".ndjson") }.count
}

// MARK: - The intake (H1, M4)

struct IntakeTests {
    @Test func aDenialIsNeverLostWhenTheIntakeOverflows() async {
        let transport = GatedTransport()
        let root = temporaryDirectory()
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: root, intakeCapacity: 5)
        defer { engine.stop() }
        engine.enqueue(event("before"))
        let first = Task { await engine.flush() }
        #expect(await eventually { transport.started == 1 })
        engine.setConsent(.denied)
        for index in 0..<50 { engine.enqueue(event("after\(index)")) }
        transport.open()
        let done = await finishes(within: .seconds(5)) {
            await first.value
            await engine.flush()
        }
        #expect(done)
        #expect(transport.messages == ["before"], "nothing logged after the denial may leave the device")
        #expect(linesOnDisk(root) == 0)
    }

    @Test func aFlushIsNeverLostWhenTheIntakeOverflows() async {
        let transport = GatedTransport()
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: temporaryDirectory(), intakeCapacity: 5)
        defer { engine.stop() }
        engine.enqueue(event("first"))
        let first = Task { await engine.flush() }
        #expect(await eventually { transport.started == 1 })
        let second = Task { await engine.flush() }
        try? await Task.sleep(for: .milliseconds(20))
        for index in 0..<50 { engine.enqueue(event("e\(index)")) }
        transport.open()
        #expect(await finishes(within: .seconds(5)) {
            await first.value
            await second.value
        }, "every flush returns")
    }

    @Test func eventsReachTheDiskWhileAnUploadHangs() async {
        let transport = GatedTransport()
        let root = temporaryDirectory()
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: root)
        defer { engine.stop() }
        engine.enqueue(event("first"))
        let flushing = Task { await engine.flush() }
        #expect(await eventually { transport.started == 1 })
        for index in 0..<20 { engine.enqueue(event("e\(index)")) }
        #expect(await eventually(.seconds(2)) { linesOnDisk(root) >= 21 }, "the writer keeps writing while the network hangs")
        transport.open()
        await flushing.value
    }
}

// MARK: - Consent at launch (H2)

struct LaunchConsentTests {
    func leaveBatches(in root: URL) async {
        let earlier = DiskQueue(root: root, limits: .init(maxFileBytes: 64 * 1024, maxFileEvents: 100,
                                                          maxTotalBytes: 1_000_000, maxAge: 3600))
        await earlier.append(Data(#"{"left":"ready"}"#.utf8), to: .ready)
        await earlier.seal()
        await earlier.append(Data(#"{"left":"pending"}"#.utf8), to: .pending)
        await earlier.seal()
    }

    @Test func aDenialAtLaunchDeletesWhatAnEarlierLaunchLeft() async {
        let root = temporaryDirectory()
        await leaveBatches(in: root)
        let transport = FakeTransport([ok, ok])
        let engine = Engine(configuration: testConfiguration(consent: .denied), transport: transport, root: root)
        defer { engine.stop() }
        await engine.flush()
        #expect(transport.count == 0)
        #expect(linesOnDisk(root) == 0)
    }

    @Test func pendingAtLaunchSendsNothingLeftFromBefore() async {
        let root = temporaryDirectory()
        await leaveBatches(in: root)
        let transport = FakeTransport([ok, ok])
        let engine = Engine(configuration: testConfiguration(consent: .pending), transport: transport, root: root)
        defer { engine.stop() }
        await engine.flush()
        #expect(transport.count == 0)
        #expect(linesOnDisk(root) == 2)
    }
}

// MARK: - Upload rounds (M1, M2, M3)

struct UploadRoundTests {
    func uploader(_ transport: any HTTPTransport, queue: DiskQueue) -> Uploader {
        Uploader(endpoint: URL(string: "https://ingest.test")!, apiKey: "lyr_ing_x", transport: transport, queue: queue)
    }

    func addBatch(_ queue: DiskQueue, _ text: String) async {
        await queue.append(Data(#"{"message":"\#(text)"}"#.utf8), to: .ready)
        await queue.seal()
        try? await Task.sleep(for: .milliseconds(2)) // file names are by the millisecond
    }

    @Test func aForcedRoundWaitsForTheRunningOneAndSendsWhatCameAfter() async {
        let queue = makeQueue()
        await addBatch(queue, "one")
        let transport = GatedTransport()
        let sender = uploader(transport, queue: queue)
        let periodic = Task { await sender.uploadReady(force: false) }
        #expect(await eventually { transport.started == 1 })
        await addBatch(queue, "two")
        let forced = Task { await sender.uploadReady(force: true) }
        try? await Task.sleep(for: .milliseconds(30))
        transport.open()
        _ = await periodic.value
        _ = await forced.value
        #expect(transport.messages.sorted() == ["one", "two"])
        #expect(await queue.readyBatches().isEmpty)
    }

    @Test func aBatchThatKeepsFailingDoesNotHoldBackTheOthers() async {
        let queue = makeQueue()
        await addBatch(queue, "bad")
        let transport = GatedTransport(open: true) { body in
            let text = (try? ndjson(body))?.compactMap { $0["message"] as? String } ?? []
            return text.contains("bad") ? (500, "", [:]) : ok
        }
        let sender = uploader(transport, queue: queue)
        for round in 0..<12 {
            await addBatch(queue, "good\(round)")
            _ = await sender.uploadReady(force: true)
        }
        let good = transport.messages.filter { $0.hasPrefix("good") }
        #expect(good.count >= 10, "the healthy batches go while the bad one keeps failing")
        #expect(transport.messages.filter { $0 == "bad" }.count <= 9)
        #expect(await queue.readyBatches().allSatisfy { !(String(decoding: (try? Data(contentsOf: $0)) ?? Data(), as: UTF8.self)).contains("bad") },
                "after enough failures while others go through, the bad batch is dropped")
        #expect(await queue.droppedEvents == 1)
    }

    @Test func aForcedFlushRespectsRetryAfter() async {
        let queue = makeQueue()
        await addBatch(queue, "one")
        let transport = FakeTransport([(429, "", ["Retry-After": "600"]), ok])
        let sender = uploader(transport, queue: queue)
        _ = await sender.uploadReady(force: false)
        _ = await sender.uploadReady(force: true)
        #expect(transport.count == 1, "the server asked to wait 10 minutes")
    }

    @Test func noTinyFilesPileUpWhileTheServerSaysWait() async {
        let root = temporaryDirectory()
        let transport = GatedTransport(open: true) { _ in (503, "", ["Retry-After": "600"]) }
        let engine = Engine(configuration: testConfiguration(interval: .milliseconds(20)), transport: transport, root: root)
        defer { engine.stop() }
        for index in 0..<40 {
            engine.enqueue(event("e\(index)"))
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.started <= 2)
        #expect(filesOnDisk(root) <= 3, "a file is sealed only when it will be sent")
    }
}

// MARK: - Reporting drops (L8)

struct DropReportTests {
    @Test func dropsAreReportedOnTheNextBatch() async {
        let root = temporaryDirectory()
        let transport = GatedTransport(open: true)
        let engine = Engine(configuration: testConfiguration(maxBatchEvents: 1, maxDiskBytes: 2000), transport: transport, root: root)
        defer { engine.stop() }
        for index in 0..<15 {
            engine.enqueue(event("e\(index)"))
            try? await Task.sleep(for: .milliseconds(2))
        }
        await engine.flush()
        let note = transport.lines.first { $0["message"] as? String == "lyrelog_events_dropped" }
        let attrs = note?["attrs"] as? [String: Any]
        #expect(note?["level"] as? String == "warning")
        #expect(note?["category"] as? String == "lyrelog")
        #expect((attrs?["count"] as? Int ?? 0) >= 5)
    }
}

// MARK: - The shared Lyrelog (L3, settings before start)

extension ScreenTests {
    @Test func stopSendsWhatWasLogged() async {
        let transport = GatedTransport(open: true)
        Lyrelog.start(testConfiguration(), transport: transport, root: temporaryDirectory())
        Lyrelog.info("last_words")
        await Lyrelog.stop()
        #expect(transport.messages == ["last_words"])
    }

    @Test func consentAndUserSetBeforeStartAreKept() async {
        let transport = GatedTransport(open: true)
        Lyrelog.setUser("early-player")
        Lyrelog.setConsent(.pending)
        Lyrelog.start(testConfiguration(consent: .granted), transport: transport, root: temporaryDirectory())
        defer { Lyrelog.stopNow() }
        Lyrelog.info("held")
        await Lyrelog.flush()
        #expect(transport.count == 0, "the earlier setConsent(.pending) wins over the configuration")
        Lyrelog.setConsent(.granted)
        await Lyrelog.flush()
        #expect(transport.messages == ["held"])
        #expect(transport.lines.first?["user_id"] as? String == "early-player")
    }
}

// MARK: - The install id (L6)

struct InstallIDTests {
    @Test func theInstallIDIsNotBackedUp() throws {
        let directory = temporaryDirectory()
        _ = DeviceContext.installID(in: directory)
        let values = try directory.appendingPathComponent("install_id").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func aDenialForgetsTheInstallID() async {
        let root = temporaryDirectory()
        let file = root.appendingPathComponent("install_id")
        let transport = GatedTransport(open: true)
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: root)
        defer { engine.stop() }
        engine.enqueue(event("one"))
        await engine.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        engine.setConsent(.denied)
        await engine.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path), "a denial leaves nothing on the device")
        engine.setConsent(.granted)
        engine.enqueue(event("two"))
        await engine.flush()
        let ids = transport.lines.compactMap { $0["install_id"] as? String }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2, "after a denial the person is a new install")
    }
}

// MARK: - Errors as the shared `exception` event (L8)

enum SubmitError: Error, CustomStringConvertible {
    case rejected(code: Int)
    var description: String { "rejected with code \(code)" }
    var code: Int { if case .rejected(let code) = self { return code }; return 0 }
}

extension ScreenTests {
    @Test func aSwiftErrorBecomesAnExceptionEvent() async throws {
        let transport = GatedTransport(open: true)
        Lyrelog.start(testConfiguration(), transport: transport, root: temporaryDirectory())
        defer { Lyrelog.stopNow() }
        Lyrelog.captureError(SubmitError.rejected(code: 6), category: "gamecenter", attrs: ["attempt": 2])
        Lyrelog.Logger(category: "network").captureError(URLError(.timedOut))
        await Lyrelog.flush()
        let lines = transport.lines
        #expect(lines.count == 2)
        let first = try #require(lines.first)
        #expect(first["message"] as? String == "exception")
        #expect(first["level"] as? String == "error")
        #expect(first["category"] as? String == "gamecenter")
        let attrs = try #require(first["attrs"] as? [String: Any])
        #expect(attrs["error_type"] as? String == "LyrelogTests.SubmitError")
        #expect(attrs["error_message"] as? String == "rejected with code 6")
        #expect(attrs["attempt"] as? Int == 2)
        let payload = try #require(first["payload"] as? [String: Any])
        #expect(payload["description"] as? String == "rejected with code 6")
        #expect(payload["domain"] != nil)
        let second = try #require((lines.last?["attrs"] as? [String: Any]))
        #expect(["Foundation.URLError", "NSURLErrorDomain"].contains(second["error_type"] as? String))
        #expect(lines.last?["category"] as? String == "network")
    }
}
