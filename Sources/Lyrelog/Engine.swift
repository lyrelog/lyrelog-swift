import Foundation
import os

/// Wires the pieces together. Three long-lived tasks, no task per event or per request:
///
/// - the **writer** takes events from the intake and appends them to disk, nothing else, so it
///   never waits on the network;
/// - the **control** task applies consent changes to the files (promote, delete), in order;
/// - the **pump** wakes every `uploadInterval` and runs an upload round.
///
/// Consent itself is not a message: it lives in a `ConsentGate` that the writer, the queue and
/// the uploader read at the moment they act. Control messages travel in their own unbounded
/// stream, so a full intake can only ever drop events, never a denial or a flush.
final class Engine: Sendable {
    /// Events waiting in memory between the caller and the disk writer. Past this, the newest
    /// events are kept and the oldest dropped (logging must never grow without bound).
    static let intakeCapacity = 10_000
    /// The same cap in bytes (an estimate per event, `PendingEvent.estimatedBytes`), as the
    /// JavaScript, Python and Go SDKs have: big events logged in a loop outrun the writer,
    /// which encodes each one, and without it the app ran out of memory.
    static let intakeBytes = 16 << 20

    let queue: DiskQueue
    let uploader: Uploader
    let consent: ConsentGate
    private let transport: any HTTPTransport
    /// Wakes the writer; the events themselves wait in `Progress`, which can drop the oldest
    /// by count and by bytes.
    private let intake: AsyncStream<Void>.Continuation
    private let controls: AsyncStream<Consent>.Continuation
    private let progress: Progress
    private let rounds: Rounds
    private let tasks: [Task<Void, Never>]

    private let resolution: Task<Void, Never>?

    /// `resolveEnvironment` refines the detected environment later (StoreKit); it is used
    /// only when the configuration doesn't name one.
    init(configuration: Configuration, transport: any HTTPTransport = URLSessionTransport(), root: URL? = nil,
         intakeCapacity: Int = Engine.intakeCapacity, intakeBytes: Int = Engine.intakeBytes,
         resolveEnvironment: (@Sendable () async -> String?)? = { await Lyrelog.detectEnvironment() },
         attestation override: Attestation? = nil) {
        let storage = root ?? Engine.defaultDirectory(configuration)
        let queue = DiskQueue(
            root: storage,
            limits: .init(
                maxFileBytes: configuration.effectiveMaxBatchBytes,
                maxFileEvents: configuration.effectiveMaxBatchEvents,
                maxTotalBytes: configuration.maxDiskBytes,
                maxAge: configuration.maxEventAge.seconds
            )
        )
        let consent = ConsentGate(configuration.consent)
        let origin = Configuration.ingestOrigin(configuration.endpoint)
        if origin == nil {
            SDKLog.once("endpoint", "lyrelog: the endpoint must be https (plain http only to localhost); nothing will be sent, events stay on the device")
        }
        // App Attest runs beside the uploads and never holds them (`Attestation`).
        let attestation: Attestation? = override ?? {
            guard configuration.appAttest, let origin else { return nil }
            return Attestation.system(origin: origin, apiKey: configuration.apiKey, transport: transport)
        }()
        let uploader = Uploader(endpoint: origin, apiKey: configuration.apiKey,
                                transport: transport, queue: queue, consent: consent, attestation: attestation)
        let progress = Progress(capacity: intakeCapacity, maxBytes: intakeBytes)
        let (wakeups, intake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Unbounded on purpose: a handful per launch, and none may be lost.
        let (controlStream, controls) = AsyncStream<Consent>.makeStream(bufferingPolicy: .unbounded)
        let identity = InstallIdentity(directory: root ?? configuration.storageDirectory ?? Engine.supportDirectory())
        let environment = configuration.environment.flatMap(Lyrelog.environmentName) ?? Lyrelog.detectedEnvironment
        let platform = configuration.platform.flatMap(Lyrelog.environmentName) ?? DeviceContext.platform
        let resource = ResourceBox(DeviceContext.resource(environment: environment, platform: platform, wrapper: configuration.wrapper))
        if configuration.environment.flatMap(Lyrelog.environmentName) == nil, let resolveEnvironment {
            resolution = Task.detached(priority: .utility) {
                if let resolved = await resolveEnvironment().flatMap(Lyrelog.environmentName) {
                    resource.setEnvironment(resolved)
                }
            }
        } else {
            resolution = nil
        }
        let rounds = Rounds(queue: queue, uploader: uploader, consent: consent, progress: progress,
                            identity: identity, resource: resource, intakeCapacity: intakeCapacity)

        // The launch consent is the first control: denied deletes what an earlier launch left,
        // granted makes what it kept pending sendable.
        progress.submitControl(configuration.consent, consent: consent, to: controls)

        let control = Task {
            await queue.enforceLimits()
            for await value in controlStream {
                switch value {
                case .granted:
                    await queue.promotePending()
                    // Started early so the first batches already carry a token, never waited for.
                    await attestation?.prepare()
                case .denied:
                    await queue.removeAll()
                    await queue.onDisk { identity.forget() }
                    await attestation?.forget()
                case .pending: break
                }
                progress.controlDone()
            }
        }

        let redaction = EventPreparation.Redaction(configuration.redactedKeys)
        let writer = Task {
            for await _ in wakeups {
                while !Task.isCancelled, let event = progress.takeEvent() {
                if let installID = await identity.resolve(unless: consent, on: queue) {
                    let wire = WireEvent(event, installID: installID, resource: resource.value,
                                         redaction: redaction)
                    if let line = try? wire.encodedLine() {
                        if line.count > EventPreparation.maxLineBytes {
                            progress.noteTooLarge()
                        } else {
                            await queue.appendEvent(line, consent: consent)
                        }
                    }
                }
                progress.eventDone()
                }
            }
        }

        let interval = configuration.effectiveUploadInterval
        let pauseInLowPower = configuration.pauseUploadsInLowPowerMode
        let pump = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                if pauseInLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { continue }
                await rounds.run(force: false)
            }
        }

