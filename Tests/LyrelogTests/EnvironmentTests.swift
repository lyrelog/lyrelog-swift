import Foundation
import Testing
@testable import Lyrelog

struct EnvironmentDetectionTests {
    typealias Case = (debug: Bool, simulator: Bool, store: StoreEnvironment?, profile: Bool, sandboxReceipt: Bool, expected: String)

    @Test(arguments: [
        (true, false, .production, false, false, "development"),   // a Debug build, whatever the store says
        (false, true, nil, false, false, "development"),           // the simulator
        (false, false, .xcode, true, false, "development"),        // run from Xcode
        (false, false, .sandbox, false, true, "testflight"),       // TestFlight (iOS or macOS)
        (false, false, .production, false, false, "production"),  // the App Store
        (false, false, nil, true, true, "development"),            // ad hoc / development signed: a sandbox receipt but a profile
        (false, false, nil, false, true, "testflight"),            // no app transaction yet (offline), TestFlight receipt
        (false, false, nil, false, false, "production"),
    ] as [Case])
    func theEnvironmentIsTold(_ c: Case) {
        #expect(Lyrelog.environment(debug: c.debug, simulator: c.simulator, store: c.store,
                                    hasProvisioningProfile: c.profile, sandboxReceipt: c.sandboxReceipt) == c.expected)
    }

    @Test func eventsAfterTheStoreAnswersCarryItsEnvironment() async {
        let transport = GatedTransport(open: true)
        var configuration = testConfiguration()
        configuration.environment = nil
        let engine = Engine(configuration: configuration, transport: transport, root: temporaryDirectory(),
                            resolveEnvironment: { "testflight" })
        defer { engine.stop() }
        await engine.environmentResolved()
        engine.enqueue(event("later"))
        await engine.flush()
        let resource = transport.lines.last?["resource"] as? [String: Any]
        #expect(resource?["environment"] as? String == "testflight")
    }

    @Test func anEnvironmentTheAppSetIsNeverReplaced() async {
        let transport = GatedTransport(open: true)
        var configuration = testConfiguration()
        configuration.environment = "staging"
        let engine = Engine(configuration: configuration, transport: transport, root: temporaryDirectory(),
                            resolveEnvironment: { "testflight" })
        defer { engine.stop() }
        await engine.environmentResolved()
        engine.enqueue(event("e"))
        await engine.flush()
        #expect((transport.lines.last?["resource"] as? [String: Any])?["environment"] as? String == "staging")
    }
}
