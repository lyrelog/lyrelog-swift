import Foundation

extension Lyrelog {
    /// Requests your app makes, as events: method, host, a path with ids folded to `:id`, status,
    /// duration and size. Never the query string, headers or body.
    public enum Network {
        /// Record a request you made yourself. 2xx and 3xx are `debug`, 4xx `warning`, 5xx and
        /// failures `error`.
        ///
        /// `route` is the endpoint's template (`"/players/:id/stats"`), the surest way to keep ids
        /// out: when given it is sent as `path` instead of the folded URL path. A query or
        /// fragment in it is cut off.
        public static func record(
            _ request: URLRequest,
            response: URLResponse?,
            error: (any Error)?,
            duration: Duration,
            bytes: Int? = nil,
            route: String? = nil,
            category: String = "network"
        ) {
            let built = event(request, response: response, error: error, duration: duration, bytes: bytes, route: route)
            Lyrelog.record(built.level, built.message, category: category, attrs: built.attrs)
        }

        static func event(
            _ request: URLRequest, response: URLResponse?, error: (any Error)?, duration: Duration, bytes: Int?, route: String?
        ) -> (level: LogLevel, message: String, attrs: [String: LogValue]) {
            var attrs: [String: LogValue] = [
                "method": .string(request.httpMethod ?? "GET"),
                "duration_ms": .int(milliseconds(duration)),
            ]
            if let url = request.url, let host = url.host() { attrs["host"] = .string(host) }
            if let route {
                let template = route.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" } ?? ""
                attrs["path"] = .string(template.isEmpty ? "/" : String(template))
            } else if let url = request.url {
                attrs["path"] = .string(path(url))
            }
            if let bytes { attrs["bytes"] = .int(bytes) }
            if let error {
                let ns = error as NSError
                attrs["error_domain"] = .string(ns.domain)
                attrs["error_code"] = .int(ns.code)
                let level: LogLevel = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled ? .debug : .error
                return (level, "http_request_failed", attrs)
            }
            if let status = (response as? HTTPURLResponse)?.statusCode {
                attrs["status"] = .int(status)
                let level: LogLevel = status >= 500 ? .error : status >= 400 ? .warning : .debug
                return (level, status >= 400 ? "http_request_failed" : "http_request", attrs)
            }
            return (.debug, "http_request", attrs)
        }

        /// Whole milliseconds, clamped: `Int(Double)` traps out of range, and a duration the app
        /// measured wrong must not take the app down.
        static func milliseconds(_ duration: Duration) -> Int {
            let value = (duration.seconds * 1000).rounded(.towardZero)
            guard value.isFinite else { return 0 }
            if value >= Double(Int.max) { return Int.max }
            if value <= Double(Int.min) { return Int.min }
            return Int(value)
        }

        /// The path with every part that could identify someone or something folded to `:id`,
        /// so requests group by endpoint and carry no ids. Never the query or fragment.
        ///
        /// A segment is folded when it holds a digit or any of `@ : . % = + ~` (numbers, UUIDs,
        /// `G:123` player ids, emails, JWTs, percent-encoded values, `key=value`), when it is 12
        /// or more characters in mixed case (a token like `AbCdEfGhIjKl`), or 24 or more without
        /// a `-` or `_` word break. Version segments (`v1`, `v2`) stay. The heuristic can fold
        /// a real word (`feed.json`) or miss an id made of lowercase words: pass `route` when
        /// you know the template.
        static func path(_ url: URL) -> String {
            let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
                let s = String(part)
                return s.isEmpty || keep(s) ? s : ":id"
            }
            let joined = parts.joined(separator: "/")
            return joined.isEmpty ? "/" : joined
        }

        private static let marks: Set<Character> = ["@", ":", ".", "%", "=", "+", "~"]

        private static func keep(_ segment: String) -> Bool {
            if segment.count <= 4, segment.first == "v", segment.dropFirst().allSatisfy(\.isASCII), segment.dropFirst().allSatisfy(\.isNumber),
               segment.count > 1 {
                return true
            }
            if segment.contains(where: { $0.isNumber || marks.contains($0) }) { return false }
            if segment.count >= 12, segment.contains(where: \.isUppercase), segment.contains(where: \.isLowercase) { return false }
            if segment.count >= 24, !segment.contains("-"), !segment.contains("_") { return false }
            return true
        }
    }
}

extension URLSession {
    /// `data(for:)` that also records the request with `Lyrelog.Network`.
    /// `route` is the endpoint's template (`"/players/:id/stats"`); see `Lyrelog.Network.record`.
    public func loggedData(for request: URLRequest, route: String? = nil, category: String = "network") async throws -> (Data, URLResponse) {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await data(for: request)
            Lyrelog.Network.record(request, response: response, error: nil, duration: clock.now - start, bytes: data.count,
                                   route: route, category: category)
            return (data, response)
        } catch {
            Lyrelog.Network.record(request, response: nil, error: error, duration: clock.now - start, route: route, category: category)
            throw error
        }
    }
}
