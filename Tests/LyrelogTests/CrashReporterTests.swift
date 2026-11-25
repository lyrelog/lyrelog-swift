import Foundation
import Testing
@testable import Lyrelog

/// What crash.c writes when the app crashes, and the images that launch had loaded.
let inProcessReport = """
lyrelog-crash 1
signal 5
code 0
address 0x10404296c
time 1795614446
note NSInvalidArgumentException: -[Tilefall.Board cell]: unrecognized selector
frame 0x10404296c
lr 0x1040428c0
frame 0x104041f54
frame 0x1c152c7b8
end

"""
let inProcessImages = """
image 0x104040000 0x68000 81F983A0-82C3-375D-8F20-E4CF37D417F8 Tilefall
image 0x1c1500000 0x80000 11111111-2222-3333-4444-555555555555 libswift_Concurrency.dylib

"""

struct CrashReporterTests {
    @Test func aReportFromTheCrashHandlerReadsLikeMetricKitsCrash() throws {
        let now = Date(timeIntervalSince1970: 1_795_614_500)
        let crash = try #require(DiagnosticReport.crash(report: inProcessReport, images: inProcessImages, appBinary: "Tilefall", now: now))
        #expect(crash.message == "app_crashed")
        #expect(crash.level == .critical)
        #expect(crash.timestamp == Date(timeIntervalSince1970: 1_795_614_446))
        #expect(crash.attributes["exception"] == .string("EXC_BREAKPOINT"))
        #expect(crash.attributes["signal"] == .string("SIGTRAP"))
        #expect(crash.attributes["objc_exception"] == .string("NSInvalidArgumentException"))
        #expect(crash.attributes["top_frame"] == .string("Tilefall +0x296c"))
        guard case .object(let payload) = crash.payload else { Issue.record("no payload"); return }
        // The link register goes second, flagged for the server to keep or drop.
        #expect(payload["frames"] == .array([.string("Tilefall +0x296c"), .string("Tilefall +0x28c0"), .string("Tilefall +0x1f54"),
                                               .string("libswift_Concurrency.dylib +0x2c7b8")]))
        #expect(payload["lr_frame"] == .int(1))
        #expect(payload["binary_images"] == .object(["Tilefall": .string("81F983A0-82C3-375D-8F20-E4CF37D417F8"),
                                                     "libswift_Concurrency.dylib": .string("11111111-2222-3333-4444-555555555555")]))
        #expect(payload["reason"] == .string("-[Tilefall.Board cell]: unrecognized selector"))
        // The same report always has the same id: read twice, stored once.
        #expect(DiagnosticReport.crash(report: inProcessReport, images: inProcessImages, appBinary: "Tilefall", now: now)?.id == crash.id)
    }

    @Test func aReportCutShortOrTooOldIsNothing() {
        let now = Date(timeIntervalSince1970: 1_795_614_500)
        #expect(DiagnosticReport.crash(report: "lyrelog-crash 1\nsignal 11\n", images: inProcessImages, appBinary: nil, now: now) == nil)
        #expect(DiagnosticReport.crash(report: "something else", images: "", appBinary: nil, now: now) == nil)
        #expect(DiagnosticReport.crash(report: inProcessReport, images: inProcessImages, appBinary: nil, now: now.addingTimeInterval(8 * 86_400)) == nil)
    }

    /// A crash the crash reporter caught isn't reported again by MetricKit; one it didn't catch
    /// (it couldn't install, the app crashed before it did, another signal) still comes from
    /// MetricKit, and so does what the process can't catch (SIGKILL).
    @Test func metricKitsCrashesAreLeftToTheCrashReporterWhenItCaughtThem() {
        let caught = [InProcessCrash(time: crashPayloadTime.addingTimeInterval(-3600), signal: 11)]
        let reports = DiagnosticReport.events(from: crashPayload, appBinary: "Tilefall", inProcess: caught, now: crashPayloadTime)
        #expect(reports.map(\.message) == ["app_hung", "disk_write_overuse"])
        #expect(DiagnosticReport.events(from: crashPayload, appBinary: "Tilefall", inProcess: [], now: crashPayloadTime).map(\.message)
            == ["app_crashed", "app_hung", "disk_write_overuse"])
        let otherSignal = [InProcessCrash(time: crashPayloadTime.addingTimeInterval(-3600), signal: 6)]
        #expect(DiagnosticReport.events(from: crashPayload, appBinary: "Tilefall", inProcess: otherSignal, now: crashPayloadTime).map(\.message)
            == ["app_crashed", "app_hung", "disk_write_overuse"])
        let killed = Data(String(decoding: crashPayload, as: UTF8.self).replacingOccurrences(of: "\"signal\": 11", with: "\"signal\": 9").utf8)
        #expect(DiagnosticReport.events(from: killed, appBinary: "Tilefall", inProcess: [InProcessCrash(time: crashPayloadTime.addingTimeInterval(-3600), signal: 9)],
                                        now: crashPayloadTime).map(\.message) == ["app_crashed", "app_hung", "disk_write_overuse"])
    }

    @Test func theCrashesCaughtAreRemembered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("caught")
        let now = Date(timeIntervalSince1970: 1_795_614_500)
        InProcessCrash.remember(InProcessCrash(time: now.addingTimeInterval(-60), signal: 11), in: file, now: now)
        InProcessCrash.remember(InProcessCrash(time: now.addingTimeInterval(-9 * 86_400), signal: 6), in: file, now: now)
        #expect(InProcessCrash.read(file, now: now) == [InProcessCrash(time: now.addingTimeInterval(-60), signal: 11)])
    }
}

/// A handler of another crash reporter's, installed before Lyrelog's.
private let otherReporter: @convention(c) (NSException) -> Void = { _ in }

struct ExceptionNoteTests {
    /// `start` after `stop` installs again: the handler before Lyrelog's stays the one it calls,
    /// never Lyrelog's own (which would call itself until the stack ran out).
    @Test func installingTwiceKeepsTheHandlerBefore() {
        NSSetUncaughtExceptionHandler(otherReporter)
        ExceptionNote.install()
        ExceptionNote.install()
        let previous = ExceptionNote.previous.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
        #expect(previous == unsafeBitCast(otherReporter, to: UnsafeRawPointer.self))
    }
}
