import Foundation
import os
import StoreKit

extension Lyrelog {
    public enum LogLevel: String, Sendable, CaseIterable, Comparable {
        case trace, debug, info, notice, warning, error, critical

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Whether the player agreed to send diagnostics. Same model as Datadog's TrackingConsent:
    /// `pending` keeps events on the device without sending them, `granted` sends them (and the
    /// ones kept while pending), `denied` deletes everything and stops recording.
    public enum Consent: Sendable, Equatable {
        case pending, granted, denied
    }

    public struct Configuration: Sendable {
        /// The hosted ingest, used when no endpoint is given.
        public static let defaultEndpoint = URL(string: "https://ingest.lyrelog.com")!

        /// The ingest origin. Defaults to `https://ingest.lyrelog.com`. A pasted
        /// `.../v1/events:batch` or `.../v1` is cut back to the origin. Must be `https`; plain
        /// `http` only reaches this machine (`localhost`, `127.0.0.1`, `::1`): any other is
        /// refused, and nothing is sent (the events stay on the device).
        public var endpoint: URL
        /// The project's ingest key (`lyr_ing_...`). It can only append events, so it is fine
        /// inside the app binary.
        public var apiKey: String
        /// Whether events may be sent. `.granted` by default: logging is the app's own
        /// diagnostics, and an app that has to ask first starts with `.pending` (events wait on
        /// the device) and calls `Lyrelog.setConsent` when the person chooses.
        public var consent: Consent
        /// Events below this level are dropped before they reach the disk.
        public var minimumLevel: LogLevel
        /// Also print every event to the unified log (Console.app, Xcode).
        public var mirrorToOSLog: Bool

        /// How often the uploader wakes up while the app is in the foreground (at least 1 s).
        public var uploadInterval: Duration
        /// Periodic uploads pause in Low Power Mode; going to the background still sends.
        public var pauseUploadsInLowPowerMode: Bool
        /// A batch (one file on disk, one request) closes at whichever comes first. Kept inside
        /// the server's limits: at most 2,000 events and 4 MiB.
        public var maxBatchBytes: Int
        public var maxBatchEvents: Int
        /// Hard caps on what waits on the device. The oldest files go first.
        public var maxDiskBytes: Int
        public var maxEventAge: Duration
        /// A new session starts after this long without any event.
        public var sessionTimeout: Duration
        /// Where the queue lives. Defaults to Library/Caches/lyrelog: excluded from backups, and
        /// the system may purge it when the device runs out of space (events waiting there are
        /// then lost, never the app's own data).
        public var storageDirectory: URL?
        /// Report crashes, hangs and CPU or disk-write overuse from MetricKit (iOS, macOS, visionOS).
        /// iOS hands them over on the next launch; they keep the time they happened.
        public var captureDiagnostics: Bool
        /// Tag every event with the screen set by `Lyrelog.screen(_:)` (`screen` attribute).
        public var attachScreen: Bool
        /// Which environment these events belong to, so the dashboard can keep them apart in one
        /// project. `nil` detects it (`Lyrelog.detectedEnvironment`, then StoreKit's answer):
        /// `development` (Debug, simulator, Xcode, ad hoc), `testflight`, `production`.
        /// Any name works: lowercase letters, digits, `-` and `_`, up to 32 ("staging", "internal").
        public var environment: String?
        /// Which part of the product sends these events, when one project holds several (an app,
        /// its website, its backend). `nil` is the OS: `ios`, `macos`, `visionos`, `tvos`.
        public var platform: String?
        /// Field names whose values are sent as "[redacted]", in the attributes and the payload at
        /// any depth. A name matches when, lowercased and without `-`, `_`, `.` or spaces, it is
        /// one of these or ends with one ("X-Api-Key", "csrf_token", "Set-Cookie"; not
        /// "token_count"). `nil` is `defaultRedactedKeys`; your own list replaces it (add to it
        /// with `defaultRedactedKeys + ["pin"]`); an empty list turns redaction off.
        public var redactedKeys: [String]?
        /// Prove with Apple's App Attest that events come from your genuine app on a real
        /// device, so Lyrelog stores them as verified. Needs the App Attest capability in Xcode
        /// (entitlement `com.apple.developer.devicecheck.appattest-environment`: `production`
        /// for App Store and TestFlight builds; without it Apple uses the development
        /// environment) and the App ID set in the project's settings in Lyrelog. Macs, the
        /// simulator, app extensions (except on watchOS) and some devices can't attest: their
        /// events are stored unverified. Sending never waits for it; batches go without a
        /// token until one exists. On by default; `false` turns it off.
        public var appAttest: Bool
        /// For Lyrelog's own Flutter and React Native SDKs only, so it is SPI: their name and
        /// version ("lyrelog-flutter/0.9.0"), sent before this SDK's in `resource.sdk` so the
        /// dashboard can tell where events came from. A wrapper writes `@_spi(Wrapper) import
        /// Lyrelog` and sets it after making the configuration; an app never sees it.
        @_spi(Wrapper) public var wrapper: String?

