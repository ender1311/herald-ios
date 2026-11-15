import os
import XCTest
@testable import HeraldSDK

final class CrashReportsTests: XCTestCase {
    private func report(_ n: Int, kind: String = "crash") -> DiagnosticReport {
        DiagnosticReport(
            kind: kind, payload: ["diagnosticMetaData": ["signal": "SIGSEGV"], "n": .number(Double(n))],
            build: "813", osVersion: "iPhone OS 18.1 (22B83)", deviceModel: "iPhone17,1"
        )
    }

    private func items(_ request: URLRequest) throws -> [[String: HeraldValue]] {
        let body = try JSONDecoder().decode(HeraldValue.self, from: XCTUnwrap(request.httpBody))
        return try XCTUnwrap(body.objectValue?["items"]?.arrayValue).compactMap(\.objectValue)
    }

    func testTwoReportsGoOutAsOneRequestWithTwoItems() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics([report(1), report(2, kind: "hang")])
        await core.drain()

        let requests = harness.transport.diagnosticsRequests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://herald.example.com/api/v1/sdk/diagnostics")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-herald-app-key"), "pk_test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-herald-user-token"))
        let body = try JSONDecoder().decode(HeraldValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.objectValue.map { Set($0.keys) }, ["items"], "no user or device id in the body")
        let sent = try items(request)
        XCTAssertEqual(sent.map { $0["kind"] }, ["crash", "hang"])
        XCTAssertEqual(Set(sent[0].keys), ["kind", "appVersion", "build", "osVersion", "deviceModel", "appBinaryName", "payload"])
        XCTAssertEqual(sent[0]["appVersion"], "4.2.0")
        XCTAssertEqual(sent[0]["build"], "813", "the diagnostic's own metadata wins over the current bundle")
        XCTAssertEqual(sent[0]["osVersion"], "iPhone OS 18.1 (22B83)")
        XCTAssertEqual(sent[0]["deviceModel"], "iPhone17,1")
        XCTAssertEqual(sent[0]["payload"]?.objectValue?["n"], 1)
        XCTAssertFalse((sent[0]["appBinaryName"]?.stringValue ?? "").isEmpty)
    }

    func testMissingMetadataFallsBackToTheDevice() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics([DiagnosticReport(kind: "hang", payload: [:], build: nil, osVersion: nil, deviceModel: nil)])
        await core.drain()
        let sent = try items(XCTUnwrap(harness.transport.diagnosticsRequests.first))
        XCTAssertEqual(sent[0]["build"], "812")
        XCTAssertEqual(sent[0]["osVersion"], "18.1")
        XCTAssertEqual(sent[0]["deviceModel"], "iPhone16,1")
    }

    func testTwentyFiveReportsGoOutAsTwoRequests() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics((1...25).map { report($0) })
        await core.drain()
        let counts = try harness.transport.diagnosticsRequests.map { try items($0).count }
        XCTAssertEqual(counts, [20, 5])
    }

    func testAFailedSendIsKeptAndSentOnTheNextStart() async throws {
        let harness = CoreHarness()
        harness.transport.enqueueDiagnosticsError(URLError(.notConnectedToInternet))
        let core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics([report(1), report(2)])
        await core.drain()
        XCTAssertEqual(harness.transport.diagnosticsRequests.count, 1)

        let relaunched = harness.makeCore { $0.crashReports = true }
        await relaunched.start()
        await relaunched.drain()
        let requests = harness.transport.diagnosticsRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try items(requests[1]).map { $0["payload"]?.objectValue?["n"] }, [1, 2])

        let third = harness.makeCore { $0.crashReports = true }
        await third.start()
        await third.drain()
        XCTAssertEqual(harness.transport.diagnosticsRequests.count, 2, "sent items are not sent again")
    }

    func testPendingIsCappedAtFiftyOldestDropped() async throws {
        let harness = CoreHarness()
        for _ in 0..<2 { harness.transport.enqueueDiagnosticsError(URLError(.timedOut)) }
        let core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics((1...30).map { report($0) })
        await core.drain()
        await core.recordDiagnostics((31...60).map { report($0) })
        await core.drain()

        let relaunched = harness.makeCore { $0.crashReports = true }
        await relaunched.start()
        await relaunched.drain()
        let sent = try harness.transport.diagnosticsRequests.suffix(3).flatMap { try items($0) }
        XCTAssertEqual(sent.compactMap { $0["payload"]?.objectValue?["n"]?.numberValue }, (11...60).map(Double.init))
    }

    func testNothingIsSentOrKeptWhileDisabled() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore { $0.crashReports = true }
        await core.setEnabled(false)
        await core.recordDiagnostics([report(1)])
        await core.drain()
        await core.setEnabled(true)
        let relaunched = harness.makeCore { $0.crashReports = true }
        await relaunched.start()
        await relaunched.drain()
        XCTAssertTrue(harness.transport.diagnosticsRequests.isEmpty)
    }

    func testWipeDataDeletesPendingReports() async throws {
        let harness = CoreHarness()
        harness.transport.enqueueDiagnosticsError(URLError(.timedOut))
        let core = harness.makeCore { $0.crashReports = true }
        await core.recordDiagnostics([report(1)])
        await core.drain()
        await core.wipeData()
        await core.setEnabled(true)
        let relaunched = harness.makeCore { $0.crashReports = true }
        await relaunched.start()
        await relaunched.drain()
        XCTAssertEqual(harness.transport.diagnosticsRequests.count, 1)
    }

    func testCrashReportsOffIgnoresReports() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.recordDiagnostics([report(1)])
        await core.drain()
        XCTAssertTrue(harness.transport.diagnosticsRequests.isEmpty)
    }

    func testSubscribesOnlyWhenCrashReportsIsOn() {
        for on in [false, true] {
            let subscribed = OSAllocatedUnfairLock(initialState: 0)
            var configuration = HeraldConfiguration(appKey: "pk_test", endpoint: URL(string: "https://h.example.com")!)
            XCTAssertFalse(configuration.crashReports, "off by default")
            configuration.crashReports = on
            let directory = tempDirectory()
            Herald().start(
                configuration, storage: { Storage(directory: directory) }, transport: FakeTransport(),
                deviceInfo: FixtureDeviceInfo(), subscribeToDiagnostics: { _ in subscribed.withLock { $0 += 1 } }
            )
            XCTAssertEqual(subscribed.withLock { $0 }, on ? 1 : 0)
        }
    }
}