        self.queue = queue
        self.uploader = uploader
        self.consent = consent
        self.transport = transport
        self.intake = intake
        self.controls = controls
        self.progress = progress
        self.rounds = rounds
        self.tasks = [control, writer, pump]
    }

    func enqueue(_ event: PendingEvent) {
        progress.submitEvent(event, wake: intake)
    }

    func setConsent(_ value: Consent) {
        progress.submitControl(value, consent: consent, to: controls)
    }

    /// Returns once every event logged and every consent change made before this call is
    /// applied on disk, and one forced upload round ran (when consent is granted, the key
    /// works and the server hasn't asked to wait).
    func flush() async {
        // A stopped engine sends nothing more: the background observer may still flush it.
        guard !progress.isClosed else { return }
        await progress.waitForEverythingSubmitted()
        await rounds.run(force: true)
    }

    /// Stops at once: events still in memory are lost, files on disk stay for the next launch,
    /// waiting flushes return, and the URL session is released.
    func stop() {
        intake.finish()
        controls.finish()
        tasks.forEach { $0.cancel() }
        resolution?.cancel()
        progress.close()
        transport.invalidate()
    }

    /// Returns once the background environment detection finished (tests).
    func environmentResolved() async {
        await resolution?.value
    }

    /// Application Support survives cache purges, so the install id lives there.
    static func supportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return perApp(support).appendingPathComponent("lyrelog", isDirectory: true)
    }

    static func defaultDirectory(_ configuration: Configuration) -> URL {
        if let custom = configuration.storageDirectory { return custom }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return perApp(caches).appendingPathComponent("lyrelog", isDirectory: true)
    }

    /// On a Mac outside the sandbox, Caches and Application Support are shared by every app of
    /// the user: without the app's own folder, two apps with Lyrelog would share one queue (one
    /// app's events sent with the other's key) and one install id. Elsewhere the directory is
    /// already the app's container.
    private static func perApp(_ directory: URL) -> URL {
        #if os(macOS)
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return directory.appendingPathComponent(app, isDirectory: true)
        #else
        return directory
        #endif
    }
}

