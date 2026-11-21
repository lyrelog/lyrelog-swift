import Foundation
import Testing
@testable import Lyrelog

/// A MetricKit diagnostic payload as `jsonRepresentation()` writes it (trimmed).
let crashPayload = Data("""
{
  "timeStampBegin": "2026-11-17 10:42:00",
  "timeStampEnd": "2026-11-17 10:42:00",
  "crashDiagnostics": [{
    "version": "1.0.0",
    "diagnosticMetaData": {
      "appVersion": "2.0", "appBuildVersion": "202611171210", "osVersion": "iPhone OS 27.2 (25C55)",
      "deviceType": "iPhone18,1", "isTestFlightApp": true, "exceptionType": 1, "exceptionCode": 0, "signal": 11,
      "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11"
    },
    "callStackTree": {
      "callStackPerThread": true,
      "callStacks": [
        {"threadAttributed": false, "callStackRootFrames": [{"binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 4096, "binaryUUID": "A"}]},
        {"threadAttributed": true, "callStackRootFrames": [{
          "binaryName": "libswiftCore.dylib", "offsetIntoBinaryTextSegment": 255, "binaryUUID": "B",
          "subFrames": [{"binaryName": "Tilefall", "offsetIntoBinaryTextSegment": 1193046, "binaryUUID": "C",
            "subFrames": [{"binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 16, "binaryUUID": "D"}]}]
        }]}
      ]
    }
  }],
  "hangDiagnostics": [{"diagnosticMetaData": {"appVersion": "2.0", "hangDuration": "3.5 sec"}}],
  "diskWriteExceptionDiagnostics": [{"diagnosticMetaData": {"writesCaused": "1,073 MB"}}]
}
""".utf8)

/// When `crashPayload` happened: its reports are only made within a week of it.
let crashPayloadTime = DiagnosticReport.date("2026-11-17 10:42:00")!

struct DiagnosticsTests {
    @Test func aCrashBecomesACriticalEventWithItsFrames() throws {
        let reports = DiagnosticReport.events(from: crashPayload, appBinary: "Tilefall", now: crashPayloadTime)
        #expect(reports.map(\.message) == ["app_crashed", "app_hung", "disk_write_overuse"])
        let crash = try #require(reports.first)
        #expect(crash.level == .critical)
        #expect(crash.timestamp == DiagnosticReport.date("2026-11-17 10:42:00"))
        #expect(crash.attributes["exception"] == "EXC_BAD_ACCESS")
        #expect(crash.attributes["signal"] == "SIGSEGV")
        #expect(crash.attributes["version_at_report"] == "2.0")
        #expect(crash.attributes["testflight"] == true)
        // The crashed thread, top first, and the app's own frame picked as the top one.
        #expect(crash.attributes["top_frame"] == "Tilefall +0x123456")
        guard case .object(let payload) = crash.payload, case .array(let frames) = payload["frames"] else {
            Issue.record("no frames")
            return
        }
        #expect(frames == ["libswiftCore.dylib +0xff", "Tilefall +0x123456", "SwiftUI +0x10"])
        #expect(reports[1].attributes["hang_seconds"] == .double(3.5))
        #expect(reports[2].attributes["writes"] == "1,073 MB")
    }

    @Test func theSameReportAlwaysGetsTheSameID() {
        let a = DiagnosticReport.events(from: crashPayload, now: crashPayloadTime).map(\.id)
        let b = DiagnosticReport.events(from: crashPayload, now: crashPayloadTime).map(\.id)
        #expect(a == b)
        #expect(Set(a).count == a.count)
    }

    @Test func garbageGivesNothing() {
        #expect(DiagnosticReport.events(from: Data("not json".utf8)).isEmpty)
        #expect(DiagnosticReport.events(from: Data("{}".utf8)).isEmpty)
    }

    @Test(arguments: [("3 sec", 3.0), ("1,500 ms", 1.5), ("2 min", 120.0), ("4", 4.0)])
    func durationsReadInSeconds(text: String, expected: Double) {
        #expect(DiagnosticReport.seconds(text) == expected)
    }
}

