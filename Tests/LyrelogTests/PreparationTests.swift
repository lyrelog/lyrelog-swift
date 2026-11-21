import Foundation
import Testing
@testable import Lyrelog

struct PreparationTests {
    @Test func truncationNeverSplitsACharacter() {
        let text = String(repeating: "ñ", count: 10) // 2 bytes each
        let cut = EventPreparation.truncated(text, maxBytes: 5)
        #expect(cut == "ññ")
        #expect(EventPreparation.truncated("🇪🇸🇪🇸", maxBytes: 9) == "🇪🇸") // a flag is 8 bytes
        #expect(EventPreparation.truncated("abc", maxBytes: 10) == "abc")
    }

    @Test func attributeNamesAreMadeSafe() {
        #expect(EventPreparation.attributeName("http.status") == "http_status")
        #expect(EventPreparation.attributeName("__private") == "private")
        #expect(EventPreparation.attributeName("_") == "key")
    }

    @Test func namesThatCollideAfterCleanupKeepTheFirstAndCountTheRest() {
        let prepared = EventPreparation.attributes(["a.b": 1, "a_b": 2, "_x": 3, "x": 4, "gc": ["k.v": 5, "k_v": 6]])
        #expect(prepared["a_b"] == .int(1)) // "a.b" sorts first
        #expect(prepared["x"] == .int(3))
        #expect(prepared["gc"] == .object(["k_v": .int(5)]))
        #expect(prepared[EventPreparation.droppedMarker] == .int(3))
    }

    @Test func extraAttributesAreDroppedAndCounted() {
        var many: [String: LogValue] = [:]
        for index in 0..<250 { many[String(format: "k%03d", index)] = .int(index) }
        let prepared = EventPreparation.attributes(many)
        #expect(prepared.count == 200) // 199 kept + the marker
        #expect(prepared[EventPreparation.droppedMarker] == .int(51))
        #expect(prepared["k000"] == .int(0)) // sorted: the first names stay
    }

    @Test func leavesAreFittedToTheServerRules() {
        let prepared = EventPreparation.attributes([
            "long": .string(String(repeating: "x", count: 5000)),
            "mixed": [1, "a", true],
            "nan": .double(.nan),
            "deep": ["a": ["b": ["c": ["d": 1]]]],
        ])
        if case .string(let text) = prepared["long"] { #expect(text.utf8.count == 1024) } else { Issue.record("long") }
        #expect(prepared["mixed"] == ["1", "a", "true"])
        #expect(prepared["nan"] == .null)
        // Level 4 is the deepest object; below that the value becomes a JSON string.
        #expect(prepared["deep"] == ["a": ["b": ["c": .string("{\"d\":1}")]]])
    }

    @Test func oversizedPayloadIsSummarised() {
        let big = LogValue.string(String(repeating: "y", count: 100_000))
        guard case .object(let summary) = EventPreparation.payload(big) else {
            Issue.record("expected a summary"); return
        }
        #expect(summary["lyrelog_truncated"] == true)
        #expect(EventPreparation.payload(["ok": 1]) == ["ok": 1])
    }

    @Test func wireLineMatchesTheIngestFormat() throws {
        let event = PendingEvent(
            id: UUID(uuidString: "6F1B2C3D-0000-4000-8000-000000000001")!,
            timestamp: Date(timeIntervalSince1970: 1_763_460_000.5),
            level: .warning, category: "daily", message: "daily_submit",
            attributes: ["latency_ms": 412, "gc": ["ok": true]],
            payload: ["raw": "x"], userID: "player-1", sessionID: "s-1")
        let resource = Resource(app_id: "com.example", app_version: "2.0", app_build: "1", os_name: "iOS",
                                os_version: "27.2.0", device_model: "iPhone18,1", locale: "es_ES", sdk: "t",
                                environment: "testflight", platform: "ios")
        let line = try WireEvent(event, installID: "i-1", resource: resource).encodedLine()
        #expect(!line.contains(0x0A))
        let json = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(json["event_id"] as? String == "6f1b2c3d-0000-4000-8000-000000000001")
        #expect(json["ts"] as? String == "2025-11-18T10:00:00.500Z")
        #expect(json["level"] as? String == "warning")
        #expect(json["category"] as? String == "daily")
        #expect(json["user_id"] as? String == "player-1")
        #expect((json["attrs"] as? [String: Any])?["latency_ms"] as? Int == 412)
        #expect((json["resource"] as? [String: Any])?["device_model"] as? String == "iPhone18,1")
    }

    @Test func sessionRotatesAfterInactivity() {
        var clock = SessionClock(timeout: 60)
        let start = Date()
        let first = clock.touch(at: start)
        #expect(clock.touch(at: start.addingTimeInterval(59)) == first)
        #expect(clock.touch(at: start.addingTimeInterval(59 + 61)) != first)
    }
}

struct EnvironmentTests {
    @Test func namesAreMadeValid() {
        #expect(Lyrelog.environmentName("Staging EU") == "staging-eu")
        #expect(Lyrelog.environmentName("internal") == "internal")
        #expect(Lyrelog.environmentName("  ") == nil)
        #expect(Lyrelog.environmentName(String(repeating: "a", count: 40))?.count == 32)
    }

    @Test func testsRunAsDevelopment() {
        // `swift test` builds Debug.
        #expect(Lyrelog.detectedEnvironment == "development")
    }
}
