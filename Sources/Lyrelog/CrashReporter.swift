import Foundation
import LyrelogCrashC

/// Crashes caught in the app's own process (2026-11-25), so a crash is reported on the very next
/// launch instead of whenever MetricKit delivers it (hours, sometimes). The part that runs while
/// the app crashes is C (`LyrelogCrashC`, async-signal-safe): it writes the crashed thread's
/// return addresses and the loaded images to two files. On the next launch this turns them into
/// the same event MetricKit's crash makes (`app_crashed`, frames as "Binary +0xoffset" with each
/// binary's UUID), which the server reads with the build's uploaded symbols.
///
/// Other crash reporters (Sentry, Crashlytics) keep working: the handlers before Lyrelog's are
/// called after it, and those installed later call Lyrelog's.
enum CrashReporter {
    static func install() {
        DiskExecutor.shared.queue.async {
            let folder = Engine.supportDirectory().appendingPathComponent("crash", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report = folder.appendingPathComponent("report")
            let images = folder.appendingPathComponent("images")
            // What the last launch left, before the files are opened again (and emptied).
            if let text = try? String(contentsOf: report, encoding: .utf8), !text.isEmpty {
                let loaded = (try? String(contentsOf: images, encoding: .utf8)) ?? ""
                let binary = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
                if let crash = DiagnosticReport.crash(report: text, images: loaded, appBinary: binary) {
                    Lyrelog.record(crash.level, crash.message, category: "diagnostics", attrs: crash.attributes,
                                   payload: crash.payload, at: crash.timestamp, id: crash.id)
                }
            }
            guard lyrelog_crash_install(report.path, images.path) else {
                SDKLog.say("crash reports: couldn't open \(folder.path); crashes come from MetricKit only")
                return
            }
            ExceptionNote.install()
            // sigaltstack is per thread: the main thread, where most stack overflows happen, gets
            // its own so they're reported too.
            DispatchQueue.main.async { lyrelog_crash_alternate_stack() }
        }
    }
}

/// An uncaught Objective-C exception's name and reason, noted for the report before the app
/// aborts. The handler set before Lyrelog's is called after it.
enum ExceptionNote {
    nonisolated(unsafe) static var previous: (@convention(c) (NSException) -> Void)?

    static func install() {
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")"
            text.withCString { lyrelog_crash_note($0) }
            // Where it was thrown: the report shows that instead of the abort that follows.
            let stack = exception.callStackReturnAddresses.map { $0.uint64Value }
            stack.withUnsafeBufferPointer { lyrelog_crash_note_stack($0.baseAddress, Int32($0.count)) }
            ExceptionNote.previous?(exception)
        }
    }
}