        /// What `redactedKeys = nil` redacts, the same list in every Lyrelog SDK.
        public static let defaultRedactedKeys = [
            "authorization", "cookie", "password", "passwd", "secret", "token", "apikey", "privatekey",
            "credential", "credentials", "accesskey", "signature",
        ]

        public init(
            endpoint: URL = Configuration.defaultEndpoint,
            apiKey: String,
            consent: Consent = .granted,
            minimumLevel: LogLevel = .debug,
            mirrorToOSLog: Bool = false,
            uploadInterval: Duration = .seconds(15),
            pauseUploadsInLowPowerMode: Bool = true,
            maxBatchBytes: Int = 512 * 1024,
            maxBatchEvents: Int = 500,
            maxDiskBytes: Int = 20 * 1024 * 1024,
            maxEventAge: Duration = .seconds(7 * 24 * 3600),
            sessionTimeout: Duration = .seconds(30 * 60),
            storageDirectory: URL? = nil,
            captureDiagnostics: Bool = true,
            attachScreen: Bool = true,
            environment: String? = nil,
            platform: String? = nil,
            redactedKeys: [String]? = nil,
            appAttest: Bool = true
        ) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.consent = consent
            self.minimumLevel = minimumLevel
            self.mirrorToOSLog = mirrorToOSLog
            self.uploadInterval = uploadInterval
            self.pauseUploadsInLowPowerMode = pauseUploadsInLowPowerMode
            self.maxBatchBytes = maxBatchBytes
            self.maxBatchEvents = maxBatchEvents
            self.maxDiskBytes = maxDiskBytes
            self.maxEventAge = maxEventAge
            self.sessionTimeout = sessionTimeout
            self.storageDirectory = storageDirectory
            self.captureDiagnostics = captureDiagnostics
            self.attachScreen = attachScreen
            self.environment = environment
            self.platform = platform
            self.redactedKeys = redactedKeys
            self.appAttest = appAttest
            self.wrapper = nil
        }
    }
}

extension Lyrelog.Configuration {
    /// The server takes at most 2,000 lines and 4 MiB per request, on the wire and once
    /// decompressed (the batch file is the decompressed size).
    static let serverMaxBatchEvents = 2000
    static let serverMaxBatchBytes = 4 * 1024 * 1024

    /// The pump sleeps at least this long between rounds: a zero or negative interval made it
    /// loop without sleeping (a busy core, a request per event).
    static let minimumUploadInterval: Duration = .seconds(1)

    var effectiveUploadInterval: Duration { max(uploadInterval, Self.minimumUploadInterval) }
    var effectiveMaxBatchEvents: Int { min(max(maxBatchEvents, 1), Self.serverMaxBatchEvents) }
    var effectiveMaxBatchBytes: Int { min(max(maxBatchBytes, 64 * 1024), Self.serverMaxBatchBytes) }

