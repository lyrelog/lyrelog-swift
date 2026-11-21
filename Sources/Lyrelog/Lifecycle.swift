import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Going to the background is the last reliable moment to send: iOS may kill the app at any
/// time after that. Ask for a little background time, write everything to disk and upload.
/// iOS, iPadOS, tvOS and visionOS only: on macOS (and watchOS) there is no background flush;
/// events wait on disk and go with the next periodic upload or launch, or call
/// `await Lyrelog.flush()` yourself (e.g. on `NSApplication.willTerminateNotification`).
enum Lifecycle {
    static func install(_ engine: Engine) {
        #if canImport(UIKit) && !os(watchOS)
        Task { @MainActor in
            BackgroundFlusher.shared.observe(engine)
        }
        #endif
    }
}

/// Begins a background task around some work and ends it when the work returns or the system
/// expires it, whichever comes first. Generic over the id so it can be tested without UIKit.
@MainActor
final class BackgroundTaskTracker<ID: Equatable> {
    private let invalid: ID
    private let begin: (@escaping @MainActor @Sendable () -> Void) -> ID
    private let end: (ID) -> Void
    private(set) var current: ID

    init(invalid: ID, begin: @escaping (@escaping @MainActor @Sendable () -> Void) -> ID, end: @escaping (ID) -> Void) {
        self.invalid = invalid
        self.begin = begin
        self.end = end
        current = invalid
    }

    /// Runs `work` inside a background task, unless one is already running.
    func run(_ work: @escaping @MainActor () async -> Void) {
        guard current == invalid else { return }
        // Each finish names its own task: a flush that returns after its task expired (and a
        // newer one began) must not end the newer one.
        let box = IDBox<ID>()
        let id = begin { [weak self] in
            if let id = box.id { self?.finish(id) }
        }
        box.id = id
        current = id
        Task { @MainActor [weak self] in
            await work()
            self?.finish(id)
        }
    }

    private func finish(_ id: ID) {
        guard current == id, current != invalid else { return }
        end(id)
        current = invalid
    }
}

@MainActor
private final class IDBox<ID> {
    var id: ID?
}

#if canImport(UIKit) && !os(watchOS)
@MainActor
private final class BackgroundFlusher {
    static let shared = BackgroundFlusher()
    private var observer: (any NSObjectProtocol)?
    private let tracker = BackgroundTaskTracker<UIBackgroundTaskIdentifier>(
        invalid: .invalid,
        begin: { expire in
            UIApplication.shared.beginBackgroundTask(withName: "lyrelog-flush") {
                MainActor.assumeIsolated { expire() }
            }
        },
        end: { UIApplication.shared.endBackgroundTask($0) }
    )

    func observe(_ engine: Engine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self, weak engine] _ in
            // Weak: a stopped engine must not be kept alive (or flushed) by this observer.
            guard let engine else { return }
            MainActor.assumeIsolated {
                self?.tracker.run { await engine.flush() }
            }
        }
    }
}
#endif
