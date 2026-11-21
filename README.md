# Lyrelog for Swift

Structured logs from your iOS, macOS, tvOS, watchOS or visionOS app to
[Lyrelog](https://lyrelog.com), a hosted log service. No dependencies.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/lyrelog/lyrelog-swift", from: "0.9.0")
```

and add the product `Lyrelog` to your target (in Xcode: File > Add Package Dependencies).

## Use

```swift
import Lyrelog

// As early as possible, e.g. in the App's init.
Lyrelog.start(Lyrelog.Configuration(
    apiKey: "lyr_ing_...",          // ingest-only: it can append events, never read them
    consent: .granted               // the default; .pending until the person chooses
))                                  // endpoint: https://ingest.lyrelog.com unless you pass one

Lyrelog.setUser(playerID)          // optional; attached to every following event
Lyrelog.info("level_completed", attrs: ["level": 12, "duration_ms": .int(ms)])
Lyrelog.error("cloud_save_failed", category: "sync", attrs: ["status": 422], payload: ["response": .string(raw)])

do { try await save.upload() } catch {
    Lyrelog.captureError(error, category: "sync")   // the `exception` event
}

// One logger per area of the app, like OSLog's Logger(category:).
let sync = Lyrelog.Logger(category: "sync")
sync.warning("sync_conflict", attrs: ["records": 2])
await Lyrelog.flush()              // rarely needed: on iOS going to the background already flushes
```

- `message`: a stable event name (`level_completed`), not prose.
- `category`: the area of the app (`sync`, `store`, `purchases`); the dashboard filters by it.
- `attrs`: small fields to filter and chart by: ids, durations, codes, flags.
- `payload`: the big stuff you only read when you open one event: responses, traces.

The types live only under `Lyrelog`, so they never clash with your own or another module's:
`Lyrelog.Configuration`, `Lyrelog.Consent`, `Lyrelog.LogLevel` (also `Lyrelog.Level`) and
`Lyrelog.LogValue` (also `Lyrelog.Value`). `Lyrelog.LogValue(duration)` is the duration in
milliseconds. A `Logger` has every level `Lyrelog` has, `trace` included, plus `log` and
`captureError`.

Two defaults to know: `consent` is `.granted` (events are sent from the start; pass `.pending`
if you ask the person first) and `appAttest` is `true` (see
[Verified events](#verified-events-app-attest)).

`setUser` and `setConsent` may be called before `start`; they apply when it runs (and that
consent wins over `Configuration.consent`).

## Errors, crashes, screens and requests

**Errors**: `Lyrelog.captureError(error)` (or `logger.captureError(error)`) logs the `exception`
event every Lyrelog SDK sends: level `error`, `error_type` and `error_message` attributes, and a
payload with the description, debug description, `NSError` domain and code and the underlying
error.

**Crashes and hangs** come from MetricKit (iOS, macOS, visionOS), on by default
(`captureDiagnostics`). The system hands them over on a later launch, so each becomes an event at
the time it happened, without a session: `app_crashed` (critical: exception, signal, termination
reason, the version and device it happened on, the top frame of your app and up to 60 frames in
the payload), `app_hung` (error, how long), `cpu_overuse`, `disk_write_overuse` and
`slow_launch` (warnings), all in the `diagnostics` area. A report delivered twice is stored once; one more than 7 days old is skipped.
Frames are offsets into each binary, not symbols: symbolicate with the dSYM when you need names.

**Screens**: say where the person is and every event that follows carries it as `screen`
(`attachScreen`), plus a `screen_viewed` event with the screen before and the time spent on it.

```swift
Lyrelog.screen("Settings")                 // anywhere
SettingsView().lyrelogScreen("Settings")   // or in SwiftUI, on appear
```

**Requests**: `http_request` / `http_request_failed` in the `network` area with method, host, a
path, status, duration and size; never the query, headers or body. Pass the endpoint's template
as `route` and that is the path sent. Otherwise every segment that could be an id is folded to
`:id`: anything with a digit or `@ : . % = + ~`, and long mixed-case or unbroken tokens. That
may also fold a harmless word (`feed.json`).

```swift
let (data, response) = try await URLSession.shared.loggedData(for: request, route: "/players/:id/stats")
Lyrelog.Network.record(request, response: response, error: nil, duration: elapsed,
                       route: "/players/:id/stats")   // your own client
```

## What it does for you

| | |
|---|---|
| Never blocks | `log` copies the event and returns; one background writer puts it on disk. The writer never waits on the network. |
| Keeps events across launches | Events wait in Library/Caches/lyrelog (on macOS Library/Caches/<bundle id>/lyrelog, so apps outside the sandbox never share a queue or an install id) until the server confirms them, capped at 20 MB and 7 days (oldest first). What reached the disk survives a crash, a kill or days offline; events still on their way to the writer (milliseconds; at most 10,000 events and about 16 MiB wait in memory, then the oldest are dropped and counted) don't. The system may purge Caches when the device is short of space, and the waiting events go with it. |
| Batches | Up to 500 events or 512 KiB per request (never more than 2,000 or 4 MiB, the server's limits), gzip. An event over 1 MiB once encoded is dropped and counted. |
| When it sends | Every 15 s in the foreground (`uploadInterval`, at least 1 s). On iOS, iPadOS, tvOS and visionOS also when the app goes to the background, inside a background task. macOS and watchOS have no background flush: call `await Lyrelog.flush()` yourself (e.g. on `NSApplication.willTerminateNotification`) or let the next launch send it. Periodic uploads pause in Low Power Mode; Low Data Mode and cellular are allowed (batches are small and gzipped). |
| Retries | Backoff from 1 s doubling to 5 min with full jitter; the server's `Retry-After` is always honoured (up to an hour, the most the server sends), also by a flush. A batch the server keeps failing goes to the back, then is dropped. A refused batch (4xx) is dropped; a revoked key stops sending until the next launch and keeps the data. When the organization's monthly quota is used up (a `429` with `plan` and `limit`), the batch is retried like any `429` and one warning goes to the unified log, again only after a batch has been accepted in between; it waits for the `Retry-After` alone and doesn't count as a failed attempt. After 3 failed uploads in a row (no network, the server unreachable) one line goes to the unified log, then nothing more until an upload succeeds. Uploads never follow redirects. |
| Drops are visible | Events lost to the caps are reported in a `lyrelog_events_dropped` warning (category `lyrelog`) with the count. The SDK's own problems (a wrong endpoint, a 404, rejected lines) go once per launch to the unified log, subsystem `com.lyrelog.sdk`, at debug level. |
| Consent | `.pending` keeps events on the device unsent; `.granted` sends them and those kept while pending; `.denied` deletes everything queued and the install id, and records nothing until consent changes (including events logged a moment before the denial and not yet written). Nothing is ever uploaded unless consent is granted, including what an earlier launch left. |
| Context | App id, version, build, OS, device model, locale, environment, platform, a session id (new after 30 min idle) and an install id. |
| Redacts secrets | Before queueing, any field in `attrs` or `payload` (at any depth, inside arrays too) whose name, lowercased and without `-`, `_`, `.` or spaces, is or ends with `authorization`, `cookie`, `password`, `passwd`, `secret`, `token`, `apikey`, `privatekey`, `credential(s)`, `accesskey` or `signature` is sent as `"[redacted]"`: `X-Api-Key`, `csrf_token`, `Set-Cookie` match, `token_count` and `max_tokens` don't. It runs before anything is cut, so no secret survives in a truncated preview. Only names are checked, never free text such as a message or an error description. |
| Limits | Fits every event to the server's limits before queueing (long strings cut on a character boundary, extra or colliding attributes counted in `lyrelog_dropped_attrs`, big payloads summarised). |

Every knob is in `Configuration`.

### Endpoint

The default is `https://ingest.lyrelog.com`. If you pass one, a pasted `.../v1/events:batch` or
`.../v1` is cut back to the origin. Only `https` is used; plain `http` only to `localhost`,
`127.0.0.1` or `::1` (a local stack). Any other endpoint is refused: nothing is sent and the
events stay on the device.

### Environment

`Configuration.environment` names it; `nil` detects it. At start: `development` for a Debug
build, the simulator, or an ad hoc / development-signed build (one with an embedded provisioning
profile); `testflight` with a sandbox App Store receipt; `production` otherwise (on macOS,
`production` until StoreKit answers). Then, in the background, Lyrelog asks StoreKit
(`AppTransaction.shared.environment`: `xcode` is development, `sandbox` testflight,
`production` production) and events after its answer carry it; that is what tells TestFlight
on macOS. StoreKit shows no prompt for this; offline or signed out, the first answer stays.
`await Lyrelog.detectEnvironment()` gives your code the same answer.

### Redaction

`Configuration.redactedKeys` replaces the list (`nil`, the default, is
`Configuration.defaultRedactedKeys`, the same in every Lyrelog SDK); an empty list turns
redaction off. To add a name, keep the defaults:

```swift
redactedKeys: Lyrelog.Configuration.defaultRedactedKeys + ["pin"]
```

### Stopping

`await Lyrelog.stop()` sends what was logged (waiting at most 2 seconds) and stops; `start` can
be called again afterwards. From synchronous code, `Lyrelog.stopNow()` stops at once without
sending: events still in memory are lost, those on disk go with the next launch.

## Verified events (App Attest)

On a real device, Lyrelog proves with Apple's App Attest that events come from your genuine app,
and the server stores them as verified (`verified_by = "app_attest"`). It is on by default
(`Configuration.appAttest`) and needs two things:

1. The **App Attest** capability on your app target in Xcode (Signing & Capabilities). That is
   the entitlement `com.apple.developer.devicecheck.appattest-environment`; set it to
   `production` for App Store and TestFlight builds. Without it Apple uses the development
   environment.
2. Your **App ID** (Team ID and bundle id) in the project's settings in Lyrelog. Until it is
   set, the server answers that App Attest isn't set up and the SDK stops trying for that launch.

The first time on an install the SDK makes a key in the Secure Enclave, has Apple attest it and
gets a token from the server; later it renews the token with an assertion. Only the key's id is
kept, in the Keychain (this device only); a denial of consent deletes it. Nothing waits for
this: batches go without a token until one exists, and those events are stored unverified, as
they are on Macs, the simulator, app extensions (except watchOS ones) and devices that don't
support App Attest. A failure never stops sending; it is tried again later. `appAttest: false`
turns it off.

## Privacy

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) that Xcode merges into your
app's privacy report: no tracking, no tracking domains, the file-metadata required-reason API
(`C617.1`: the disk queue reads its own files' sizes), and the data it collects (crash data,
performance data, other diagnostic data, a device id), not linked to the person and not used
for tracking.

For the App Store privacy label, declare what your app sends through Lyrelog:

- **Diagnostics**: Crash Data, Performance Data, Other Diagnostic Data (App Functionality).
- **Identifiers > Device ID**: the install id, a random UUID that is not the advertising id,
  is not backed up and is deleted on a denial (App Functionality). Not linked to the person
  unless you also call `setUser`.
- **Identifiers > User ID**, linked to the person: only if you call `setUser`.
- **Usage Data > Product Interaction**: if you log screens or taps (`screen_viewed`, your own
  events).
- Anything else you put in `attrs` or `payload` (emails, purchases...) under its own category.

The server adds the country of the sending address; the address itself is not stored.

## Tests

```bash
swift test
LYRELOG_E2E_KEY=lyr_ing_... LYRELOG_E2E_URL=http://127.0.0.1:8090 swift test --filter EndToEnd   # against a local Lyrelog stack
```

## Licence

MIT.
