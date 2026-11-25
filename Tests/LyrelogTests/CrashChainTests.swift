#if os(macOS)
import Foundation
import Testing

/// The C crash handler, built with a small program that installs another reporter's handler
/// first (as Sentry or Crashlytics would be) and then faults: that handler must see the fault as it
/// happened (its address and code), and the app must still end with its own signal.
struct CrashChainTests {
    static let probe = #"""
    #include "lyrelog_crash.h"
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    static void other(int signal, siginfo_t *info, void *context) {
        char line[128];
        int n = snprintf(line, sizeof line, "other: signal %d addr %p\n", signal, info ? info->si_addr : NULL);
        write(1, line, n);
        _exit(0);
    }
    int main(int argc, char **argv) {
        if (argc > 3) {
            struct sigaction a; memset(&a, 0, sizeof a);
            a.sa_sigaction = other; a.sa_flags = SA_SIGINFO; sigemptyset(&a.sa_mask);
            sigaction(SIGSEGV, &a, NULL); sigaction(SIGBUS, &a, NULL);
        }
        if (!lyrelog_crash_install(argv[1], argv[2])) return 2;
        volatile int *bad = (volatile int *)0x10;
        *bad = 1;
        return 1;
    }
    """#

    func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, reason: Process.TerminationReason, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, process.terminationReason, output)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/clang")))
    func anotherReporterSeesTheFaultAsItHappened() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.probe.write(to: dir.appendingPathComponent("probe.c"), atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("probe").path
        let built = try run("/usr/bin/clang", ["-O1", "-I", root.appendingPathComponent("Sources/LyrelogCrashC/include").path,
                                               dir.appendingPathComponent("probe.c").path,
                                               root.appendingPathComponent("Sources/LyrelogCrashC/crash.c").path, "-o", binary])
        try #require(built.status == 0, "\(built.output)")
        let report = dir.appendingPathComponent("report").path, images = dir.appendingPathComponent("images").path

        let chained = try run(binary, [report, images, "other"])
        #expect(chained.output == "other: signal 11 addr 0x10\n")
        #expect(try String(contentsOfFile: report, encoding: .utf8).hasPrefix("lyrelog-crash 1\nsignal 11\n"))

        let alone = try run(binary, [report, images])
        #expect(alone.reason == .uncaughtSignal && alone.status == SIGSEGV)
    }
}
#endif
