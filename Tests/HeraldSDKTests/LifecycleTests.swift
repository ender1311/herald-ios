import XCTest
@testable import HeraldSDK

/// `FixtureDeviceInfo` with another app version and build.
private struct VersionInfo: DeviceInfoProvider {
    var version: String
    var build: String
    func current() async -> DeviceInfo {
        var info = await FixtureDeviceInfo().current()
        info.appVersion = version
        info.appBuild = build
        return info
    }
}

/// Every event sent so far, in order.
private func sentEvents(_ harness: CoreHarness, _ core: HeraldCore) async throws -> [[String: HeraldValue]] {
    await core.drain()
    await core.flushNow()
    return try harness.transport.batchBodies()
        .flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
        .compactMap(\.objectValue)
}

private func names(_ events: [[String: HeraldValue]]) -> [String] {
    events.compactMap { $0["name"]?.stringValue ?? $0["type"]?.stringValue }
}

final class LifecycleTests: XCTestCase {
    func testInstallThenNormalLaunchThenUpdate() async throws {
        let harness = CoreHarness()
        var core = harness.makeCore(lifecycle: true)
        await core.start()
        var events = try await sentEvents(harness, core)
        XCTAssertEqual(names(events), ["$app_installed"], "a launch alone starts no session")
        XCTAssertEqual(events[0]["properties"], ["version": "4.2.0", "build": "812"])

        // Same version: nothing.
        core = harness.makeCore(lifecycle: true)
        await core.start()
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(names(sent).count, 1)

        core = harness.makeCore(deviceInfo: VersionInfo(version: "4.3.0", build: "900"), lifecycle: true)
        await core.start()
        events = try await sentEvents(harness, core)
        XCTAssertEqual(names(events).last, "$app_updated")
        XCTAssertEqual(events.last?["properties"], [
            "version": "4.3.0", "build": "900", "previous_version": "4.2.0", "previous_build": "812",
        ])
    }

    func testStateFromAnOlderSdkOnlyStoresTheVersion() async throws {
        let harness = CoreHarness()
        // An SDK before 0.6.0 left state without a version.
        Storage(directory: harness.directory).saveState(PersistedState(deviceId: "d1"))
        let core = harness.makeCore(lifecycle: true)
        await core.start()
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(names(sent), [])
        let version = await core.state.appVersion
        XCTAssertEqual(version, "4.2.0")
    }

