import Foundation
import Testing
@testable import Lyrelog

struct GzipTests {
    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    #if os(macOS)
    /// The real check: the system's gunzip must read what we produce.
    @Test(arguments: [0, 1, 1000, 300_000])
    func systemGunzipReadsIt(size: Int) throws {
        let original = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 31 % 251) })
        let compressed = try Gzip.compress(original)
        #expect(Array(compressed.prefix(2)) == [0x1F, 0x8B])

        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
        try compressed.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", input.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let decompressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(decompressed == original)
    }
    #endif
}
