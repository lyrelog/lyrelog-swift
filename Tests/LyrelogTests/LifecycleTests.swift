import Foundation
import Testing
@testable import Lyrelog

@MainActor
struct LifecycleTests {
    /// The system expires task 1; the app goes to the background again (task 2); then the old
    /// flush finally returns. It must not end task 2.
    @Test func aLateFinishNeverEndsANewerTask() async {
        var nextID = 0
        var ended: [Int] = []
        var expire: [Int: () -> Void] = [:]
        let tracker = BackgroundTaskTracker<Int>(invalid: 0, begin: { onExpire in
            nextID += 1
            expire[nextID] = onExpire
            return nextID
        }, end: { ended.append($0) })

        let firstGate = GatedTransport()
        tracker.run { _ = try? await firstGate.send(URLRequest(url: URL(string: "https://a.test")!)) }
        #expect(tracker.current == 1)
        expire[1]?()
        #expect(ended == [1])

        let secondGate = GatedTransport()
        tracker.run { _ = try? await secondGate.send(URLRequest(url: URL(string: "https://a.test")!)) }
        #expect(tracker.current == 2)

        firstGate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ended == [1], "the first flush returning late must not end task 2")
        #expect(tracker.current == 2)

        secondGate.open()
        for _ in 0..<200 where ended != [1, 2] { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(ended == [1, 2])
        #expect(tracker.current == 0)
    }
}
