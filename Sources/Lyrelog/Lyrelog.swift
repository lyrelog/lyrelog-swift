import Foundation
import os

/// Lyrelog: structured logs from your app to Lyrelog, a hosted log service
/// (`https://ingest.lyrelog.com` unless the configuration names another endpoint).
///
/// ```swift
/// Lyrelog.start(Lyrelog.Configuration(apiKey: "lyr_ing_..."))
/// Lyrelog.setUser("player-123")
/// Lyrelog.info("level_completed", attrs: ["level": 12, "duration_ms": 412])
///
/// let sync = Lyrelog.Logger(category: "sync")  // the area of the app, like OSLog's
/// sync.warning("sync_conflict", attrs: ["records": 2])
/// Lyrelog.error("cloud_save_failed", attrs: ["status": 422], payload: ["response": "..."])
/// ```
///
/// Logging never blocks and never throws: the event is copied, handed to a background writer
/// that puts it on disk, and sent in batches. Events logged before `start` are ignored;
/// `setUser` and `setConsent` before `start` are kept and applied when it runs.
public enum Lyrelog {
    /// This SDK's version (the git tag). Sent as `resource.sdk` and the User-Agent; the README's
    /// install line uses the same number (a test keeps them in step).
    public static let version = "1.1.0"

    private struct Runtime: Sendable {
        let engine: Engine
        let minimumLevel: LogLevel
        let mirror: os.Logger?
        var userID: String?
        var session: SessionClock
        let attachScreen: Bool
        var screen: String?
        var screenSince: Date?
    }

    private static let state = OSAllocatedUnfairLock<Runtime?>(initialState: nil)

    /// `setUser` and `setConsent` called before `start` (or while it builds the engine), applied
    /// when it runs.
    private struct Early: Sendable {
        var userID: String??
        var consent: Consent?
        /// A `start` is building its engine: another one is ignored.
        var starting = false
    }

    private static let early = OSAllocatedUnfairLock(initialState: Early())

    /// How long `await stop()` waits for its last upload.
    static let stopFlushTimeout: Duration = .seconds(2)

    /// Called while `start` builds the engine, outside every lock (tests).
    static let whileBuilding = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    // MARK: - Setup

    /// Start once, as early as possible (app init). A second call is ignored.
    public static func start(_ configuration: Configuration) {
        start(configuration, transport: URLSessionTransport(), root: nil)
    }

