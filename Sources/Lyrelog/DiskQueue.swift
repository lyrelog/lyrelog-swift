import Foundation

/// Events wait on disk until the server confirms them, so a crash, a kill or a week offline
/// loses nothing that reached the disk (up to the caps). Events still in memory, on their way
/// to the writer (usually for a few milliseconds), are lost if the app dies.
///
/// Layout under the root:
///     ready/<millis>-<seq>-<uuid>.ndjson     batches to send, oldest first
///     pending/<millis>-<seq>-<uuid>.ndjson   kept while consent is pending, never sent
///
/// Every event is appended to the open file immediately. A file is "sealed" (becomes a batch
/// and is never written again) when it reaches the size or count limit, or when the uploader
/// asks for it. One sealed file = one request; a retry resends exactly the same bytes.
/// The few FileHandle calls the queue makes, all of the throwing kind. The legacy ones
/// (`seekToEndOfFile`, `write(_:)`) raise an Objective-C exception on a full disk, which no
/// Swift code can catch: the app dies. A protocol so a test can make writes fail.
protocol QueueFileHandle: AnyObject {
    @discardableResult func seekToEnd() throws -> UInt64
    func write<T: DataProtocol>(contentsOf data: T) throws
    func truncate(atOffset offset: UInt64) throws
    func close() throws
}

extension FileHandle: QueueFileHandle {}

