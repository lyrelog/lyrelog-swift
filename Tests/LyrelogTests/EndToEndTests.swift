import Foundation
import Testing
@testable import Lyrelog

/// Against a real local stack (in the lyrelog repo: `make up`, then `make project` for a key):
///
///     LYRELOG_E2E_KEY=lyr_ing_... swift test --filter EndToEnd
///
/// Skipped when the variable is missing.
struct EndToEndTests {
    static let key = ProcessInfo.processInfo.environment["LYRELOG_E2E_KEY"]
    static let endpoint = ProcessInfo.processInfo.environment["LYRELOG_E2E_URL"] ?? "http://127.0.0.1:8090"

    @Test(.enabled(if: key != nil))
    func eventsReachTheServer() async throws {
        let engine = Engine(configuration: Configuration(endpoint: URL(string: Self.endpoint)!, apiKey: Self.key!,
                                                         uploadInterval: .seconds(3600)),
                            root: temporaryDirectory())
        defer { engine.stop() }
        let marker = UUID().uuidString
        engine.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "e2e_\(marker)",
                                    attributes: ["latency_ms": 412, "gc": ["ok": true]],
                                    payload: ["note": "from swift test"], userID: "e2e-user", sessionID: "e2e"))
        await engine.flush()
        #expect(await engine.queue.readyBatches().isEmpty, "the server should have accepted the batch")
    }
}

extension EndToEndTests {
    /// A MetricKit crash report (the fixture in DiagnosticsTests) reaches the server and is accepted.
    @Test(.enabled(if: key != nil))
    func aCrashReportReachesTheServer() async throws {
        let engine = Engine(configuration: Configuration(endpoint: URL(string: Self.endpoint)!, apiKey: Self.key!,
                                                         uploadInterval: .seconds(3600)),
                            root: temporaryDirectory())
        defer { engine.stop() }
        for report in DiagnosticReport.events(from: crashPayload, appBinary: "Tilefall", now: crashPayloadTime) {
            // Reports keep their own time; move the fixture's to now so it lands in the retention.
            engine.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: report.level, category: "diagnostics",
                                        message: report.message, attributes: report.attributes, payload: report.payload,
                                        userID: "e2e-user", sessionID: ""))
        }
        await engine.flush()
        #expect(await engine.queue.readyBatches().isEmpty, "the server should have accepted the batch")
    }
}
