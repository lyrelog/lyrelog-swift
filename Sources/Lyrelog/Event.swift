import Foundation

/// An event as captured on the caller's thread: only cheap copies, no encoding yet.
struct PendingEvent: Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String?
    let message: String
    let attributes: [String: LogValue]
    let payload: LogValue?
    let userID: String?
    let sessionID: String
}

extension PendingEvent {
    /// About how much memory the event holds, for the intake's byte cap. Walks the values
    /// (not the bytes of each string: `utf8.count` is constant time for native strings).
    var estimatedBytes: Int {
        128 + message.utf8.count + (category?.utf8.count ?? 0) + (userID?.utf8.count ?? 0) + sessionID.utf8.count
            + attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.estimatedBytes }
            + (payload?.estimatedBytes ?? 0)
    }
}

extension LogValue {
    var estimatedBytes: Int {
        switch self {
        case .string(let text): return 16 + text.utf8.count
        case .int, .double, .bool, .null: return 16
        case .array(let items): return 16 + items.reduce(0) { $0 + $1.estimatedBytes }
        case .object(let fields): return 16 + fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.estimatedBytes }
        }
    }
}

/// The device and app, the same for every event of this launch.
struct Resource: Sendable, Encodable, Equatable {
    var app_id: String
    var app_version: String
    var app_build: String
    var os_name: String
    var os_version: String
    var device_model: String
    var locale: String
    var sdk: String
    var environment: String
    var platform: String
}

/// One NDJSON line, exactly what the ingest expects (lyrelog: internal/events/events.go, docs/ingest-api.md).
struct WireEvent: Encodable {
    let event_id: String
    let ts: String
    let level: String
    let category: String?
    let message: String
    let user_id: String?
    let install_id: String?
    let session_id: String?
    let attrs: [String: LogValue]?
    let payload: LogValue?
    let resource: Resource

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(_ event: PendingEvent, installID: String, resource: Resource,
         redaction: EventPreparation.Redaction = .defaults) {
        event_id = event.id.uuidString.lowercased()
        ts = event.timestamp.formatted(Self.timestampStyle)
        level = event.level.rawValue
        category = event.category.flatMap { $0.isEmpty ? nil : EventPreparation.resource($0) }
        message = EventPreparation.message(event.message)
        user_id = EventPreparation.identifier(event.userID)
        install_id = EventPreparation.identifier(installID)
        session_id = EventPreparation.identifier(event.sessionID)
        let prepared = EventPreparation.attributes(event.attributes, redaction: redaction)
        attrs = prepared.isEmpty ? nil : prepared
        payload = EventPreparation.payload(event.payload, redaction: redaction)
        self.resource = resource
    }

    /// One line of JSON, no trailing newline (JSONEncoder never emits newlines unless pretty-printing).
    func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
