import XCTest
@testable import HeraldSDK

final class WireFormatTests: XCTestCase {
    /// Drives the public-equivalent calls that produce batch-full.json and compares the encoded batch.
    func testFullBatchMatchesFixture() async throws {
        let harness = CoreHarness()
        Storage(directory: harness.directory).saveState(PersistedState(deviceId: "6c1f2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b"))
        let core = harness.makeCore()
        let card = try XCTUnwrap(MessagesPayload.decode(fixtureData("messages")).contentCards.first)

        await core.identify(userId: "u_123", traits: ["plan": "free"])
        await core.track("workout_completed", properties: ["minutes": 32])
        await core.screen("Home", properties: [:])
        await core.trackPurchase(productId: "plus_annual", price: 59.99, currency: "USD", quantity: 1, properties: [:])
        await core.setAttributes([
            "favorite_workout": "strength", "workouts_30d": 14, "beta_tester": true,
            "goals": ["strength", "mobility"], "$email": "maya@example.com",
        ])
        await core.setSubscription(.push, .optedIn)
        let token = Data([0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18, 0x29, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90])
        await core.setPushToken(hex: PushToken.hex(token + token))
        await core.logCardClick(card)
        harness.clock.advance(412)
        await core.ensureSession()
        await core.endSessionForTesting()
        harness.clock.set(t0)
        await core.drain()
        await core.flushNow()

        let bodies = try harness.transport.batchBodies()
        XCTAssertEqual(bodies.count, 1)
        var actual = try XCTUnwrap(bodies.first?.objectValue)
        let expected = try XCTUnwrap(fixtureJSON("batch-full").objectValue)

        XCTAssertEqual(shape(.object(actual)), shape(.object(expected)), "same keys and value types at every level")

        // session_end is recorded when the session's last activity happened (412 s in), unlike the fixture's flat timestamps.
        var events = try XCTUnwrap(actual["events"]?.arrayValue)
        var last = try XCTUnwrap(events.last?.objectValue)
        XCTAssertEqual(last["timestamp"], "2026-11-09T14:06:52.000Z")
        last["timestamp"] = "2026-11-09T14:00:00.000Z"
        events[events.count - 1] = .object(last)
        // The fixture's sessionId (1762696800000) is 2025-11-09 in epoch ms while its timestamps say 2026;
        // the SDK derives sessionId from the real start time, so align it before the exact comparison.
        XCTAssertEqual(events.first?.objectValue?["sessionId"], .string(String(Int64(t0.timeIntervalSince1970 * 1000))))
        events = events.map { event in
            guard var object = event.objectValue else { return event }
            object["sessionId"] = "1762696800000"
            return .object(object)
        }
        actual["events"] = .array(events)
        for key in expected.keys.sorted() {
            XCTAssertEqual(actual[key], expected[key], "batch.\(key)")
        }
        let request = try XCTUnwrap(harness.transport.batchRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-herald-app-key"), "pk_test")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testMinimalModeOmitsTierTwoKeys() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore { $0.deviceDataCollection = .minimal }
        await core.track("app_opened", properties: [:])
        await core.drain()
        await core.flushNow()

        let body = try XCTUnwrap(harness.transport.batchBodies().first?.objectValue)
        let context = try XCTUnwrap(body["context"]?.objectValue)
        let expectedKeys = try XCTUnwrap(fixtureJSON("batch-minimal").objectValue?["context"]?.objectValue?.keys)
        XCTAssertEqual(Set(context.keys), Set(expectedKeys))
        for key in ["locale", "language", "timezone", "device", "screen", "network", "push"] {
            XCTAssertNil(context[key], "\(key) must be absent in minimal mode")
        }
        XCTAssertEqual(body["userId"], .null)
    }

    func testStandardContextHasTierTwo() {
        let context = DeviceContext.build(
            DeviceInfo(
                appName: "A", appVersion: "1", appBuild: "1", appNamespace: "a", osName: "iOS", osVersion: "18.1",
                region: nil, manufacturer: "Apple", model: "m", deviceType: "phone", locale: "en-US",
                language: "en", timezone: "UTC", networkType: nil, pushAuthorization: nil
            ),
            collection: .standard
        ).objectValue ?? [:]
        XCTAssertEqual(Set(context.keys), ["app", "os", "device", "locale", "language", "timezone"])
    }

    func testDecodesMessagesSkippingMalformed() throws {
        let payload = try MessagesPayload.decode(fixtureData("messages"))
        XCTAssertEqual(payload.contentCards.map(\.id), ["msg_1", "msg_3", "msg_4"])
        XCTAssertEqual(payload.inAppMessages.map(\.id), ["msg_2", "msg_5", "msg_6"], "msg_bad (type hologram) is skipped")

        let card = payload.contentCards[0]
        XCTAssertEqual(card.type, .captionedImage)
        XCTAssertEqual(card.url, URL(string: "lumen://plus/strength"))
        XCTAssertEqual(card.extras, ["campaign": "upgrade"])
        XCTAssertTrue(card.pinned)
        XCTAssertEqual(card.decisionId, "dec_1")
        XCTAssertEqual(payload.contentCards[1].expiresAt, WireDate.parse("2026-12-01T00:00:00.000Z"))
        XCTAssertNil(payload.contentCards[2].title)

        let modal = payload.inAppMessages[0]
        XCTAssertEqual(modal.type, .modal)
        XCTAssertEqual(modal.priority, 10)
        XCTAssertEqual(modal.trigger, .event(name: "workout_completed", propertyFilters: [PropertyFilter(key: "minutes", op: .gt, value: 20)]))
        XCTAssertEqual(modal.content.buttons.map(\.action), [.deeplink(URL(string: "lumen://plus")!), .close])
        XCTAssertEqual(payload.inAppMessages[1].reEligibility, .afterHours(24))
        XCTAssertEqual(payload.inAppMessages[1].style.backgroundColor, "#101828")
        XCTAssertEqual(payload.inAppMessages[1].content.dismissAfterSeconds, 6)
        XCTAssertEqual(payload.inAppMessages[2].trigger, .pushOpen)
        XCTAssertNotNil(payload.inAppMessages[2].content.html)
    }

    func testMalformedItemsAndUnknownOperatorsAreSkipped() throws {
        let json = #"""
        {"data":{"contentCards":[{"id":"a","type":"classic"},{"type":"classic"},{"id":"c","type":"poster"},42],
        "inAppMessages":[{"id":"m1","type":"modal","trigger":{"type":"event","event":"x","propertyFilters":[{"key":"k","op":"regex","value":1}]}},
        {"id":"m2","type":"slideup","trigger":{"type":"geofence"}},
        {"id":"m3","type":"html","trigger":{"type":"session_start"},"content":{}},
        {"id":"m4","type":"full","trigger":{"type":"session_start"}}]}}
        """#
        let payload = try MessagesPayload.decode(Data(json.utf8))
        XCTAssertEqual(payload.contentCards.map(\.id), ["a"])
        XCTAssertEqual(payload.inAppMessages.map(\.id), ["m4"])
        XCTAssertEqual(payload.inAppMessages[0].reEligibility, .once)
    }

    func testEmptyMessagesFixture() throws {
        let payload = try MessagesPayload.decode(fixtureData("messages-empty"))
        XCTAssertTrue(payload.contentCards.isEmpty)
        XCTAssertTrue(payload.inAppMessages.isEmpty)
    }

    func testPushTokenHexAndProfileParsing() {
        XCTAssertEqual(PushToken.hex(Data([0x00, 0xAB, 0x0F, 0xFF])), "00ab0fff")
        let profile = "junk<plist><dict><key>aps-environment</key>\n\t<string>development</string></dict>"
        XCTAssertEqual(PushEnvironment.apsEnvironment(inProfile: profile), "development")
        XCTAssertNil(PushEnvironment.apsEnvironment(inProfile: "<plist></plist>"))
    }

    func testHeraldPushPayload() {
        XCTAssertNil(HeraldPushPayload(userInfo: ["aps": ["alert": "hi"]]))
        let payload = HeraldPushPayload(userInfo: ["nexus_decision_id": "dec_9", "deeplink": "lumen://x"])
        XCTAssertEqual(payload?.decisionId, "dec_9")
        XCTAssertEqual(payload?.deeplink, URL(string: "lumen://x"))
    }

    func testAttributeValidation() {
        let valid = HeraldCore.validAttributes([
            "ok": "x", "n": 1, "list": ["a", "b"], "nested": ["a": 1], "mixed": ["a", 1],
            "$custom": "x", "$email": "not-an-email", "$phone": "+15551234567", "": "empty",
        ])
        XCTAssertEqual(Set(valid.keys), ["ok", "n", "list", "$phone"])
    }

    func testValueEncodingKeepsIntegers() throws {
        let data = try JSONEncoder().encode(["a": HeraldValue.number(32), "b": .number(59.99), "c": .bool(true)])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"a\":32"))
        XCTAssertTrue(text.contains("59.99"))
        XCTAssertEqual(try JSONDecoder().decode(HeraldValue.self, from: Data("[1,true]".utf8)), [1, true])
    }
}
