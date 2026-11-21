import Foundation
import os

/// The SDK's own diagnostics (a dropped batch, a wrong endpoint), at debug level in the unified
/// log under the subsystem `com.lyrelog.sdk`, so they show in Console.app or Xcode without
/// ever reaching the app's own logs. Never the API key.
enum SDKLog {
    private static let logger = os.Logger(subsystem: "com.lyrelog.sdk", category: "lyrelog")
    private static let state = OSAllocatedUnfairLock(initialState: (said: Set<String>(), recent: [String]()))

    /// Logs `message` once per launch for each `key`.
    static func once(_ key: String, _ message: String) {
        let first = state.withLock { $0.said.insert(key).inserted }
        if first { say(message) }
    }

    /// Logs `message` every time: the caller decides when it is worth saying again.
    static func say(_ message: String) {
        state.withLock { state in
            state.recent.append(message)
            if state.recent.count > 50 { state.recent.removeFirst() }
        }
        logger.debug("\(message, privacy: .public)")
    }

    /// What was said lately (tests).
    static var recent: [String] { state.withLock { $0.recent } }
}