    func testOpenedForegroundAndBackground() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore(lifecycle: true)
        await core.pushResponse(messageId: "m1", decisionId: "d1", action: "open", buttonId: nil)
        await core.appDidBecomeActive()
        _ = await core.appDidEnterBackground()
        await core.appDidBecomeActive()
        let events = try await sentEvents(harness, core)
        XCTAssertEqual(
            names(events).filter { $0.hasPrefix("$") },
            ["$app_opened", "$app_foreground", "$app_background", "$app_foreground"]
        )
        let opened = events.first { $0["name"] == "$app_opened" }
        XCTAssertEqual(opened?["properties"], ["from_push": true])
    }

    func testOpenedWithoutPushAndOffSwitch() async throws {
        var harness = CoreHarness()
        var core = harness.makeCore(lifecycle: true)
        await core.appDidBecomeActive()
        let opened = try await sentEvents(harness, core).first { $0["name"] == "$app_opened" }
        XCTAssertEqual(opened?["properties"], ["from_push": false])

        harness = CoreHarness()
        core = harness.makeCore()  // trackLifecycleEvents off
        await core.start()
        await core.appDidBecomeActive()
        _ = await core.appDidEnterBackground()
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(names(sent), ["session_start"])
    }

    func testLifecycleEventsSendInMinimalMode() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore(lifecycle: true) { $0.deviceDataCollection = .minimal }
        await core.start()
        await core.appDidBecomeActive()
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(names(sent), ["$app_installed", "session_start", "$app_opened", "$app_foreground"])
    }

    func testGoingToTheBackgroundAfterAnIdleForegroundStartsNoSession() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore(lifecycle: true)
        await core.appDidBecomeActive()
        harness.clock.advance(35 * 60)  // past the 30-minute foreground timeout, nothing tracked
        _ = await core.appDidEnterBackground()
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(names(sent), ["session_start", "$app_opened", "$app_foreground", "$app_background"])
        XCTAssertEqual(sent.last?["sessionId"], sent.first?["sessionId"])
    }

    func testOnlyARealMoveToTheForegroundSendsForeground() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore(lifecycle: true)
        await core.appDidBecomeActive()
        await core.appDidBecomeActive()  // after a permission alert, Control Center or Face ID: no background between
        _ = await core.appDidEnterBackground()
        await core.appDidBecomeActive()
        await core.appDidBecomeActive()
        let lifecycle = names(try await sentEvents(harness, core)).filter { $0.hasPrefix("$") }
        XCTAssertEqual(lifecycle, ["$app_opened", "$app_foreground", "$app_background", "$app_foreground"])
    }

    func testColdStartAfterTheBackgroundUsesTheBackgroundTimeout() async throws {
        let harness = CoreHarness()
        let timeouts = { (c: inout HeraldConfiguration) in
            c.foregroundSessionTimeout = 60 * 60
            c.backgroundSessionTimeout = 5 * 60
        }
        var core = harness.makeCore(timeouts)
        await core.appDidBecomeActive()
        await core.appDidEnterBackground().value  // its flush ends before the next launch reads the queue
        harness.clock.advance(10 * 60)
        core = harness.makeCore(timeouts)  // killed in the background, launched again
        await core.appDidBecomeActive()
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(names(sent), ["session_start", "session_end", "session_start"])
    }

    func testDeepLinkWithoutAHostSendsTheSchemeOnly() async throws {
        let cases: [(String, HeraldValue)] = [
            ("mailto:a@b.com?subject=hi", ["scheme": "mailto", "source": "link"]),
            ("tel:+15551234567", ["scheme": "tel", "source": "link"]),
            ("https://x.com/a?b", ["scheme": "https", "host": "x.com", "path": "/a", "query": "b", "source": "link"]),
            ("myapp://screen/x", ["scheme": "myapp", "host": "screen", "path": "/x", "source": "link"]),
            ("myapp://screen/x;jsessionid=s", ["scheme": "myapp", "host": "screen", "path": "/x", "source": "link"]),
        ]
        for (url, expected) in cases {
            let harness = CoreHarness()
            let core = harness.makeCore { $0.trackDeepLinkQuery = true }
            await core.deepLinkOpened(URL(string: url)!, source: "link")
            let event = try await sentEvents(harness, core).last
            XCTAssertEqual(event?["properties"], expected, url)
        }
    }

    func testDeepLinkLeavesOutQueryByDefault() async throws {
        let url = URL(string: "lumen://plus/offer/7?code=abc#top")!
        var harness = CoreHarness()
        var core = harness.makeCore()
        await core.deepLinkOpened(url, source: "push")
        var event = try await sentEvents(harness, core).last
        XCTAssertEqual(event?["name"], "$deep_link_opened")
        XCTAssertEqual(event?["properties"], ["scheme": "lumen", "host": "plus", "path": "/offer/7", "source": "push"])

        harness = CoreHarness()
        core = harness.makeCore { $0.trackDeepLinkQuery = true }
        await core.deepLinkOpened(url, source: "link")
        event = try await sentEvents(harness, core).last
        XCTAssertEqual(event?["properties"]?.objectValue?["query"], "code=abc")
        XCTAssertEqual(event?["properties"]?.objectValue?["source"], "link")

        harness = CoreHarness()
        core = harness.makeCore {
            $0.deviceDataCollection = .minimal
            $0.trackDeepLinkQuery = true
        }
        await core.deepLinkOpened(url, source: "link")
        event = try await sentEvents(harness, core).last
        XCTAssertEqual(event?["properties"], ["scheme": "lumen", "host": "plus", "source": "link"], "minimal: scheme and host only")

        harness = CoreHarness()
        core = harness.makeCore { $0.trackDeepLinks = false }
        await core.deepLinkOpened(url, source: "link")
        let sent = try await sentEvents(harness, core)
        XCTAssertEqual(sent.count, 0)
    }

    func testSessionContinuesAcrossARestartWithinTheTimeout() async throws {
        let harness = CoreHarness()
        var core = harness.makeCore()
        await core.track("a", properties: [:])
        _ = await core.appDidEnterBackground()  // persists the last activity
        let first = await core.state.session?.id
        harness.clock.advance(10 * 60)
        core = harness.makeCore()
        await core.track("b", properties: [:])
        let continued = await core.state.session?.id
        XCTAssertEqual(continued, first)

        harness.clock.advance(31 * 60)
        core = harness.makeCore()
        await core.track("c", properties: [:])
        let events = try await sentEvents(harness, core)
        XCTAssertEqual(names(events), ["session_start", "a", "b", "session_end", "session_start", "c"])
        XCTAssertEqual(events[4]["properties"], ["session_index": 2, "previous_session_id": .string(first!)])
        XCTAssertEqual(events[0]["properties"], ["session_index": 1, "previous_session_id": .null])
    }

    func testSeparateForegroundAndBackgroundTimeouts() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore {
            $0.foregroundSessionTimeout = 60 * 60
            $0.backgroundSessionTimeout = 5 * 60
        }
        await core.appDidBecomeActive()
        harness.clock.advance(40 * 60)
        await core.track("foreground_idle", properties: [:])  // within the foreground hour
        _ = await core.appDidEnterBackground()
        harness.clock.advance(6 * 60)
        await core.appDidBecomeActive()  // over the background 5 minutes
        let events = try await sentEvents(harness, core)
        XCTAssertEqual(names(events), ["session_start", "foreground_idle", "session_end", "session_start"])
        XCTAssertEqual(events[3]["properties"]?.objectValue?["session_index"], 2)
    }

    @available(*, deprecated)
    func testDeprecatedSessionTimeoutSetsBoth() {
        var configuration = HeraldConfiguration(appKey: "pk", endpoint: URL(string: "https://h.example.com")!)
        configuration.sessionTimeout = 120
        XCTAssertEqual(configuration.foregroundSessionTimeout, 120)
        XCTAssertEqual(configuration.backgroundSessionTimeout, 120)
    }

    func testQueuedEventsOlderThanTheMaxAgeAreDroppedAndCounted() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore { $0.maxQueuedEventAge = 86_400 }
        harness.transport.enqueueBatchError(URLError(.notConnectedToInternet))
        await core.track("old", properties: [:])
        await core.flushNow()  // offline: stays queued
        harness.clock.advance(2 * 86_400)
        await core.track("new", properties: [:])
        await core.flushNow()
        let body = try XCTUnwrap(harness.transport.batchBodies().last?.objectValue)
        XCTAssertEqual(names(body["events"]?.arrayValue?.compactMap(\.objectValue) ?? []), ["session_start", "new"])
        XCTAssertEqual(body["dropped"], 3, "the first session's start, old and its end were over a day old")
    }
}
