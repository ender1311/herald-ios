import XCTest
@testable import HeraldSDK

private func configBody(_ version: String, _ settings: String) -> Data {
    Data(#"{"data":{"version":"\#(version)","settings":\#(settings)}}"#.utf8)
}

final class RemoteConfigTests: XCTestCase {
    func testTheCachedConfigAppliesAtLaunchBeforeTheFetch() async throws {
        let harness = CoreHarness()
        Storage(directory: harness.directory).saveRemoteConfig(configBody("v1", #"{"flushIntervalSeconds":60,"dataCollection":"minimal"}"#), appKey: "pk_test")
        let core = harness.makeCore()
        let configuration = await core.configuration
        XCTAssertEqual(configuration.flushInterval, 60)
        XCTAssertEqual(configuration.deviceDataCollection, .minimal)
        XCTAssertEqual(core.remoteVersion.withLock { $0 }, "v1")
        // The launch fetch asks with the cached version; a 304 keeps it.
        await core.start()
        await core.drain()
        XCTAssertEqual(harness.transport.configRequests.first?.value(forHTTPHeaderField: "If-None-Match"), #""v1""#)
        XCTAssertEqual(harness.transport.configRequests.first?.value(forHTTPHeaderField: "x-herald-app-key"), "pk_test")
        let after = await core.configuration
        XCTAssertEqual(after.flushInterval, 60)
    }

    func testRemoteValuesOverrideAndAbsentOnesFallBack() async throws {
        let harness = CoreHarness()
        harness.transport.enqueueConfig(FakeResponse(status: 200, body: configBody("v2", #"{"foregroundSessionTimeoutSeconds":120,"trackDeepLinks":false,"trackExternalPushes":false,"flushIntervalSeconds":"x"}"#)))
        let core = harness.makeCore { $0.flushInterval = 15 }
        await core.start()
        await core.drain()
        let c = await core.configuration
        XCTAssertEqual(c.foregroundSessionTimeout, 120)
        XCTAssertFalse(c.trackDeepLinks)
        XCTAssertFalse(c.trackExternalPushes)
        XCTAssertEqual(c.flushInterval, 15, "a mistyped value keeps the app's")
        XCTAssertEqual(c.backgroundSessionTimeout, 30 * 60)
        XCTAssertEqual(core.remoteVersion.withLock { $0 }, "v2")
        // Saved: the next launch starts with it.
        XCTAssertEqual(Storage(directory: harness.directory).loadRemoteConfig(appKey: "pk_test")?.version, "v2")

        // A failed fetch or an unreadable body keeps it.
        harness.transport.enqueueConfigError(URLError(.notConnectedToInternet))
        harness.transport.enqueueConfig(FakeResponse(status: 200, body: Data("nope".utf8)))
        for _ in 0..<2 {
            harness.clock.advance(HeraldCore.configFetchInterval)
            await core.appDidBecomeActive()
            await core.drain()
        }
        XCTAssertEqual(harness.transport.configRequests.count, 3)
        XCTAssertEqual(core.remoteVersion.withLock { $0 }, "v2")
        let still = await core.configuration
        XCTAssertEqual(still.foregroundSessionTimeout, 120)
    }

    func testTheKillSwitchStopsCollectionAndClearsTheQueueUntilTurnedBackOn() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("before", properties: [:])
        await core.applyRemote(RemoteConfig(version: "off", settings: ["enabled": false]))
        let cleared = await core.queuedCount
        XCTAssertEqual(cleared, 0)
        await core.track("during", properties: [:])
        await core.flushNow()
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(harness.transport.batchRequests.isEmpty)
        // Config is still fetched while off.
        harness.transport.enqueueConfig(FakeResponse(status: 200, body: configBody("on", "{}")))
        harness.clock.advance(HeraldCore.configFetchInterval)
        await core.appDidBecomeActive()
        await core.drain()
        await core.track("after", properties: [:])
        await core.flushNow()
        let names = try harness.transport.batchBodies()
            .flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
            .compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(names, ["after"])
    }

    func testTheFetchRunsAtLaunchThenAtMostHourlyOnForeground() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.start()
        await core.appDidBecomeActive()
        harness.clock.advance(59 * 60)
        await core.appDidEnterBackground().value
        await core.appDidBecomeActive()
        await core.drain()
        XCTAssertEqual(harness.transport.configRequests.count, 1)
        harness.clock.advance(60)
        await core.appDidEnterBackground().value
        await core.appDidBecomeActive()
        await core.drain()
        XCTAssertEqual(harness.transport.configRequests.count, 2)
    }

    func testConsentIsPersistedSentInContextThenCleared() async throws {
        let harness = CoreHarness()
        var core = harness.makeCore()
        await core.setConsent(basis: .legitimateInterests, documentId: "privacy", documentVersion: String(repeating: "x", count: 101))
        let rejected = await core.state.consent
        XCTAssertNil(rejected, "a document version over 100 characters is refused")
        await core.setConsent(basis: .legitimateInterests, documentId: "privacy", documentVersion: "")
        core = harness.makeCore()  // persisted across launches
        await core.track("a", properties: [:])
        await core.flushNow()
        XCTAssertEqual(try harness.transport.batchBodies().last?.objectValue?["context"]?.objectValue?["consent"], [
            "basis": "legitimate_interests", "documentId": "privacy", "recordedAt": .string(WireDate.format(t0)),
        ])
        await core.clearConsent()
        await core.track("b", properties: [:])
        await core.flushNow()
        XCTAssertNil(try harness.transport.batchBodies().last?.objectValue?["context"]?.objectValue?["consent"])
    }

    func testACachedKillSwitchAppliesAtLaunch() async throws {
        let harness = CoreHarness()
        Storage(directory: harness.directory).saveRemoteConfig(configBody("off", #"{"enabled":false}"#), appKey: "pk_test")
        let core = harness.makeCore()
        await core.track("early", properties: [:])
        await core.flushNow()
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(harness.transport.batchRequests.isEmpty)
    }

    func testAnotherAppKeysCachedConfigIsIgnored() async throws {
        let harness = CoreHarness()
        Storage(directory: harness.directory).saveRemoteConfig(configBody("off", #"{"enabled":false}"#), appKey: "pk_staging")
        let core = harness.makeCore()
        XCTAssertNil(core.remoteVersion.withLock { $0 })
        await core.track("a", properties: [:])
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 2, "session_start and the event")
    }

    func testAPushTokenRegisteredWhileOffIsSentWhenCollectionResumes() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.applyRemote(RemoteConfig(version: "off", settings: ["enabled": false]))
        await core.setPushToken(hex: "ab12")
        await core.setSubscription(.email, .unsubscribed)
        await core.track("dropped", properties: [:])
        await core.flushNow()
        XCTAssertTrue(harness.transport.batchRequests.isEmpty, "nothing is sent while off")
        await core.applyRemote(RemoteConfig(version: "on", settings: [:]))
        await core.drain()
        await core.flushNow()
        let types = try harness.transport.batchBodies()
            .flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
            .compactMap { $0.objectValue?["type"]?.stringValue }
        XCTAssertTrue(types.contains("push_token"))
        XCTAssertTrue(types.contains("subscription"))
        XCTAssertFalse(types.contains("track"))
    }

    func testCrashReportsRespectTheKillSwitch() async throws {
        let harness = CoreHarness()
        harness.transport.enqueueDiagnosticsError(URLError(.notConnectedToInternet))
        var core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics([DiagnosticReport(kind: "crash", payload: [:], build: "1", osVersion: "18", deviceModel: "x")])
        await core.drain()
        XCTAssertEqual(harness.transport.diagnosticsRequests.count, 1, "kept on the device for the next launch")
        await core.applyRemote(RemoteConfig(version: "off", settings: ["enabled": false]))
        await core.recordDiagnostics([DiagnosticReport(kind: "hang", payload: [:], build: "1", osVersion: "18", deviceModel: "x")])
        await core.drain()
        // The launch path, with the kill switch cached.
        Storage(directory: harness.directory).saveRemoteConfig(configBody("off", #"{"enabled":false}"#), appKey: "pk_test")
        core = harness.makeCore { $0.crashReports = true }
        await core.start()
        await core.drain()
        XCTAssertEqual(harness.transport.diagnosticsRequests.count, 1)
    }

    func testTheConsentRecordMatchesTheSharedFixture() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setConsent(basis: .consent, documentId: "privacy-policy", documentVersion: "2026-11")
        await core.track("a", properties: [:])
        await core.flushNow()
        let expected = try fixtureJSON("batch-consent").objectValue?["context"]?.objectValue?["consent"]
        XCTAssertNotNil(expected)
        XCTAssertEqual(try harness.transport.batchBodies().last?.objectValue?["context"]?.objectValue?["consent"], expected)
    }
}
