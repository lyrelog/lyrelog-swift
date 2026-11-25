import CryptoKit
import Foundation
#if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
import MetricKit
#endif

/// MetricKit's diagnostics (crashes, hangs, CPU and disk-write overuse) as Lyrelog events.
///
/// iOS collects them while the app runs and hands them over later, usually on the next launch,
/// as JSON. `DiagnosticReport.events(from:)` turns that JSON into events and knows nothing
/// about MetricKit, so it can be tested with a saved payload.
enum Diagnostics {
    static func install() {
        #if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
        // MXMetricManager (iOS 14+, macOS 12+) delivers each diagnostic payload once, through
        // `didReceive(_:)` on a background queue, usually on the launch after it happened.
        // `pastDiagnosticPayloads` lists the payloads already delivered to this app before (not
        // only "before this launch"): reading it catches up on any delivered while Lyrelog
        // wasn't subscribed yet (an earlier launch that died early). Event ids derive from the
        // content, so a payload seen both ways is stored once. iOS 27's MetricManager
        // (`diagnosticReports`) replaces this later; the subscriber API still works there.
        Task.detached(priority: .utility) {
            MXMetricManager.shared.add(DiagnosticsReceiver.shared)
            // Serialising and parsing the reports happens here, never on the main actor.
            let past = MXMetricManager.shared.pastDiagnosticPayloads.map { $0.jsonRepresentation() }
            DiagnosticsReceiver.shared.receive(past)
        }
        #endif
    }
}

#if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
final class DiagnosticsReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsReceiver()

    /// Called by MetricKit on a background queue.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        receive(payloads.map { $0.jsonRepresentation() })
    }

    func receive(_ payloads: [Data]) {
        let binary = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        // On the disk's queue, after the crash reporter has read what the last launch left.
        DiskExecutor.shared.queue.async {
            let caught = InProcessCrash.read(CrashReporter.caughtFile)
            for data in payloads {
                for report in DiagnosticReport.events(from: data, appBinary: binary, inProcess: caught) {
                    Lyrelog.record(report.level, report.message, category: "diagnostics", attrs: report.attributes,
                                   payload: report.payload, at: report.timestamp, id: report.id)
                }
            }
        }
    }
}
#endif

