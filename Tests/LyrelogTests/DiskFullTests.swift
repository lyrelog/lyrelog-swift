import Foundation
import Testing
@testable import Lyrelog

/// A file handle whose writes start failing after `failAfter` successful ones, like a disk
/// that fills up.
final class FailingHandle: QueueFileHandle, @unchecked Sendable {
    private let real: FileHandle
    private var writes = 0
    let failAfter: Int

    init(url: URL, failAfter: Int) throws {
        real = try FileHandle(forWritingTo: url)
        self.failAfter = failAfter
    }

    func seekToEnd() throws -> UInt64 { try real.seekToEnd() }

    func write<T: DataProtocol>(contentsOf data: T) throws {
        writes += 1
        if writes > failAfter {
            // A partial write, then the error a full disk gives.
            try real.write(contentsOf: Data(data).prefix(3))
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try real.write(contentsOf: data)
    }

    func truncate(atOffset offset: UInt64) throws { try real.truncate(atOffset: offset) }
    func close() throws { try real.close() }
}

struct DiskFullTests {
    @Test func aFailingWriteDropsTheEventAndKeepsTheFileValid() async throws {
        let root = temporaryDirectory()
        let queue = DiskQueue(root: root, limits: .init(maxFileBytes: 64 * 1024, maxFileEvents: 100,
                                                        maxTotalBytes: 1_000_000, maxAge: 3600),
                              openHandle: { try FailingHandle(url: $0, failAfter: 2) })
        for index in 0..<4 { await queue.append(Data("{\"n\":\(index)}".utf8), to: .ready) }
        #expect(await queue.droppedEvents == 1)
        // The file that failed was closed with only its whole lines; the next event opened a new one.
        await queue.seal()
        let batches = await queue.readyBatches()
        let text = try batches.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }.joined()
        #expect(text == "{\"n\":0}\n{\"n\":1}\n{\"n\":3}\n")
    }

    /// The real thing: a 2 MB disk image filled to the brim. With the legacy FileHandle API
    /// this killed the process with "No space left on device".
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func aFullDiskNeverCrashes() async throws {
        let work = temporaryDirectory()
        let image = work.appendingPathComponent("full.dmg")
        let mount = work.appendingPathComponent("mnt")
        guard run("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "lyrelogfull", image.path]),
              run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mount.path, image.path]) else {
            return // no disk images here (a sandbox): the injected test above covers the logic
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let queue = DiskQueue(root: mount.appendingPathComponent("lyrelog"),
                              limits: .init(maxFileBytes: 512 * 1024, maxFileEvents: 100_000,
                                            maxTotalBytes: 20_000_000, maxAge: 3600))
        let line = Data(("{\"padding\":\"" + String(repeating: "x", count: 1000) + "\"}").utf8)
        await queue.append(line, to: .ready) // the open file exists before the disk fills
        // Fill the volume.
        let filler = mount.appendingPathComponent("filler")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        let chunk = Data(count: 4096)
        while (try? handle.write(contentsOf: chunk)) != nil {}
        try? handle.close()

        for _ in 0..<200 { await queue.append(line, to: .ready) }
        #expect(await queue.droppedEvents > 0)
    }
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
