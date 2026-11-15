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
