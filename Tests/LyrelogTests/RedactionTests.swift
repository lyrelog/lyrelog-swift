import Foundation
import Testing
@testable import Lyrelog

/// docs/sdk-spec.md rule 9, the rule every Lyrelog SDK shares (Python's `_prepare.py`): a field
/// whose name, lowercased and without `-`, `_`, `.` or spaces, is one of the keys or ends with
/// one is sent as "[redacted]".
struct RedactionTests {
    let redacted = LogValue.string("[redacted]")

    @Test func namesAreNormalisedAndMatchAtTheEnd() {
        let rule = EventPreparation.Redaction.defaults
        for name in ["password", "Authorization", "X-Api-Key", "api_key", "apiKey", "csrf_token", "Set-Cookie",
                     "user_token", "client.secret", "Private Key", "aws_access_key", "credentials", "passwd",
                     "request_signature", "TOKEN"] {
            #expect(rule.isSecret(name), "\(name) should be redacted")
        }
        for name in ["token_count", "max_tokens", "user", "secrets_count", "cookies", "author", "keys", "day_key", ""] {
            #expect(!rule.isSecret(name), "\(name) should be kept")
        }
    }

    @Test func attributesAreRedactedAtAnyDepth() {
        let prepared = EventPreparation.attributes([
            "password": "hunter2",
            "X-Api-Key": "abc",
            "token_count": 12,
            "request": ["headers": ["Authorization": "Bearer xyz", "Accept": "json"]],
            "credentials": ["user": "a", "pass": "b"], // a secret object goes whole
        ])
        #expect(prepared["password"] == redacted)
        #expect(prepared["X-Api-Key"] == redacted)
        #expect(prepared["token_count"] == .int(12))
        #expect(prepared["request"] == ["headers": ["Authorization": redacted, "Accept": "json"]])
        #expect(prepared["credentials"] == redacted)
    }

    @Test func attributeArraysOfObjectsAreRedactedBeforeBecomingStrings() throws {
        let prepared = EventPreparation.attributes(["headers": [["name": "a", "token": "t1"], ["cookie": "c1"]]])
        guard case .array(let items) = prepared["headers"] else { Issue.record("headers"); return }
        let text = items.map { EventPreparation.stringForm($0) }.joined()
        #expect(!text.contains("t1") && !text.contains("c1"))
        #expect(text.contains("[redacted]"))
    }

    @Test func objectsDeeperThanTheLimitAreRedactedBeforeBecomingStrings() {
        // Level 4 is the deepest object; below that the value becomes a JSON string.
        let prepared = EventPreparation.attributes(["a": ["b": ["c": ["d": ["secret": "s3cr3t", "ok": 1]]]]])
        guard case .object(let a) = prepared["a"], case .object(let b) = a["b"], case .object(let c) = b["c"],
              case .string(let d) = c["d"] else {
            Issue.record("shape"); return
        }
        #expect(!d.contains("s3cr3t"))
        #expect(d.contains("[redacted]"))
    }

    @Test func payloadIsRedactedInNestedObjectsAndArrays() {
        let payload = EventPreparation.payload([
            "response": ["session": ["refresh_token": "r1", "expires": 3600]],
            "attempts": [["password": "p1", "n": 1], ["n": 2], "plain"],
            "max_tokens": 100,
        ])
        #expect(payload == [
            "response": ["session": ["refresh_token": redacted, "expires": 3600]],
            "attempts": [["password": redacted, "n": 1], ["n": 2], "plain"],
            "max_tokens": 100,
        ])
    }

    @Test func redactionComesBeforeTheOversizedPayloadPreview() {
        // The secret is first in the encoded JSON ("a" sorts first), so it would be in the preview.
        let payload: LogValue = ["a_token": "SECRET-IN-PREVIEW", "z": .string(String(repeating: "y", count: 100_000))]
        guard case .object(let summary) = EventPreparation.payload(payload),
              case .string(let preview) = summary["preview"] else {
            Issue.record("expected a summary"); return
        }
        #expect(!preview.contains("SECRET-IN-PREVIEW"))
    }

    @Test func redactionComesBeforeStringTruncation() {
        // A long secret is replaced, not cut to 1 KiB and kept.
        let prepared = EventPreparation.attributes(["token": .string(String(repeating: "s", count: 5000))])
        #expect(prepared["token"] == redacted)
    }

    @Test func theListCanBeReplacedOrTurnedOff() {
        let custom = EventPreparation.Redaction(["Session-ID"])
        let replaced = EventPreparation.attributes(["session_id": "abc", "password": "kept"], redaction: custom)
        #expect(replaced["session_id"] == redacted)
        #expect(replaced["password"] == "kept")

        let off = EventPreparation.Redaction([])
        #expect(EventPreparation.attributes(["password": "kept"], redaction: off)["password"] == "kept")
        #expect(EventPreparation.payload(["token": "kept"], redaction: off) == ["token": "kept"])
    }

    @Test func theConfigurationExposesTheDefaults() {
        #expect(Configuration.defaultRedactedKeys == [
            "authorization", "cookie", "password", "passwd", "secret", "token", "apikey", "privatekey",
            "credential", "credentials", "accesskey", "signature",
        ])
        #expect(Configuration(apiKey: "k").redactedKeys == nil)
        #expect(EventPreparation.Redaction(nil) == .defaults)
    }

    @Test func theEngineRedactsWhatItQueuesAndHonoursTheConfiguration() async throws {
        let transport = GatedTransport(open: true)
        let engine = Engine(configuration: testConfiguration(), transport: transport, root: temporaryDirectory())
        defer { engine.stop() }
        engine.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "login",
                                    attributes: ["password": "hunter2"], payload: ["auth": ["access_token": "a1"]],
                                    userID: nil, sessionID: "s"))
        await engine.flush()
        let line = try #require(transport.lines.first)
        #expect((line["attrs"] as? [String: Any])?["password"] as? String == "[redacted]")
        #expect(((line["payload"] as? [String: Any])?["auth"] as? [String: Any])?["access_token"] as? String == "[redacted]")

        var configuration = testConfiguration()
        configuration.redactedKeys = []
        let clearTransport = GatedTransport(open: true)
        let clear = Engine(configuration: configuration, transport: clearTransport, root: temporaryDirectory())
        defer { clear.stop() }
        clear.enqueue(PendingEvent(id: UUID(), timestamp: Date(), level: .info, category: "test", message: "login",
                                   attributes: ["password": "hunter2"], payload: nil, userID: nil, sessionID: "s"))
        await clear.flush()
        #expect((clearTransport.lines.first?["attrs"] as? [String: Any])?["password"] as? String == "hunter2")
    }
}
