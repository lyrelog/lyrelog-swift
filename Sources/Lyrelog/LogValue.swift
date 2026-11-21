import Foundation

extension Lyrelog {
    /// A value for an attribute or payload. Write literals directly:
    /// `["day_key": "20261118", "latency_ms": 412, "ok": true, "tags": ["a", "b"]]`.
    /// For variables use the cases (`.int(ms)`) or `LogValue(x)`.
    public enum LogValue: Sendable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case array([LogValue])
        case object([String: LogValue])
        case null

        public init(_ value: String) { self = .string(value) }
        public init(_ value: some BinaryInteger) { self = .int(Int(clamping: value)) }
        public init(_ value: some BinaryFloatingPoint) { self = .double(Double(value)) }
        public init(_ value: Bool) { self = .bool(value) }
        /// A duration as milliseconds (a `double`), like every `*_ms` attribute.
        public init(_ value: Duration) {
            let (seconds, attoseconds) = value.components
            self = .double(Double(seconds) * 1000 + Double(attoseconds) / 1e15)
        }
    }
}

// Internal: outside this module the type is only `Lyrelog.LogValue` (or `Lyrelog.Value`).
typealias LogValue = Lyrelog.LogValue

extension Lyrelog.LogValue: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension Lyrelog.LogValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension Lyrelog.LogValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension Lyrelog.LogValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension Lyrelog.LogValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Lyrelog.LogValue...) { self = .array(elements) }
}

extension Lyrelog.LogValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Lyrelog.LogValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension Lyrelog.LogValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension Lyrelog.LogValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value):
            // JSON has no NaN or infinity.
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