struct DiagnosticReport: Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let attributes: [String: LogValue]
    let payload: LogValue?

    /// The most frames a report carries, so it stays well under the server's 64 KiB payload.
    static let maxFrames = 60
    /// Older reports are skipped. `pastDiagnosticPayloads` is read on every launch, and a report
    /// older than the project's retention (7 days on Free, the queue's own limit too) is stored
    /// by the server at its arrival time, so it would become a new event on every launch.
    static let maxAge: TimeInterval = 7 * 86_400

    /// `inProcess` are the crashes the crash reporter caught (CrashReporter.swift): MetricKit's
    /// report of one of them is left out, so a crash isn't reported twice. SIGKILL is never one
    /// (the process can't catch it: the watchdog, the system ending the app).
    static func events(from json: Data, appBinary: String? = nil, inProcess: [InProcessCrash] = [], now: Date = Date()) -> [DiagnosticReport] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        let when = date(root["timeStampBegin"]) ?? date(root["timeStampEnd"]) ?? now
        let until = date(root["timeStampEnd"]) ?? when
        guard now.timeIntervalSince(when) <= maxAge else { return [] }
        var out: [DiagnosticReport] = []
        let kinds: [(key: String, level: LogLevel, message: String)] = [
            ("crashDiagnostics", .critical, "app_crashed"),
            ("hangDiagnostics", .error, "app_hung"),
            ("cpuExceptionDiagnostics", .warning, "cpu_overuse"),
            ("diskWriteExceptionDiagnostics", .warning, "disk_write_overuse"),
            ("appLaunchDiagnostics", .warning, "slow_launch"),
        ]
        for kind in kinds {
            for (index, item) in ((root[kind.key] as? [[String: Any]]) ?? []).enumerated() {
                let meta = item["diagnosticMetaData"] as? [String: Any] ?? [:]
                if kind.key == "crashDiagnostics", let signal = meta["signal"] as? Int, signal != 9,
                   inProcess.contains(where: { $0.signal == signal && $0.time >= when.addingTimeInterval(-InProcessCrash.window) && $0.time <= until.addingTimeInterval(InProcessCrash.window) }) {
                    continue
                }
                var attrs: [String: LogValue] = [:]
                if let v = meta["appVersion"] as? String { attrs["version_at_report"] = .string(v) }
                if let v = meta["appBuildVersion"] as? String { attrs["build_at_report"] = .string(v) }
                if let v = meta["osVersion"] as? String { attrs["os_at_report"] = .string(v) }
                if let v = meta["deviceType"] as? String { attrs["device_at_report"] = .string(v) }
                if let v = meta["isTestFlightApp"] as? Bool { attrs["testflight"] = .bool(v) }
                switch kind.key {
                case "crashDiagnostics":
                    if let code = meta["exceptionType"] as? Int { attrs["exception"] = .string(exceptionName(code)) }
                    if let code = meta["exceptionCode"] as? Int { attrs["exception_code"] = .int(code) }
                    if let signal = meta["signal"] as? Int { attrs["signal"] = .string(signalName(signal)) }
                    if let reason = meta["terminationReason"] as? String { attrs["termination_reason"] = .string(String(reason.prefix(300))) }
                    if let objc = meta["objectiveCexceptionReason"] as? [String: Any], let name = objc["exceptionName"] as? String {
                        attrs["objc_exception"] = .string(name)
                    }
                case "hangDiagnostics":
                    if let duration = seconds(meta["hangDuration"]) { attrs["hang_seconds"] = .double(duration) }
                case "cpuExceptionDiagnostics":
                    if let cpu = seconds(meta["totalCPUTime"]) { attrs["cpu_seconds"] = .double(cpu) }
                    if let sampled = seconds(meta["totalSampledTime"]) { attrs["sampled_seconds"] = .double(sampled) }
                case "diskWriteExceptionDiagnostics":
                    if let writes = meta["writesCaused"] as? String { attrs["writes"] = .string(writes) }
                case "appLaunchDiagnostics":
                    if let launch = seconds(meta["launchDuration"]) { attrs["launch_seconds"] = .double(launch) }
                default: break
                }
                let frames = topFrames(item["callStackTree"] as? [String: Any])
                if let first = frames.first(where: { appBinary != nil && $0.binary == appBinary }) ?? frames.first {
                    attrs["top_frame"] = .string(first.text)
                }
                var payload: [String: LogValue] = [:]
                if !frames.isEmpty { payload["frames"] = .array(frames.prefix(maxFrames).map { .string($0.text) }) }
                let images = Dictionary(frames.compactMap { f in f.uuid.map { (f.binary, LogValue.string($0)) } }, uniquingKeysWith: { a, _ in a })
                if !images.isEmpty { payload["binary_images"] = .object(images) }
                // The same report always gets the same id.
                let fingerprint = "\(kind.key)|\(index)|\(when.timeIntervalSince1970)|\(String(describing: meta.sorted { $0.key < $1.key }))"
                out.append(DiagnosticReport(id: stableUUID(fingerprint), timestamp: when, level: kind.level, message: kind.message,
                                            attributes: attrs, payload: payload.isEmpty ? nil : .object(payload)))
            }
        }
        return out
    }

    struct Frame {
        let binary: String
        let uuid: String?
        let text: String
    }

    /// The frames of the thread that crashed (or hung), top first: "Tilefall +0x1a2b3c".
    /// MetricKit nests each caller as the only subframe of the frame it called.
    static func topFrames(_ tree: [String: Any]?) -> [Frame] {
        guard let stacks = tree?["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        var frames: [Frame] = []
        var current = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let frame = current, frames.count < maxFrames {
            let binary = frame["binaryName"] as? String ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            frames.append(Frame(binary: binary, uuid: frame["binaryUUID"] as? String, text: "\(binary) +0x\(String(offset, radix: 16))"))
            current = (frame["subFrames"] as? [[String: Any]])?.first
        }
        return frames
    }

    static func exceptionName(_ code: Int) -> String {
        switch code {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "EXC_\(code)"
        }
    }

    static func signalName(_ code: Int) -> String {
        switch code {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 13: "SIGPIPE"
        default: "SIG\(code)"
        }
    }

    /// "3 sec", "1,234 ms", "2.5 min" or a bare number, in seconds.
    static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = (value as? String)?.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = text.split(separator: " ")
        guard let amount = parts.first.flatMap({ Double($0) }) else { return nil }
        switch parts.count > 1 ? parts[1].lowercased() : "sec" {
        case "ms": return amount / 1000
        case "min": return amount * 60
        case "hr", "h": return amount * 3600
        default: return amount
        }
    }

    /// MetricKit writes "2026-11-17 10:42:00" (UTC) in its JSON.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// A UUID made from a hash (version 5 style), so the same text always gives the same id.
    static func stableUUID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
