import Foundation

extension Lyrelog {
    /// Log a Swift `Error` as the `exception` event every Lyrelog SDK sends (JavaScript's
    /// `captureException`, Python's `capture_exception`, Go's `CaptureError`): level `error`,
    /// attributes `error_type` (the full type name, or the domain of a plain `NSError`) and `error_message` (its description), and
    /// a payload with the description, the debug description, the `NSError` domain and code,
    /// and the underlying error when there is one. Your `attrs` are added; theirs win.
    public static func captureError(
        _ error: any Error,
        category: String? = nil,
        attrs: [String: LogValue] = [:],
        level: LogLevel = .error
    ) {
        let built = exceptionEvent(error)
        var attributes = attrs
        for (key, value) in built.attrs where attributes[key] == nil { attributes[key] = value }
        record(level, "exception", category: category, attrs: attributes, payload: built.payload)
    }

    static func exceptionEvent(_ error: any Error) -> (attrs: [String: LogValue], payload: LogValue) {
        let ns = error as NSError
        let description = String(describing: error)
        var payload: [String: LogValue] = [
            "description": .string(description),
            "debug_description": .string(String(reflecting: error)),
            "localized_description": .string(error.localizedDescription),
            "domain": .string(ns.domain),
            "code": .int(ns.code),
        ]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            payload["underlying"] = .object([
                "domain": .string(underlying.domain),
                "code": .int(underlying.code),
                "description": .string(underlying.localizedDescription),
            ])
        }
        // A Foundation error often arrives as a plain NSError: its domain says more.
        var typeName = String(reflecting: type(of: error))
        if typeName == "NSError" || typeName == "__C.NSError" || typeName.hasSuffix("SwiftNativeNSError") { typeName = ns.domain }
        return (["error_type": .string(typeName), "error_message": .string(description)],
                .object(payload))
    }
}

extension Lyrelog.Logger {
    /// `Lyrelog.captureError` in this logger's category.
    public func captureError(_ error: any Error, attrs: [String: Lyrelog.LogValue] = [:], level: Lyrelog.LogLevel = .error) {
        Lyrelog.captureError(error, category: category, attrs: attrs, level: level)
    }
}
