import Foundation

/// Fitting an event inside the ingest's limits (lyrelog: internal/events/events.go, docs/ingest-api.md) *before* it is queued,
/// so a line is never rejected later for something the SDK could have fixed. Pure functions.
///
/// Policy: never drop an event for its shape. Long strings are cut on a character boundary,
/// extra attributes (and names that collide once cleaned) are dropped and counted in
/// `lyrelog_dropped_attrs`, an oversized payload
/// is replaced by a short summary.
enum EventPreparation {
    static let maxMessageBytes = 2048
    static let maxIdBytes = 128
    static let maxResourceBytes = 64
    static let maxAttributes = 200
    static let maxAttributeStringBytes = 1024
    static let maxArrayItems = 64
    static let maxDepth = 4
    static let maxPayloadBytes = 64 * 1024
    static let droppedMarker = "lyrelog_dropped_attrs"
    /// The server rejects a longer line on its own; such an event is dropped (and counted)
    /// before it is queued. Only reachable with many large string arrays.
    static let maxLineBytes = 1 << 20

    static func message(_ text: String) -> String {
        let cut = truncated(text, maxBytes: maxMessageBytes)
        return cut.isEmpty ? "(empty)" : cut
    }

    static func identifier(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return truncated(text, maxBytes: maxIdBytes)
    }

    static func resource(_ text: String) -> String {
        truncated(text, maxBytes: maxResourceBytes)
    }

    static func attributes(_ input: [String: LogValue], redaction: Redaction = .defaults) -> [String: LogValue] {
        let input = redaction.apply(input)
        var budget = maxAttributes - 1 // keep room for the dropped marker
        var dropped = 0
        let result = object(input, depth: 1, budget: &budget, dropped: &dropped)
        guard dropped > 0 else { return result }
        var marked = result
        marked[droppedMarker] = .int(dropped)
        return marked
    }

    static func payload(_ value: LogValue?, redaction: Redaction = .defaults) -> LogValue? {
        guard let raw = value else { return nil }
        let value = redaction.apply(raw)
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        guard data.count > maxPayloadBytes else { return value }
        let preview = String(decoding: data.prefix(1024), as: UTF8.self)
        return .object([
            "lyrelog_truncated": true,
            "bytes": .int(data.count),
            "preview": .string(truncated(preview, maxBytes: 1024)),
        ])
    }

    // MARK: - Redaction

    /// Secrets never leave the device (docs/sdk-spec.md rule 9, the same rule in every Lyrelog
    /// SDK): a field whose name, lowercased and without `-`, `_`, `.` or spaces, is one of the
    /// keys or ends with one is sent as "[redacted]", whatever its value (a whole object too).
    /// "X-Api-Key", "csrf_token" and "Set-Cookie" match; "token_count" and "max_tokens" don't.
    /// Applied at every depth of the attributes and the payload, inside arrays too, before
    /// anything is cut, so no secret survives in a truncated string or a payload preview.
    struct Redaction: Sendable, Equatable {
        static let marker = LogValue.string("[redacted]")
        static let defaults = Redaction(nil)

        /// The normalised keys; empty turns redaction off.
        let keys: Set<String>

        /// `nil` is `Configuration.defaultRedactedKeys`; an empty list turns redaction off.
        init(_ keys: [String]?) {
            self.keys = Set((keys ?? Configuration.defaultRedactedKeys).map(Self.normal).filter { !$0.isEmpty })
        }

        static func normal(_ name: String) -> String {
            String(name.lowercased().unicodeScalars.filter { !"-_. ".unicodeScalars.contains($0) })
        }

        func isSecret(_ name: String) -> Bool {
            guard !keys.isEmpty else { return false }
            let normal = Self.normal(name)
            guard !normal.isEmpty else { return false }
            return keys.contains { normal.hasSuffix($0) }
        }

        func apply(_ object: [String: LogValue]) -> [String: LogValue] {
            guard !keys.isEmpty else { return object }
            var out = object
            for (key, value) in object {
                out[key] = isSecret(key) ? Self.marker : apply(value)
            }
            return out
        }

        func apply(_ value: LogValue) -> LogValue {
            guard !keys.isEmpty else { return value }
            switch value {
            case .object(let object): return .object(apply(object))
            case .array(let items): return .array(items.map(apply))
            case .string, .int, .double, .bool, .null: return value
            }
        }
    }

    // MARK: - Attributes

    private static func object(
        _ input: [String: LogValue], depth: Int, budget: inout Int, dropped: inout Int
    ) -> [String: LogValue] {
        var out: [String: LogValue] = [:]
        for key in input.keys.sorted() {
            let name = attributeName(key)
            let value = input[key]!
            // `a.b` and `a_b`, or `_x` and `x`, become the same name: keep the first (in sorted
            // order, so it is always the same one) and count the rest.
            guard out[name] == nil else {
                dropped += leafCount(value)
                continue
            }
            switch value {
            case .object(let nested) where depth < maxDepth:
                let child = object(nested, depth: depth + 1, budget: &budget, dropped: &dropped)
                if !child.isEmpty { out[name] = .object(child) }
            default:
                guard budget > 0 else { dropped += leafCount(value); continue }
                budget -= 1
                out[name] = leaf(value)
            }
        }
        return out
    }

    private static func leaf(_ value: LogValue) -> LogValue {
        switch value {
        case .string(let text):
            return .string(truncated(text, maxBytes: maxAttributeStringBytes))
        case .double(let number):
            return number.isFinite ? value : .null
        case .int, .bool, .null:
            return value
        case .array(let items):
            // Attribute arrays hold strings only.
            return .array(items.prefix(maxArrayItems).map { .string(truncated(stringForm($0), maxBytes: maxAttributeStringBytes)) })
        case .object:
            // Deeper than maxDepth: keep it as a JSON string instead of losing it.
            return .string(truncated(stringForm(value), maxBytes: maxAttributeStringBytes))
        }
    }

    private static func leafCount(_ value: LogValue) -> Int {
        if case .object(let nested) = value { return nested.values.reduce(0) { $0 + leafCount($1) } }
        return 1
    }

    /// Lowercase-insensitive names are fine; dots would mean nesting and a leading underscore
    /// is reserved, so both are rewritten.
    static func attributeName(_ key: String) -> String {
        var name = key.replacingOccurrences(of: ".", with: "_")
        while name.hasPrefix("_") { name.removeFirst() }
        if name.isEmpty { name = "key" }
        return truncated(name, maxBytes: 128)
    }

    static func stringForm(_ value: LogValue) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .null: return "null"
        case .array, .object:
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Cut to at most `maxBytes` of UTF-8 without splitting a character. A first character
    /// longer than that on its own (a letter with hundreds of combining marks) is cut between
    /// its scalars instead, so the result is never empty: an empty attribute name would get the
    /// whole line rejected.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > maxBytes { break }
            bytes += size
            end = text.index(after: index)
        }
        if end == text.startIndex {
            var scalars = String.UnicodeScalarView()
            bytes = 0
            for scalar in text.unicodeScalars {
                let size = UTF8.width(scalar)
                if bytes + size > maxBytes { break }
                bytes += size
                scalars.append(scalar)
            }
            return String(scalars)
        }
        return String(text[..<end])
    }
}
