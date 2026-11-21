import Foundation
import Testing
@testable import Lyrelog

/// What a strange answer, a misconfiguration or a stop must never do to the app the SDK lives
/// in: crash it, keep a core busy, keep sending, or mix its events with another app's.
struct HostSafetyTests {
    // A proxy or a captive portal can answer anything. A Retry-After of 10^30 seconds (or
    // "inf") used to overflow on its way to a Duration: a trap, the app dies.
    @Test(arguments: ["1e30", "inf", "99999999999999999999999"])
    func anAbsurdRetryAfterNeverCrashes(value: String) async {
        let queue = makeQueue()
        await queue.append(Data("{}".utf8), to: .ready)
        await queue.seal()
        let transport = FakeTransport([(503, "", ["Retry-After": value])])
        let uploader = Uploader(endpoint: URL(string: "https://ingest.test")!, apiKey: "k", transport: transport, queue: queue)
        let report = await uploader.uploadReady(force: true)
        #expect(report.stoppedForRetry)
        #expect(await queue.readyBatches().count == 1)
        let wait = ResponseClassifier.parseRetryAfter(value) ?? 0
        #expect(wait <= ResponseClassifier.maxRetryAfter)
    }

    // URLSession raises an Objective-C exception (no Swift code can catch it) when a task is
    // made after `invalidateAndCancel()`. A round or an App Attest refresh still running when
    // the SDK stops makes exactly that call.
    @Test func aStoppedTransportThrowsInsteadOfCrashing() async {
        let transport = URLSessionTransport()
        transport.invalidate()
        await #expect(throws: URLError.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "https://ingest.test/v1/events:batch")!))
        }
    }

    // After `stop()` nothing may be sent: the background observer still calls `flush()` on the
    // engine it was given (and on iOS that send went through the invalidated session above).
    @Test func aStoppedEngineNeverSendsAgain() async {
        let transport = FakeTransport([]) // offline: the event stays on disk
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: temporaryDirectory())
        engine.enqueue(event("kept"))
        await engine.flush()
        let before = transport.count
        engine.stop()
        await engine.flush()
        #expect(transport.count == before)
    }

    // An interval of zero (or less) made the pump loop without sleeping: a busy core and a
    // request per event.
    @Test(arguments: [Duration.zero, .seconds(-1)])
    func aZeroUploadIntervalDoesNotSpin(interval: Duration) async {
        let transport = GatedTransport(open: true)
        let engine = Engine(configuration: testConfiguration(interval: interval), transport: transport, root: temporaryDirectory())
        defer { engine.stop() }
        for index in 0..<20 {
            engine.enqueue(event("e\(index)"))
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.count <= 1)
    }

    // A name that is one enormous character (a letter with hundreds of combining marks) was
    // cut to nothing, and the server rejects an empty attribute name: the whole line was lost.
    @Test func anAttributeNameIsNeverCutToNothing() throws {
        let huge = "e" + String(repeating: "\u{301}", count: 200) // one Character, 401 bytes
        let name = EventPreparation.attributeName(huge)
        #expect(!name.isEmpty)
        #expect(name.utf8.count <= 128)
        #expect(!EventPreparation.truncated(huge, maxBytes: 64).isEmpty)
        let prepared = EventPreparation.attributes([huge: 1])
        #expect(prepared.keys.allSatisfy { !$0.isEmpty })
    }

    // `Int(Double)` traps out of range: a duration the app measured wrong must not kill it.
    @Test func anAbsurdRequestDurationNeverCrashes() {
        let request = URLRequest(url: URL(string: "https://api.test/x")!)
        let event = Lyrelog.Network.event(request, response: nil, error: nil, duration: .seconds(Int64.max), bytes: nil, route: nil)
        #expect(event.attrs["duration_ms"] == .int(Int.max))
    }

    #if os(macOS)
    // Outside the sandbox every Mac app shares ~/Library/Caches and Application Support: two
    // apps with Lyrelog read one queue (one app's events sent with the other's key, to its
    // project) and one install id (the same id across apps).
    @Test func eachMacAppHasItsOwnQueueAndInstallID() {
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        #expect(Engine.defaultDirectory(testConfiguration()).path.contains(app))
        #expect(Engine.supportDirectory().path.contains(app))
    }
    #endif
}

extension HostSafetyTests {
    // The intake capped only the number of events: 10,000 waiting events of 1 MiB each is
    // 10 GB, and an app logging big payloads in a loop outruns the writer (which encodes each
    // one) and is killed for its memory. Now 16 MiB at most wait; the oldest go, counted.
    @Test func bigEventsInATightLoopStayInsideTheIntakeBudget() async throws {
        let transport = GatedTransport(open: true)
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: temporaryDirectory())
        defer { engine.stop() }
        let events = (0..<100).map { index in
            PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "big\(index)",
                         attributes: [:], payload: .string("\(index)" + String(repeating: "x", count: 1 << 20)),
                         userID: nil, sessionID: "s")
        }
        for event in events { engine.enqueue(event) }
        await engine.flush()
        let note = try #require(transport.lines.first { $0["message"] as? String == "lyrelog_events_dropped" },
                                "100 MiB logged at once can't all wait in memory")
        let dropped = (note["attrs"] as? [String: Any])?["in_memory"] as? Int ?? 0
        #expect(dropped >= 100 - 17)
        #expect(Engine.intakeBytes == 16 << 20)
    }

    @Test func theIntakeEstimateCountsWhatTheEventHolds() {
        let small = event("m")
        let big = PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "c", message: "m",
                               attributes: ["a": .string(String(repeating: "y", count: 10_000)), "n": [1, 2, ["k": "v"]]],
                               payload: ["p": .string(String(repeating: "z", count: 50_000))], userID: "u", sessionID: "s")
        #expect(small.estimatedBytes < 1_000)
        #expect(big.estimatedBytes > 60_000)
        #expect(big.estimatedBytes < 70_000)
    }
}
