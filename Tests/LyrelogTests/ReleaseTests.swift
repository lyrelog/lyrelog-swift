import CryptoKit
import Foundation
import os
import Testing
@testable import Lyrelog

/// The repository's root, from this file's path.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The files anyone who gets the package can read: the README, the licence, the manifest, every
/// source (with its doc comments) and every test fixture.
func publicFiles() -> [URL] {
    var files = ["README.md", "LICENSE", "Package.swift"].map { repositoryRoot.appendingPathComponent($0) }
    for folder in ["Sources", "Tests"] {
        let walker = FileManager.default.enumerator(at: repositoryRoot.appendingPathComponent(folder),
                                                    includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
    }
    return files
}

/// What changed before 0.9.0: retries, failure counting, names, the public surface.
struct ReleaseTests {
    // The server never asks for more than an hour; anything longer (a proxy, a captive portal,
    // a date years ahead) held sending for up to a day.
    @Test func retryAfterIsCappedAtAnHour() {
        let now = Date(timeIntervalSince1970: 1_000_000_000) // Sun, 09 Sep 2001 01:46:40 GMT
        #expect(ResponseClassifier.maxRetryAfter == 3600)
        #expect(ResponseClassifier.parseRetryAfter("3600", now: now) == 3600)
        #expect(ResponseClassifier.parseRetryAfter("7200", now: now) == 3600)
        #expect(ResponseClassifier.parseRetryAfter("Sun, 09 Sep 2001 03:46:40 GMT", now: now) == 3600)
        #expect(ResponseClassifier.parseRetryAfter("nan", now: now) == nil)
        #expect(ResponseClassifier.classify(status: 503, body: Data(), retryAfter: "86400", now: now) == .retry(after: 3600))
    }

    @Test func theUploadIntervalIsAtLeastOneSecond() {
        #expect(Configuration(apiKey: "k", uploadInterval: .milliseconds(200)).effectiveUploadInterval == .seconds(1))
        #expect(Configuration(apiKey: "k", uploadInterval: .seconds(5)).effectiveUploadInterval == .seconds(5))
    }

    // sdk-spec rule 4: the monthly quota waits for its Retry-After, nothing more. Counted as a
    // failure, it grew the backoff, so sending resumed late once the month turned.
    @Test func theMonthlyQuotaIsNotAFailedAttempt() async {
        let queue = makeQueue()
        await UploaderTests().fill(queue, batches: 1)
        let transport = FakeTransport([QuotaTests.quota("quota-\(UUID().uuidString)"), (503, "", [:])])
        let sender = UploaderTests().uploader(transport, queue: queue)
        #expect(await sender.uploadReady(force: true).stoppedForRetry)
        #expect(await sender.attempt == 0)
        #expect(await sender.willAttempt(force: false), "no backoff of its own after the quota's Retry-After: 0")
        #expect(await sender.uploadReady(force: false).stoppedForRetry) // the 503
        #expect(await sender.attempt == 1)
        #expect(await !sender.willAttempt(force: false))
    }

    // One line in the SDK's own log after 3 failed uploads in a row, then silence until a
    // delivery. The quota's 429 doesn't count.
    @Test func oneWarningWhenUploadsKeepFailing() async {
        let queue = makeQueue()
        await UploaderTests().fill(queue, batches: 3)
        let failed = (503, "", [String: String]())
        let transport = FakeTransport([failed, failed, QuotaTests.quota("used up"), failed, failed,
                                       ok, failed, failed, failed])
        let sender = UploaderTests().uploader(transport, queue: queue)
        for _ in 0..<3 { _ = await sender.uploadReady(force: true) }
        #expect(await sender.failingWarnings == 0, "two failures and the quota are not three failures")
        _ = await sender.uploadReady(force: true)
        #expect(await sender.failingWarnings == 1)
        let line = SDKLog.recent.last { $0.contains("uploads in a row failed") }
        #expect(line?.hasPrefix("lyrelog: 3 uploads in a row failed") == true)
        #expect(line?.contains("lyr_ing_x") == false)
        _ = await sender.uploadReady(force: true)
        #expect(await sender.failingWarnings == 1, "said once")
        _ = await sender.uploadReady(force: true) // delivered, then a failure
        _ = await sender.uploadReady(force: true)
        #expect(await sender.failingWarnings == 1)
        _ = await sender.uploadReady(force: true)
        #expect(await sender.failingWarnings == 2, "a delivery re-arms it")
        #expect(transport.count == 9)
    }

    // Only `Lyrelog` is a top-level public name: `Configuration`, `Consent`, `LogLevel` and
    // `LogValue` at the top level clashed with an app's own types and other modules'.
    @Test func theOnlyTopLevelPublicNameIsLyrelog() throws {
        let sources = repositoryRoot.appendingPathComponent("Sources/Lyrelog")
        var found: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                // Column 0 is the top level (the sources indent every member).
                let topLevel = line.hasPrefix("public ") || line.hasPrefix("open ")
                    || (line.hasPrefix("@") && line.split(separator: " ").contains("public"))
                guard topLevel else { continue }
                if line.hasPrefix("public enum Lyrelog ") { continue }
                found.append("\(name): \(line)")
            }
        }
        #expect(found.isEmpty, "top-level public declarations: \(found)")
    }

    // Nothing personal in what ships: the words are compared by digest so this file never
    // spells them (the founder's first and last name, his two apps, his GitHub username).
    @Test func thePublicFilesNameNoRealPerson() throws {
        let banned: Set<String> = [
            "4859d1729b697a9ccc9bf17b6a3c676bc935834e5640d203a7cfa489bd45d619",
            "976c617a20d12e4261e40bd8e4ce88493578ec463d082af3b2784b642b82ef0d",
            "b9e5b115929357704655d70d95b79daf630c3cea6e084adec79b4bcb7e0cd7b1",
            "34eb8131c759d8ea0bdf432f943e6e78d8bd2e1d9ad50f2bf166fad074edcea8",
            "7e421181fc7b52ab66f2c22bd396acce92c3cdd9a29122dde0f1b7ddc0eb4435",
        ]
        let files = publicFiles()
        #expect(files.count > 10)
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            #expect(!text.contains("/" + "Users/"), "\(file.lastPathComponent) names a path on someone's machine")
            let lowered = text.lowercased()
            var words = Set(lowered.split { !($0.isLetter || $0.isNumber) }.map(String.init))
            for word in Array(words) { words.formUnion(word.split { !$0.isLetter }.map(String.init)) }
            for word in words {
                let digest = SHA256.hash(data: Data(word.utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(!banned.contains(digest), "\(file.lastPathComponent) names a real person or app")
            }
        }
        let license = try String(contentsOf: repositoryRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(license.contains("Copyright (c) 2026 Lyrelog"))
        let readme = try String(contentsOf: repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("https://github.com/lyrelog/lyrelog-swift"))
    }

    @Test func theVersionIs090() {
        #expect(Lyrelog.version == "0.9.0")
        #expect(DeviceContext.sdkVersion == "lyrelog-swift/0.9.0")
    }
}

// The shared Lyrelog, so these run in the serialized suite.
extension ScreenTests {
    @Test func aLoggerHasTrace() async {
        let transport = GatedTransport(open: true)
        var configuration = testConfiguration()
        configuration.minimumLevel = .trace
        Lyrelog.start(configuration, transport: transport, root: temporaryDirectory())
        defer { Lyrelog.stopNow() }
        Lyrelog.Logger(category: "sync").trace("fine_detail")
        await Lyrelog.flush()
        #expect(transport.lines.first?["level"] as? String == "trace")
        #expect(transport.lines.first?["category"] as? String == "sync")
    }

    @Test func stopNowStopsWithoutSending() async {
        let transport = GatedTransport(open: true)
        Lyrelog.start(testConfiguration(), transport: transport, root: temporaryDirectory())
        Lyrelog.stopNow()
        Lyrelog.info("after_stop")
        await Lyrelog.flush()
        #expect(transport.count == 0)
        #expect(Lyrelog.sessionID == nil)
    }

    // `start` built the engine (directories, file lookups) while holding the lock every log
    // call takes: a log on another thread waited for the disk. Now it builds outside the lock,
    // and what is said meanwhile (a user, a consent) still applies.
    @Test func startBuildsTheEngineWithoutHoldingTheLoggingLock() async {
        let transport = GatedTransport(open: true)
        let answered = OSAllocatedUnfairLock(initialState: false)
        Lyrelog.whileBuilding.withLock { hook in
            hook = {
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    _ = Lyrelog.sessionID
                    Lyrelog.setUser("during-build")
                    Lyrelog.setConsent(.pending)
                    done.signal()
                }
                let inTime = done.wait(timeout: .now() + 2) == .success
                answered.withLock { $0 = inTime }
            }
        }
        Lyrelog.start(testConfiguration(), transport: transport, root: temporaryDirectory())
        Lyrelog.whileBuilding.withLock { $0 = nil }
        defer { Lyrelog.stopNow() }
        #expect(answered.withLock { $0 }, "a call on another thread waited for start to build the engine")
        Lyrelog.info("held")
        await Lyrelog.flush()
        #expect(transport.count == 0, "the consent set while building applies")
        Lyrelog.setConsent(.granted)
        await Lyrelog.flush()
        #expect(transport.messages == ["held"])
        #expect(transport.lines.first?["user_id"] as? String == "during-build")
    }
}
