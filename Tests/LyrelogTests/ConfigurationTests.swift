import Foundation
import Testing
@testable import Lyrelog

struct ConfigurationTests {
    @Test func theHostedIngestIsTheDefault() {
        #expect(Configuration(apiKey: "k").endpoint.absoluteString == "https://ingest.lyrelog.com")
    }

    @Test(arguments: [
        ("https://ingest.lyrelog.com", "https://ingest.lyrelog.com"),
        ("https://ingest.lyrelog.com/", "https://ingest.lyrelog.com"),
        ("https://ingest.lyrelog.com/v1/events:batch", "https://ingest.lyrelog.com"),
        ("https://ingest.lyrelog.com/v1/events:batch/", "https://ingest.lyrelog.com"),
        ("https://ingest.lyrelog.com/v1", "https://ingest.lyrelog.com"),
        ("https://ingest.lyrelog.com/v1/", "https://ingest.lyrelog.com"),
        ("https://proxy.test/lyrelog", "https://proxy.test/lyrelog"),
        ("http://localhost:8090", "http://localhost:8090"),
        ("http://127.0.0.1:8090/v1", "http://127.0.0.1:8090"),
        ("http://[::1]:8090", "http://[::1]:8090"),
    ])
    func aPastedEndpointBecomesTheOrigin(raw: String, expected: String) {
        #expect(Configuration.ingestOrigin(URL(string: raw)!)?.absoluteString == expected)
    }

    @Test(arguments: ["http://ingest.lyrelog.com", "ftp://ingest.lyrelog.com", "http://192.168.1.10:8090"])
    func plainHTTPIsRefusedExceptOnThisMachine(raw: String) {
        #expect(Configuration.ingestOrigin(URL(string: raw)!) == nil)
    }

    @Test func aRefusedEndpointSendsNothingAndKeepsTheData() async {
        let transport = FakeTransport([ok])
        let root = temporaryDirectory()
        var configuration = testConfiguration()
        configuration.endpoint = URL(string: "http://ingest.lyrelog.com")!
        let engine = Engine(configuration: configuration, transport: transport, root: root)
        defer { engine.stop() }
        engine.enqueue(event("kept"))
        await engine.flush()
        #expect(transport.count == 0)
        #expect(linesOnDisk(root) == 1)
    }

    @Test func batchesStayInsideTheServerLimits() {
        let configuration = Configuration(apiKey: "k", maxBatchBytes: 50 * 1024 * 1024, maxBatchEvents: 10_000)
        #expect(configuration.effectiveMaxBatchEvents == 2000)
        #expect(configuration.effectiveMaxBatchBytes == 4 * 1024 * 1024) // the server: 4 MiB on the wire and decompressed
        let tiny = Configuration(apiKey: "k", maxBatchBytes: 0, maxBatchEvents: -3)
        #expect(tiny.effectiveMaxBatchEvents == 1)
        #expect(tiny.effectiveMaxBatchBytes >= 64 * 1024)
    }

    @Test func anEventOverOneMebibyteIsDroppedAndCountedBeforeQueueing() async {
        let root = temporaryDirectory()
        let transport = GatedTransport(open: true)
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: root)
        defer { engine.stop() }
        // 200 attributes, each an array of 64 strings of 1 KB: about 13 MB once encoded.
        var huge: [String: LogValue] = [:]
        let item = LogValue.string(String(repeating: "x", count: 1000))
        for index in 0..<200 { huge["a\(index)"] = .array(Array(repeating: item, count: 64)) }
        engine.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "huge",
                                    attributes: huge, payload: nil, userID: nil, sessionID: "s"))
        engine.enqueue(event("small"))
        await engine.flush()
        #expect(!transport.messages.contains("huge"))
        #expect(transport.messages.contains("small"))
        let note = transport.lines.first { $0["message"] as? String == "lyrelog_events_dropped" }
        #expect((note?["attrs"] as? [String: Any])?["count"] as? Int == 1)
    }

    @Test func redirectsAreAnsweredNotFollowed() async {
        #expect(ResponseClassifier.classify(status: 301, body: Data(), retryAfter: nil) == .drop(status: 301))
        #expect(ResponseClassifier.classify(status: 307, body: Data(), retryAfter: nil) == .drop(status: 307))
        let task = URLSession.shared.dataTask(with: URL(string: "https://ingest.test")!)
        let response = HTTPURLResponse(url: URL(string: "https://ingest.test")!, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": "https://elsewhere.test"])!
        let next = await NoRedirects().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                                  newRequest: URLRequest(url: URL(string: "https://elsewhere.test")!))
        #expect(next == nil)
    }

    @Test func aDroppedBatchFor404IsWarnedAbout() async {
        let queue = makeQueue()
        await queue.append(Data("{}".utf8), to: .ready)
        await queue.seal()
        let sender = Uploader(endpoint: URL(string: "https://ingest.test/wrong")!, apiKey: "k",
                              transport: FakeTransport([(404, "", [:])]), queue: queue)
        _ = await sender.uploadReady(force: true)
        #expect(SDKLog.recent.contains { $0.contains("404") })
    }

    /// L1: the module and the enum share a name, so these must resolve through the enum.
    @Test func theTypesAreReachableThroughTheEnum() {
        let configuration: Lyrelog.Configuration = Lyrelog.Configuration(apiKey: "k", consent: Lyrelog.Consent.pending)
        let value: Lyrelog.Value = ["a": 1]
        let same: Lyrelog.LogValue = value
        let level: Lyrelog.LogLevel = Lyrelog.Level.warning
        #expect(configuration.consent == .pending)
        #expect(same == value)
        #expect(level == .warning)
    }
}

struct VersionTests {
    @Test func theVersionIsTheSameEverywhere() throws {
        #expect(DeviceContext.sdkVersion == "lyrelog-swift/\(Lyrelog.version)")
        // A wrapper (Flutter, React Native) goes first; blank or nil changes nothing.
        #expect(DeviceContext.sdk(wrapper: "lyrelog-flutter/0.1.0") == "lyrelog-flutter/0.1.0 lyrelog-swift/\(Lyrelog.version)")
        #expect(DeviceContext.sdk(wrapper: " ") == DeviceContext.sdkVersion)
        #expect(DeviceContext.sdk(wrapper: nil) == DeviceContext.sdkVersion)
        #expect(DeviceContext.resource(wrapper: "lyrelog-react-native/0.1.0").sdk.hasPrefix("lyrelog-react-native/0.1.0 "))
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        #expect(text.contains(#"from: "\#(Lyrelog.version)""#), "the README's install line names this version")
    }

    @Test func thePrivacyManifestShipsInTheBundle() {
        #expect(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
    }
}
