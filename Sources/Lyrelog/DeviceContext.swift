import Foundation

enum DeviceContext {
    static let sdkVersion = "lyrelog-swift/\(Lyrelog.version)"

    /// `resource.sdk`: this SDK, after the wrapper's name when one sends through it
    /// ("lyrelog-flutter/1.0.0 lyrelog-swift/1.0.0").
    static func sdk(wrapper: String?) -> String {
        let name = (wrapper ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace && !$0.isNewline }
        return name.isEmpty ? sdkVersion : EventPreparation.resource("\(name.prefix(64)) \(sdkVersion)")
    }

    static func resource(bundle: Bundle = .main, environment: String = Lyrelog.detectedEnvironment, platform: String = DeviceContext.platform, wrapper: String? = nil) -> Resource {
        let info = bundle.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Resource(
            app_id: EventPreparation.resource(bundle.bundleIdentifier ?? ""),
            app_version: EventPreparation.resource(info["CFBundleShortVersionString"] as? String ?? ""),
            app_build: EventPreparation.resource(info["CFBundleVersion"] as? String ?? ""),
            os_name: osName,
            os_version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            device_model: EventPreparation.resource(hardwareModel()),
            locale: EventPreparation.resource(Locale.current.identifier),
            sdk: sdk(wrapper: wrapper),
            environment: environment,
            platform: platform
        )
    }

    /// Which part of a product this is, for a project that also has a website or a backend.
    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }

    private static var osName: String {
        #if os(iOS)
        // An iPad app on a Mac still reports iOS here; the model tells them apart.
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    /// `iPhone18,1`, not the marketing name: stable, and it doesn't need a lookup table.
    static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// A random id kept in Application Support: survives launches and updates, not a reinstall
    /// or a denial of consent. Excluded from iCloud and device backups, so a restored or new
    /// device is a new install. Not an advertising identifier and not linked to anything else.
    static func installID(in directory: URL) -> String {
        var file = directory.appendingPathComponent("install_id")
        defer {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        }
        if let saved = try? String(contentsOf: file, encoding: .utf8),
           UUID(uuidString: saved.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fresh.write(to: file, atomically: true, encoding: .utf8)
        return fresh
    }

    static func forgetInstallID(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("install_id"))
    }
}

/// The install id, read or made on first use and forgotten (file deleted) on a denial.
final class InstallIdentity: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var id: String?

    init(directory: URL) {
        self.directory = directory
    }

    /// The id, or nil while consent is denied (then nothing may be written to the device).
    func current(unless consent: ConsentGate) -> String? {
        lock.withLock {
            guard consent.value != .denied else { return nil }
            if let id { return id }
            let made = DeviceContext.installID(in: directory)
            id = made
            return made
        }
    }

    /// `current(unless:)`, reading or making the file on the disk queue the first time.
    func resolve(unless consent: ConsentGate, on queue: DiskQueue) async -> String? {
        let cached = lock.withLock { consent.value == .denied ? String?.none : id }
        if let cached { return cached }
        return await queue.onDisk { self.current(unless: consent) }
    }

    func forget() {
        lock.withLock {
            id = nil
            DeviceContext.forgetInstallID(in: directory)
        }
    }
}

/// The current session: a new one starts after `timeout` without events.
struct SessionClock: Sendable {
    private(set) var id = UUID().uuidString.lowercased()
    private var lastActivity: Date?
    let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    mutating func touch(at now: Date) -> String {
        if let lastActivity, now.timeIntervalSince(lastActivity) > timeout {
            id = UUID().uuidString.lowercased()
        }
        lastActivity = now
        return id
    }
}