    static func start(_ configuration: Configuration, transport: any HTTPTransport, root: URL?) {
        // Claim the start, then build the engine (directories, file lookups) without holding
        // the lock every log call takes: a log on another thread never waits for the disk.
        let claimed = state.withLock { runtime -> Early? in
            guard runtime == nil else { return nil }
            return early.withLock { early -> Early? in
                guard !early.starting else { return nil }
                early.starting = true
                return early
            }
        }
        guard let said = claimed else { return }
        // What the app said before starting wins over the configuration: it is newer.
        let configuration = {
            var configuration = configuration
            if let consent = said.consent { configuration.consent = consent }
            return configuration
        }()
        whileBuilding.withLock { $0 }?()
        let engine = Engine(configuration: configuration, transport: transport, root: root)
        let mirror = configuration.mirrorToOSLog
            ? os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "lyrelog", category: "lyrelog")
            : nil
        // Swap it in, with what was said while it was built.
        let later = state.withLock { runtime -> Consent? in
            let now = early.withLock { early in
                defer { early = Early() }
                return early
            }
            runtime = Runtime(
                engine: engine,
                minimumLevel: configuration.minimumLevel,
                mirror: mirror,
                userID: now.userID ?? nil,
                session: SessionClock(timeout: configuration.sessionTimeout.seconds),
                attachScreen: configuration.attachScreen,
                screen: nil,
                screenSince: nil
            )
            return now.consent != said.consent ? now.consent : nil
        }
        if let later { engine.setConsent(later) }
        Lifecycle.install(engine)
        if configuration.captureDiagnostics {
            CrashReporter.install()
            Diagnostics.install()
        }
    }

    /// Send what was logged (waiting at most 2 seconds for it), then stop and forget the
    /// configuration. What couldn't be sent stays on disk for the next launch. After this,
    /// `start` can be called again.
    public static func stop() async {
        guard let engine = state.withLock({ $0?.engine }) else { return }
        await withDeadline(stopFlushTimeout) { await engine.flush() }
        stop(engine)
    }

    /// Stop at once, without sending: events still in memory are lost, those on disk stay for
    /// the next launch. For a synchronous context; prefer `await Lyrelog.stop()`. After this,
    /// `start` can be called again.
    public static func stopNow() {
        guard let engine = state.withLock({ $0?.engine }) else { return }
        stop(engine)
    }

    private static func stop(_ engine: Engine) {
        let current = state.withLock { runtime -> Bool in
            guard runtime?.engine === engine else { return false }
            runtime = nil
            return true
        }
        if current { engine.stop() }
    }

    /// Attach your own player or account id to every following event. `nil` clears it.
    /// Called before `start`, it applies from the start.
    public static func setUser(_ id: String?) {
        state.withLock { runtime in
            if runtime != nil {
                runtime!.userID = id
            } else {
                early.withLock { $0.userID = .some(id) }
            }
        }
    }

    /// Change the person's choice at any moment; it applies at once (a denial deletes what is
    /// on the device and records nothing more, including what was logged a moment before but
    /// not yet written). Called before `start`, it wins over `Configuration.consent`.
    public static func setConsent(_ consent: Consent) {
        let engine = state.withLock { runtime -> Engine? in
            if runtime == nil { early.withLock { $0.consent = consent } }
            return runtime?.engine
        }
        engine?.setConsent(consent)
    }

    /// Write everything logged so far to disk and try to send it now.
    public static func flush() async {
        await state.withLock { $0?.engine }?.flush()
    }

    /// Say which screen the person is on: logs `screen_viewed` (with the screen before and how
    /// long they stayed on it) and, unless turned off, tags every following event with `screen`.
    /// In SwiftUI, `.lyrelogScreen("Settings")` does it on appear.
    public static func screen(_ name: String, attrs: [String: LogValue] = [:]) {
        let now = Date()
        let previous = state.withLock { runtime -> (String?, Date?)? in
            guard runtime != nil, runtime!.screen != name else { return nil }
            defer {
                runtime!.screen = name
                runtime!.screenSince = now
            }
            return (runtime!.screen, runtime!.screenSince)
        }
        guard let (before, since) = previous else { return }
        var attributes = attrs
        attributes["screen"] = .string(name)
        if let before { attributes["previous_screen"] = .string(before) }
        if let since { attributes["seconds_on_previous"] = .double((now.timeIntervalSince(since) * 10).rounded() / 10) }
        record(.info, "screen_viewed", category: "navigation", attrs: attributes)
    }

    /// The current session id, e.g. to show in a support screen.
    public static var sessionID: String? {
        state.withLock { $0?.session.id }
    }

    // MARK: - Logging

    public static func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        category: String? = nil,
        attrs: [String: LogValue] = [:],
        payload: LogValue? = nil
    ) {
        record(level, message(), category: category, attrs: attrs, payload: payload)
    }

    /// Everything goes through here. `at` and `id` are for reports that arrive later (a crash
    /// reported on the next launch): they keep their own time, have no session, and their id is
    /// derived from the report so a report delivered twice is stored once.
    static func record(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        category: String? = nil,
        attrs: [String: LogValue] = [:],
        payload: LogValue? = nil,
        at timestamp: Date? = nil,
        id: UUID? = nil
    ) {
        let now = Date()
        let late = timestamp != nil
        let captured = state.withLock { runtime -> (Engine, String?, String, os.Logger?, String?)? in
            guard runtime != nil, level >= runtime!.minimumLevel else { return nil }
            let session = late ? "" : runtime!.session.touch(at: now)
            let screen = runtime!.attachScreen && !late ? runtime!.screen : nil
            return (runtime!.engine, runtime!.userID, session, runtime!.mirror, screen)
        }
        guard let (engine, userID, sessionID, mirror, screen) = captured else { return }
        // Cut now (cheap: only the kept prefix is walked), so a huge message isn't held while
        // it waits for the writer.
        let text = EventPreparation.truncated(message(), maxBytes: EventPreparation.maxMessageBytes)
        var attributes = attrs
        if let screen, attributes["screen"] == nil { attributes["screen"] = .string(screen) }
        engine.enqueue(PendingEvent(id: id ?? UUID(), timestamp: timestamp ?? now, level: level, category: category, message: text,
                                    attributes: attributes, payload: payload, userID: userID, sessionID: sessionID))
        if let category {
            mirror?.log(level: level.osLogType, "[\(category, privacy: .public)] \(text, privacy: .public)")
        } else {
            mirror?.log(level: level.osLogType, "\(text, privacy: .public)")
        }
    }

    public static func trace(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.trace, message(), category: category, attrs: attrs, payload: payload)
    }

    public static func debug(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.debug, message(), category: category, attrs: attrs, payload: payload)
    }

    public static func info(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.info, message(), category: category, attrs: attrs, payload: payload)
    }

    public static func notice(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.notice, message(), category: category, attrs: attrs, payload: payload)
    }

    public static func warning(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.warning, message(), category: category, attrs: attrs, payload: payload)
    }

    public static func error(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.error, message(), category: category, attrs: attrs, payload: payload)
    }

    public static func critical(_ message: @autoclosure () -> String, category: String? = nil, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
        log(.critical, message(), category: category, attrs: attrs, payload: payload)
    }
}

extension Lyrelog {
    /// A logger for one area of the app: every event it records carries `category`.
    public struct Logger: Sendable {
        public let category: String

        public init(category: String) {
            self.category = category
        }

        public func log(_ level: LogLevel, _ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            Lyrelog.log(level, message(), category: category, attrs: attrs, payload: payload)
        }

        public func trace(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.trace, message(), attrs: attrs, payload: payload)
        }

        public func debug(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.debug, message(), attrs: attrs, payload: payload)
        }

        public func info(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.info, message(), attrs: attrs, payload: payload)
        }

        public func notice(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.notice, message(), attrs: attrs, payload: payload)
        }

        public func warning(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.warning, message(), attrs: attrs, payload: payload)
        }

        public func error(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.error, message(), attrs: attrs, payload: payload)
        }

        public func critical(_ message: @autoclosure () -> String, attrs: [String: LogValue] = [:], payload: LogValue? = nil) {
            log(.critical, message(), attrs: attrs, payload: payload)
        }
    }
}

extension Lyrelog.LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: .debug
        case .info, .notice: .info
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }
}