/// One upload round: report drops, seal the open file only when it will be sent, upload.
struct Rounds: Sendable {
    let queue: DiskQueue
    let uploader: Uploader
    let consent: ConsentGate
    let progress: Progress
    let identity: InstallIdentity
    let resource: ResourceBox
    let intakeCapacity: Int

    func run(force: Bool) async {
        guard !progress.isClosed else { return }
        // During a backoff, a Retry-After, without consent or with a refused key nothing is
        // sealed: the open file keeps growing instead of leaving one tiny file per tick.
        guard await uploader.willAttempt(force: force) else { return }
        await reportDrops()
        // A backlog goes first; the open file is sealed when nothing older is waiting...
        if await queue.readyBatches().isEmpty { await queue.seal() }
        let report = await uploader.uploadReady(force: force)
        // ...or once the backlog went through.
        if !report.stoppedForRetry, report.delivered + report.dropped > 0, await queue.hasOpenEvents,
           await uploader.willAttempt(force: force) {
            await queue.seal()
            await uploader.uploadReady(force: force)
        }
    }

    /// Events lost to the caps since the last report become one `lyrelog_events_dropped`
    /// warning, the same note the other Lyrelog SDKs send.
    private func reportDrops() async {
        let (memory, tooLarge) = progress.takeMemoryDrops()
        let disk = await queue.takeUnreportedDrops()
        let total = memory + tooLarge + disk
        guard total > 0 else { return }
        let note = PendingEvent(id: UUID(), timestamp: Date(), level: .warning, category: "lyrelog",
                                message: "lyrelog_events_dropped",
                                attributes: ["count": .int(total), "in_memory": .int(memory), "too_large": .int(tooLarge),
                                             "on_disk": .int(disk), "max_queue": .int(intakeCapacity)],
                                payload: nil, userID: nil, sessionID: "")
        guard let installID = await identity.resolve(unless: consent, on: queue),
              let line = try? WireEvent(note, installID: installID, resource: resource.value).encodedLine() else { return }
        await queue.appendEvent(line, consent: consent)
    }
}

/// The resource of this launch; only its environment can change, once StoreKit answers.
final class ResourceBox: Sendable {
    private let state: OSAllocatedUnfairLock<Resource>

    init(_ resource: Resource) {
        state = OSAllocatedUnfairLock(initialState: resource)
    }

    var value: Resource { state.withLock { $0 } }

    func setEnvironment(_ environment: String) {
        state.withLock { $0.environment = environment }
    }
}

/// Counts what went into the streams and what the tasks finished, so a flush can wait for
/// exactly what came before it, whatever the intake dropped.
final class Progress: Sendable {
    private struct Waiter: Sendable {
        let events: Int
        let controls: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct Waiting: Sendable {
        let event: PendingEvent
        let bytes: Int
    }

    private struct State: Sendable {
        /// Events on their way to the writer, oldest first from `head`; a taken or dropped
        /// slot is nil at once, so its memory goes then.
        var buffer: [Waiting?] = []
        var head = 0
        var bufferedBytes = 0
        var eventsIn = 0
        var eventsDone = 0
        var controlsIn = 0
        var controlsDone = 0
        var memoryDrops = 0
        var tooLarge = 0
        var closed = false
        var waiters: [Waiter] = []