actor DiskQueue {
    enum Area: String, CaseIterable, Sendable {
        case ready, pending
    }

    struct Limits: Sendable {
        var maxFileBytes: Int
        var maxFileEvents: Int
        var maxTotalBytes: Int
        var maxAge: TimeInterval
    }

    private struct OpenFile {
        let url: URL
        let area: Area
        let handle: any QueueFileHandle
        var bytes: Int
        var events: Int
    }

    let root: URL
    nonisolated let limits: Limits
    private let fileManager = FileManager.default
    private let now: @Sendable () -> Date
    private let openHandle: @Sendable (URL) throws -> any QueueFileHandle
    private var open: OpenFile?
    /// Orders files made in the same millisecond.
    private var sequence: UInt64 = 0
    /// Every event lost since launch (caps, write failures, refused batches).
    private(set) var droppedEvents = 0
    /// Lost and not yet reported in a `lyrelog_events_dropped` note.
    private var unreportedDrops = 0

    init(root: URL, limits: Limits, now: @escaping @Sendable () -> Date = { Date() },
         openHandle: @escaping @Sendable (URL) throws -> any QueueFileHandle = { try FileHandle(forWritingTo: $0) }) {
        self.root = root
        self.limits = limits
        self.now = now
        self.openHandle = openHandle
        for area in Area.allCases {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(area.rawValue),
                                                     withIntermediateDirectories: true)
        }
    }

    func append(_ line: Data, to area: Area) {
        let size = line.count + 1
        if let current = open, current.area != area || current.bytes + size > limits.maxFileBytes {
            seal()
        }
        do {
            if open == nil { open = try createFile(in: area) }
        } catch {
            noteDropped(1)
            return
        }
        var record = line
        record.append(0x0A)
        do {
            try open!.handle.seekToEnd()
            try open!.handle.write(contentsOf: record)
            open!.bytes += size
            open!.events += 1
        } catch {
            // Usually a full disk. Cut the file back to its last whole line and close it, so
            // what it already holds still goes; if even that fails, the file goes too.
            noteDropped(1)
            let current = open!
            open = nil
            do {
                try current.handle.truncate(atOffset: UInt64(current.bytes))
                try current.handle.close()
                if current.events == 0 { try? fileManager.removeItem(at: current.url) }
            } catch {
                try? current.handle.close()
                try? fileManager.removeItem(at: current.url)
                noteDropped(current.events)
            }
            return
        }
        if open!.events >= limits.maxFileEvents || open!.bytes >= limits.maxFileBytes {
            seal()
        }
    }

    /// Writes an event where the consent of this moment says: `.ready` when granted, `.pending`
    /// when pending, nowhere when denied. Read here, inside the queue, so an event can't be
    /// written after `removeAll()` ran for a denial.
    func appendEvent(_ line: Data, consent: ConsentGate) {
        switch consent.value {
        case .granted: append(line, to: .ready)
        case .pending: append(line, to: .pending)
        case .denied: return
        }
    }

    /// Whether the open file holds anything.
    var hasOpenEvents: Bool { (open?.events ?? 0) > 0 }

    /// Drops since the last call, to report them.
    func takeUnreportedDrops() -> Int {
        defer { unreportedDrops = 0 }
        return unreportedDrops
    }

    /// Put back a count that couldn't be reported.
    func restoreUnreportedDrops(_ count: Int) {
        unreportedDrops += count
    }

    /// Remove a batch that will never be delivered, counting its events.
    func drop(_ batch: URL) {
        noteDropped(lineCount(batch))
        remove(batch)
    }

    private func noteDropped(_ count: Int) {
        droppedEvents += count
        unreportedDrops += count
    }

    /// Close the open file so it can be sent. Then enforce the caps.
    func seal() {
        guard let current = open else { return }
        try? current.handle.close()
        open = nil
        enforceLimits()
    }

    /// Sealed batches waiting to be sent, oldest first.
    func readyBatches() -> [URL] {
        files(in: .ready).filter { $0 != open?.url }
    }

    func contents(of batch: URL) -> Data? {
        try? Data(contentsOf: batch)
    }

    func remove(_ batch: URL) {
        try? fileManager.removeItem(at: batch)
    }

    /// Consent granted: what was kept while pending becomes sendable.
    func promotePending() {
        if open?.area == .pending { seal() }
        for file in files(in: .pending) {
            let target = root.appendingPathComponent(Area.ready.rawValue).appendingPathComponent(file.lastPathComponent)
            try? fileManager.moveItem(at: file, to: target)
        }
    }

    /// Consent denied: nothing recorded may stay on the device.
    func removeAll() {
        if let current = open { try? current.handle.close() }
        open = nil
        for area in Area.allCases {
            for file in files(in: area) { try? fileManager.removeItem(at: file) }
        }
        unreportedDrops = 0
    }

    /// Drop files older than maxAge, then the oldest ones until under maxTotalBytes.
    func enforceLimits() {
        let cutoff = now().addingTimeInterval(-limits.maxAge)
        var all: [(url: URL, created: Date, size: Int)] = []
        for area in Area.allCases {
            for file in files(in: area) where file != open?.url {
                // The time is in the name: no file timestamp API (an App Store required reason).
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                all.append((file, Self.creation(of: file), size))
            }
        }
        var total = all.reduce(0) { $0 + $1.size } + (open?.bytes ?? 0)
        for file in all.sorted(by: { ($0.created, $0.url.lastPathComponent) < ($1.created, $1.url.lastPathComponent) }) {
            guard file.created < cutoff || total > limits.maxTotalBytes else { continue }
            noteDropped(lineCount(file.url))
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }

    // MARK: - Files

    private func createFile(in area: Area) throws -> OpenFile {
        let millis = UInt64(now().timeIntervalSince1970 * 1000)
        sequence += 1
        let name = String(format: "%015llu-%012llu-", millis, sequence) + UUID().uuidString + ".ndjson"
        let url = root.appendingPathComponent(area.rawValue).appendingPathComponent(name)
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS) || os(tvOS) || os(visionOS)
        // Readable after the first unlock, so a background upload can still open it.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            return OpenFile(url: url, area: area, handle: try openHandle(url), bytes: 0, events: 0)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// When a file was made, from the milliseconds at the start of its name.
    static func creation(of file: URL) -> Date {
        let millis = file.lastPathComponent.prefix { $0 != "-" }
        guard let value = UInt64(millis) else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }

    private func files(in area: Area) -> [URL] {
        let directory = root.appendingPathComponent(area.rawValue)
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".ndjson") }.sorted().map { directory.appendingPathComponent($0) }
    }

    private func lineCount(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}