    /// The origin requests go to (`<origin>/v1/events:batch`), or nil for an endpoint that
    /// must not be used (plain `http` to another machine, another scheme).
    static func ingestOrigin(_ raw: URL) -> URL? {
        guard var components = URLComponents(url: raw, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        let host = (components.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch scheme {
        case "https": break
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(host): break
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/v1/events:batch", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

// The public types live only inside `Lyrelog` (`Lyrelog.Configuration`, `Lyrelog.Consent`,
// `Lyrelog.LogLevel`, `Lyrelog.LogValue`), so they never clash with an app's own types or another
// module's. These short names are internal: only this module's code sees them.
typealias LogLevel = Lyrelog.LogLevel
typealias Consent = Lyrelog.Consent
typealias Configuration = Lyrelog.Configuration

/// What StoreKit says about where the app came from (`AppTransaction.environment`).
enum StoreEnvironment: Sendable, Equatable {
    case production, sandbox, xcode
}

extension Lyrelog {
    /// The environment this build runs in, told without waiting: `development` (a Debug build,
    /// the simulator, or an ad hoc or development-signed build: one with an embedded
    /// provisioning profile), `testflight` (a sandbox App Store receipt and no profile), or
    /// `production`. On macOS without an answer from StoreKit it is `production`.
    ///
    /// When `Configuration.environment` is nil, Lyrelog also asks StoreKit
    /// (`AppTransaction.shared.environment`: `xcode` is development, `sandbox` testflight,
    /// `production` production) in the background; events logged after it answers carry its
    /// answer, which also tells TestFlight on macOS. StoreKit never prompts here; offline or
    /// signed out, this detection stays. Combine it with your own rule:
    ///
    /// ```swift
    /// environment: isInternalTester ? "internal" : nil   // nil = this detection
    /// ```
    public static var detectedEnvironment: String {
        environment(debug: isDebugBuild, simulator: isSimulator, store: nil,
                    hasProvisioningProfile: hasProvisioningProfile, sandboxReceipt: hasSandboxReceipt)
    }

    /// `detectedEnvironment`, refined by StoreKit's app transaction when it answers within
    /// `timeout`.
    public static func detectEnvironment(timeout: Duration = .seconds(10)) async -> String {
        let store = await storeEnvironment(timeout: timeout)
        return environment(debug: isDebugBuild, simulator: isSimulator, store: store,
                           hasProvisioningProfile: hasProvisioningProfile, sandboxReceipt: hasSandboxReceipt)
    }

    static func environment(debug: Bool, simulator: Bool, store: StoreEnvironment?,
                            hasProvisioningProfile: Bool, sandboxReceipt: Bool) -> String {
        if debug || simulator { return "development" }
        switch store {
        case .xcode: return "development"
        case .sandbox: return "testflight"
        case .production: return "production"
        case nil:
            // Ad hoc and development builds carry a profile and a sandbox receipt too.
            if hasProvisioningProfile { return "development" }
            return sandboxReceipt ? "testflight" : "production"
        }
    }

    static func storeEnvironment(timeout: Duration) async -> StoreEnvironment? {
        let answer = OSAllocatedUnfairLock<StoreEnvironment?>(initialState: nil)
        await withDeadline(timeout) {
            guard let result = try? await AppTransaction.shared else { return }
            let environment = result.unsafePayloadValue.environment
            let mapped: StoreEnvironment? = switch environment {
            case .xcode: .xcode
            case .sandbox: .sandbox
            case .production: .production
            default: nil
            }
            answer.withLock { $0 = mapped }
        }
        return answer.withLock { $0 }
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static var hasProvisioningProfile: Bool {
        #if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #else
        return false
        #endif
    }

    private static var hasSandboxReceipt: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Makes any name a valid environment ("Staging EU" -> "staging-eu"); empty becomes nil.
    static func environmentName(_ raw: String) -> String? {
        let lowered = raw.lowercased().map { c -> Character in
            c.isLetter && c.isASCII || c.isNumber && c.isASCII || c == "_" || c == "-" ? c : "-"
        }
        var name = String(lowered).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if name.count > 32 { name = String(name.prefix(32)) }
        return name.isEmpty ? nil : name
    }

    /// `LogLevel` by a name that can't collide: an app with its own `LogLevel` type refers to
    /// this one as `Lyrelog.Level`.
    public typealias Level = LogLevel
    /// `LogValue` by a shorter name: `let v: Lyrelog.Value = ["a": 1]`.
    public typealias Value = LogValue
}