        mutating func takeSatisfied() -> [CheckedContinuation<Void, Never>] {
            var ready: [CheckedContinuation<Void, Never>] = []
            let done = (events: eventsDone, controls: controlsDone, closed: closed)
            waiters.removeAll { waiter in
                guard done.closed || (done.events >= waiter.events && done.controls >= waiter.controls) else { return false }
                ready.append(waiter.continuation)
                return true
            }
            return ready
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int
    private let maxBytes: Int

    init(capacity: Int = Engine.intakeCapacity, maxBytes: Int = Engine.intakeBytes) {
        self.capacity = max(1, capacity)
        self.maxBytes = maxBytes
    }

    /// Keeps the event for the writer and wakes it. Past `capacity` events or `maxBytes`, the
    /// oldest waiting ones are dropped (counted) until it fits; the newest always stays.
    func submitEvent(_ event: PendingEvent, wake writer: AsyncStream<Void>.Continuation) {
        let bytes = event.estimatedBytes
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.eventsIn += 1
            guard !state.closed else {
                state.eventsDone += 1
                return state.takeSatisfied()
            }
            state.buffer.append(Waiting(event: event, bytes: bytes))
            state.bufferedBytes += bytes
            var dropped = false
            while state.buffer.count - state.head > 1,
                  state.buffer.count - state.head > capacity || state.bufferedBytes > maxBytes {
                // The oldest waiting event makes room: it will never be written.
                Self.popOldest(&state)
                state.eventsDone += 1
                state.memoryDrops += 1
                dropped = true
            }
            return dropped ? state.takeSatisfied() : []
        }
        writer.yield(())
        ready.forEach { $0.resume() }
    }

    /// The oldest waiting event, for the writer.
    func takeEvent() -> PendingEvent? {
        state.withLock { state in
            guard state.head < state.buffer.count else { return nil }
            return Self.popOldest(&state)
        }
    }

    @discardableResult
    private static func popOldest(_ state: inout State) -> PendingEvent? {
        let waiting = state.buffer[state.head]
        state.buffer[state.head] = nil
        state.head += 1
        state.bufferedBytes -= waiting?.bytes ?? 0
        if state.head == state.buffer.count {
            state.buffer.removeAll(keepingCapacity: true)
            state.head = 0
        } else if state.head >= 1024, state.head * 2 >= state.buffer.count {
            state.buffer.removeFirst(state.head)
            state.head = 0
        }
        return waiting?.event
    }

    /// Sets the gate and queues the file work under one lock, so the gate always ends up with
    /// the value of the last control applied.
    func submitControl(_ value: Consent, consent: ConsentGate, to controls: AsyncStream<Consent>.Continuation) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            consent.value = value
            state.controlsIn += 1
            if case .terminated = controls.yield(value) { state.controlsDone += 1 }
            return state.takeSatisfied()
        }
        ready.forEach { $0.resume() }
    }

    func eventDone() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.eventsDone += 1
            return state.takeSatisfied()
        }
        ready.forEach { $0.resume() }
    }

    func controlDone() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.controlsDone += 1
            return state.takeSatisfied()
        }
        ready.forEach { $0.resume() }
    }

    func noteTooLarge() {
        state.withLock { $0.tooLarge += 1 }
    }

    /// Events dropped before reaching the disk since the last call: the intake overflowed, or
    /// one encoded to more than the server takes in a line.
    func takeMemoryDrops() -> (overflow: Int, tooLarge: Int) {
        state.withLock { state in
            defer {
                state.memoryDrops = 0
                state.tooLarge = 0
            }
            return (state.memoryDrops, state.tooLarge)
        }
    }

    func waitForEverythingSubmitted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.closed || (state.eventsDone >= state.eventsIn && state.controlsDone >= state.controlsIn) {
                    return true
                }
                state.waiters.append(Waiter(events: state.eventsIn, controls: state.controlsIn, continuation: continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Whether the engine stopped.
    var isClosed: Bool { state.withLock { $0.closed } }

    /// Releases every waiting flush (the engine stopped).
    func close() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.closed = true
            state.buffer = []
            state.head = 0
            state.bufferedBytes = 0
            return state.takeSatisfied()
        }
        ready.forEach { $0.resume() }
    }
}

/// Runs `operation` without waiting longer than `timeout` for it. The operation is unstructured,
/// so one that never returns can't hold the caller. True when it finished in time.
@discardableResult
func withDeadline(_ timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let decide: @Sendable (Bool) -> Bool = { value in
        outcome.withLock { current in
            guard current == nil else { return false }
            current = value
            return true
        }
    }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        Task {
            await operation()
            if decide(true) { continuation.resume(returning: true) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if decide(false) { continuation.resume(returning: false) }
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (whole, fraction) = components
        return TimeInterval(whole) + TimeInterval(fraction) / 1e18
    }
}