struct NetworkTests {
    @Test(arguments: [
        ("https://api.test/v1/users/12345/matches", "/v1/users/:id/matches"),
        ("https://api.test/chat/6f1b2c3d-1234-4abc-8def-1234567890ab", "/chat/:id"),
        ("https://api.test/files/a8f3k2l9q0w8e7r6t5y4", "/files/:id"),
        ("https://api.test/settings/notifications?token=secret", "/settings/notifications"),
        ("https://api.test", "/"),
        // Ids of every shape: Game Center, email, JWT, tokens without digits, short ones.
        ("https://api.test/players/G:1234567890/stats", "/players/:id/stats"),
        ("https://api.test/users/a@b.com", "/users/:id"),
        ("https://api.test/users/a%40b.com/avatar", "/users/:id/avatar"),
        ("https://api.test/auth/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", "/auth/:id"),
        ("https://api.test/reset/AbCdEfGhIjKlMnOpQr", "/reset/:id"),
        ("https://api.test/invite/qwertyuiopasdfghjklzxcvbnm", "/invite/:id"),
        ("https://api.test/items/abc123def", "/items/:id"),
        ("https://api.test/k/key=value", "/k/:id"),
        // What names an endpoint stays.
        ("https://api.test/v2/leaderboards/achievements", "/v2/leaderboards/achievements"),
        ("https://api.test/notification-preferences", "/notification-preferences"),
        ("https://api.test/players/me/daily_results", "/players/me/daily_results"),
    ])
    func pathsKeepTheEndpointNotTheIDs(url: String, expected: String) {
        #expect(Lyrelog.Network.path(URL(string: url)!) == expected)
    }

    @Test func aRouteTemplateWinsAndNeverCarriesAQuery() {
        let request = URLRequest(url: URL(string: "https://api.test/players/G:123/stats?token=secret")!)
        let event = Lyrelog.Network.event(request, response: nil, error: nil, duration: .milliseconds(5), bytes: nil,
                                          route: "/players/:player/stats?debug=1#x")
        #expect(event.attrs["path"] == "/players/:player/stats")
        let plain = Lyrelog.Network.event(request, response: nil, error: nil, duration: .milliseconds(5), bytes: nil, route: nil)
        #expect(plain.attrs["path"] == "/players/:id/stats")
    }
}

/// Uses the shared Lyrelog, so these run one at a time.
@Suite(.serialized)
struct ScreenTests {
    @Test func eventsCarryTheScreenAndScreensSayWhereFrom() async throws {
        let transport = FakeTransport([ok, ok])
        Lyrelog.start(Configuration(endpoint: URL(string: "https://ingest.test")!, apiKey: "k", uploadInterval: .seconds(3600),
                                    captureDiagnostics: false),
                      transport: transport, root: temporaryDirectory())
        defer { Lyrelog.stopNow() }
        Lyrelog.screen("Home")
        Lyrelog.screen("Home") // the same screen again is not a new view
        Lyrelog.info("tapped_play")
        Lyrelog.screen("Game")
        Lyrelog.info("won", attrs: ["screen": "custom"]) // an explicit value wins
        await Lyrelog.flush()
        let lines = try transport.requests.flatMap { try ndjson($0.httpBody ?? Data()) }
        #expect(lines.map { $0["message"] as? String } == ["screen_viewed", "tapped_play", "screen_viewed", "won"])
        let attrs = lines.map { $0["attrs"] as? [String: Any] ?? [:] }
        #expect(attrs[1]["screen"] as? String == "Home")
        #expect(attrs[2]["previous_screen"] as? String == "Home")
        #expect(attrs[2]["seconds_on_previous"] != nil)
        #expect(attrs[3]["screen"] as? String == "custom")
    }
}

/// The lines of a gzip-compressed NDJSON body.
func ndjson(_ gzip: Data) throws -> [[String: Any]] {
    // gzip = a 10-byte header, raw DEFLATE, an 8-byte trailer; Foundation's .zlib reads raw DEFLATE.
    let deflated = gzip.dropFirst(10).dropLast(8)
    let plain = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
    return String(decoding: plain, as: UTF8.self).split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
}

extension DiagnosticsTests {
    // `pastDiagnosticPayloads` is read on every launch. A report older than the project's
    // retention is stored by the server at its arrival time (`_lyrelog_ts_clamped`), so the
    // same old crash became a new `app_crashed` row, "now", on every launch.
    @Test func aReportOlderThanAWeekIsNotSentAgain() throws {
        let happened = try #require(DiagnosticReport.date("2026-11-17 10:42:00"))
        #expect(!DiagnosticReport.events(from: crashPayload, now: happened.addingTimeInterval(6 * 86_400)).isEmpty)
        #expect(DiagnosticReport.events(from: crashPayload, now: happened.addingTimeInterval(30 * 86_400)).isEmpty)
    }
}
