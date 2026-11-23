import Foundation
import os
import Testing
@testable import Lyrelog

/// The dispatch queue the caller runs on ("com.apple.root.default-qos.cooperative" on Swift's
/// shared pool).
func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// What changed before 1.0.0: where the disk work runs.
struct DiskThreadTests {
    // The queue was a plain actor, so its blocking file calls (open, write, list, delete) ran on
    // Swift's shared cooperative pool, a thread per core shared with the app's own tasks: a slow
    // disk held a thread the app's async code needed. Now they run on the SDK's own queue.
    @Test func theQueueTouchesTheDiskOffTheCooperativePool() async throws {
        let labels = OSAllocatedUnfairLock<[String]>(initialState: [])
        let queue = DiskQueue(root: temporaryDirectory(),
                              limits: .init(maxFileBytes: 64 * 1024, maxFileEvents: 100, maxTotalBytes: 1_000_000, maxAge: 3600),
                              openHandle: { url in
                                  labels.withLock { $0.append(currentQueueLabel()) }
                                  return try FileHandle(forWritingTo: url)
                              })
        await queue.append(Data("{\"n\":1}".utf8), to: .ready)
        await queue.seal()
        #expect(await queue.readyBatches().count == 1)
        #expect(labels.withLock { $0 } == ["com.lyrelog.disk"])
    }

    @Test func theInstallIDIsReadOnTheDiskQueue() async {
        let root = temporaryDirectory()
        let queue = makeQueue(root: root)
        let identity = InstallIdentity(directory: root)
        let consent = ConsentGate(.granted)
        let id = await identity.resolve(unless: consent, on: queue)
        #expect(id != nil)
        #expect(await identity.resolve(unless: consent, on: queue) == id)
        #expect(await queue.onDisk { currentQueueLabel() } == "com.lyrelog.disk")
    }
}

// The shared Lyrelog, so these run in the serialized suite.
extension ScreenTests {
    // `start` made the queue's folders while the app waited for it, on the calling thread
    // (usually the main one, at launch). Now it touches no disk: the folders are made by the
    // disk queue when the first event is written.
    @Test func startTouchesNoDisk() async {
        let root = temporaryDirectory().appendingPathComponent("queue", isDirectory: true)
        let transport = GatedTransport(open: true)
        Lyrelog.start(testConfiguration(), transport: transport, root: root)
        defer { Lyrelog.stopNow() }
        #expect(!FileManager.default.fileExists(atPath: root.path), "start made folders on the calling thread")
        Lyrelog.info("first")
        await Lyrelog.flush()
        #expect(transport.messages == ["first"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
    }
}