extension DiagnosticReport {
    /// A report written by the crash handler (crash.c), with the images that launch had loaded.
    /// nil when it isn't one, or it's older than `maxAge`.
    static func crash(report: String, images: String, appBinary: String?, now: Date = Date()) -> DiagnosticReport? {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first == "lyrelog-crash 1" else { return nil }
        var signal = 0, code = 0, time = 0.0
        var note: String?
        var addresses: [UInt64] = []
        var linkRegister: UInt64?
        var message: String?
        var thrown: [UInt64] = []
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "signal": signal = Int(parts[1]) ?? 0
            case "code": code = Int(parts[1]) ?? 0
            case "time": time = Double(parts[1]) ?? 0
            case "note": note = parts[1]
            case "frame": if let a = hex(parts[1]) { addresses.append(a) }
            case "lr": if let a = hex(parts[1]) { linkRegister = a }
            case "message": message = parts[1]
            case "thrown": if let a = hex(parts[1]) { thrown.append(a) }
            default: break
            }
        }
        // An uncaught exception: where it was thrown says more than the abort it ended in.
        if !thrown.isEmpty {
            addresses = thrown
            linkRegister = nil
        }
        guard signal != 0, !addresses.isEmpty else { return nil }
        // The link register goes second, flagged: it may be the top function's caller (a leaf
        // that saved nothing) or a call that function already made; the server tells them apart
        // with the build's symbols and drops it in the second case.
        let lrIndex: Int? = linkRegister.map { lr in
            addresses.insert(lr, at: 1)
            return 1
        }
        let when = time > 0 ? Date(timeIntervalSince1970: time) : now
        guard now.timeIntervalSince(when) <= maxAge else { return nil }

        struct Image { let load: UInt64; let size: UInt64; let uuid: String; let name: String }
        let loaded: [Image] = images.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4).map(String.init)
            guard parts.count == 5, parts[0] == "image", let load = hex(parts[1]), let size = hex(parts[2]) else { return nil }
            return Image(load: load, size: size, uuid: parts[3], name: parts[4])
        }.sorted { $0.load < $1.load }
        var frames: [Frame] = []
        for address in addresses.prefix(maxFrames) {
            if let image = loaded.last(where: { $0.load <= address }), address < image.load + image.size {
                frames.append(Frame(binary: image.name, uuid: image.uuid, text: "\(image.name) +0x\(String(address - image.load, radix: 16))"))
            } else {
                frames.append(Frame(binary: "?", uuid: nil, text: "? 0x\(String(address, radix: 16))"))
            }
        }

        var attrs: [String: LogValue] = [
            "signal": .string(signalName(signal)),
            "exception": .string(exceptionFor(signal: signal)),
            "mechanism": .string("signal"),
        ]
        if code != 0 { attrs["exception_code"] = .int(code) }
        if !thrown.isEmpty { attrs["mechanism"] = .string("uncaught_exception") }
        // "Fatal error: Index out of range" (a Swift runtime failure, from libswiftCore).
        if let message { attrs["error_message"] = .string(String(message.prefix(500))) }
        var payload: [String: LogValue] = ["frames": .array(frames.map { .string($0.text) })]
        if let lrIndex { payload["lr_frame"] = .int(lrIndex) }
        if let note, let colon = note.range(of: ": ") {
            attrs["objc_exception"] = .string(String(note[..<colon.lowerBound]))
            payload["reason"] = .string(String(note[colon.upperBound...].prefix(1000)))
        }
        if let first = frames.first(where: { appBinary != nil && $0.binary == appBinary }) ?? frames.first {
            attrs["top_frame"] = .string(first.text)
        }
        let images = Dictionary(frames.compactMap { f in f.uuid.map { (f.binary, LogValue.string($0)) } }, uniquingKeysWith: { a, _ in a })
        if !images.isEmpty { payload["binary_images"] = .object(images) }
        return DiagnosticReport(id: stableUUID("lyrelog-crash|" + report), timestamp: when, level: .critical, message: "app_crashed",
                                attributes: attrs, payload: .object(payload))
    }

    /// The Mach exception a signal usually comes from, named as MetricKit names it, so a crash
    /// reads (and is grouped) the same whichever way it was reported.
    static func exceptionFor(signal: Int) -> String {
        switch signal {
        case 10, 11: "EXC_BAD_ACCESS"
        case 4: "EXC_BAD_INSTRUCTION"
        case 5: "EXC_BREAKPOINT" // Swift's fatalError and other traps (brk)
        case 8: "EXC_ARITHMETIC"
        case 6: "EXC_CRASH" // abort(): an uncaught exception, a failed assertion
        default: "EXC_CRASH"
        }
    }

    private static func hex(_ text: String) -> UInt64? {
        UInt64(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16)
    }
}

extension Lyrelog {
    /// For wrapper SDKs: the crash about to happen (within 10 seconds) was already reported, as
    /// React Native's fatal JavaScript error is before React Native aborts the app, so the crash
    /// reporter doesn't report it again. Other crash reporters still see it.
    @_spi(Wrapper) public static func crashAlreadyReported() {
        lyrelog_crash_already_reported(10)
    }
}