/// Answers like `FixtureDeviceInfo` once `release()` is called; `entered` tells when a caller is waiting.
final class GatedDeviceInfo: DeviceInfoProvider {
    private let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
    var entered: Bool { state.withLock { $0.entered } }
    func release() { state.withLock { $0.released = true } }

    func current() async -> DeviceInfo {
        state.withLock { $0.entered = true }
        while !state.withLock({ $0.released }) { try? await Task.sleep(nanoseconds: 1_000_000) }
        return await FixtureDeviceInfo().current()
    }
}

final class CrashReportsConsentAndStatusTests: XCTestCase {
    private let report = DiagnosticReport(kind: "crash", payload: ["n": 1], build: nil, osVersion: nil, deviceModel: nil)
    private let config: (inout HeraldConfiguration) -> Void = { $0.crashReports = true }

    private func relaunchRequests(_ harness: CoreHarness) async -> Int {
        let core = harness.makeCore(config)
        await core.start()
        await core.drain()
        return harness.transport.diagnosticsRequests.count
    }

    func testKeptReportsAreNotSentAfterSetEnabledFalse() async {
        let harness = CoreHarness()
        harness.transport.enqueueDiagnosticsError(URLError(.timedOut))
        let core = harness.makeCore(config)
        await core.recordDiagnostics([report])
        await core.drain()
        await core.setEnabled(false)
        let relaunched = await relaunchRequests(harness)
        XCTAssertEqual(relaunched, 1, "no request while disabled")
    }

    func testWipeDuringTheDeviceInfoAwaitStoresNothing() async throws {
        let harness = CoreHarness()
        let gate = GatedDeviceInfo()
        let core = harness.makeCore(deviceInfo: gate, config)
        await core.recordDiagnostics([report])
        for _ in 0..<1_000 where !gate.entered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(gate.entered)
        await core.wipeData()
        gate.release()
        await core.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: Storage(directory: harness.directory).diagnosticsURL.path))
        await core.setEnabled(true)
        let relaunched = await relaunchRequests(harness)
        XCTAssertEqual(relaunched, 0)
    }

    func testSendStopsAndKeepsItemsWhenConsentTurnsOffMidLoop() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport()
        let configuration = HeraldConfiguration(appKey: "pk_test", endpoint: URL(string: "https://h.example.com")!)
        let reports = CrashReports(configuration: configuration, fileURL: directory.appendingPathComponent("d.json"), transport: transport)
        reports.add((1...25).map { HeraldValue.object(["n": .number(Double($0))]) })
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await reports.send { calls.withLock { $0 += 1; return $0 == 1 } }
        XCTAssertEqual(transport.diagnosticsRequests.count, 1, "the second chunk waits")
        await reports.send { true }
        XCTAssertEqual(transport.diagnosticsRequests.count, 2)
        let last = try JSONDecoder().decode(HeraldValue.self, from: XCTUnwrap(transport.diagnosticsRequests[1].httpBody))
        XCTAssertEqual(last.objectValue?["items"]?.arrayValue?.count, 5)
    }

    private func statusKeeps(_ status: Int) async -> Bool {
        let harness = CoreHarness()
        harness.transport.enqueueDiagnostics(FakeResponse(status: status))
        let core = harness.makeCore(config)
        await core.recordDiagnostics([report])
        await core.drain()
        return await relaunchRequests(harness) == 2
    }

    func testStatusHandling() async {
        for status in [400, 413] {
            let kept = await statusKeeps(status)
            XCTAssertFalse(kept, "\(status) drops the chunk")
        }
        for status in [500, 401] {
            let kept = await statusKeeps(status)
            XCTAssertTrue(kept, "\(status) keeps the chunk")
        }
    }

    func testAnItemOver256KBIsDroppedWhileTheOthersSend() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore(config)
        let huge = DiagnosticReport(
            kind: "crash", payload: ["blob": .string(String(repeating: "x", count: 300 * 1024))], build: nil, osVersion: nil,
            deviceModel: nil
        )
        await core.recordDiagnostics([huge, report, report])
        await core.drain()
        let requests = harness.transport.diagnosticsRequests
        XCTAssertEqual(requests.count, 1)
        let body = try JSONDecoder().decode(HeraldValue.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body.objectValue?["items"]?.arrayValue?.count, 2)
        let relaunched = await relaunchRequests(harness)
        XCTAssertEqual(relaunched, 1, "nothing left behind")
    }
}
