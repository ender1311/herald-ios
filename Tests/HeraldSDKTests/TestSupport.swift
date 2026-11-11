import Foundation
import os
import XCTest
@testable import HeraldSDK

let t0 = Date(timeIntervalSince1970: 1_794_232_800)  // 2026-11-09T14:00:00Z

func fixtureData(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureJSON(_ name: String) throws -> HeraldValue {
    try JSONDecoder().decode(HeraldValue.self, from: fixtureData(name))
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("herald-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class TestClock: Sendable {
    private let value: OSAllocatedUnfairLock<Date>
    init(_ date: Date = t0) { value = OSAllocatedUnfairLock(initialState: date) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Ids like the fixtures: 0b8f3c2e-0000-4000-8000-000000000001, …
final class SequentialIds: Sendable {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    func next() -> String {
        let n = counter.withLock { value -> Int in
            value += 1
            return value
        }
        return String(format: "0b8f3c2e-0000-4000-8000-%012d", n)
    }
}

struct FakeResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

final class FakeTransport: HeraldTransport {
    private struct State {
        var requests: [URLRequest] = []
        var batchResponses: [Result<FakeResponse, URLError>] = []
        var messageResponses: [FakeResponse] = []
        var batchDelayNanoseconds: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var batchRequests: [URLRequest] { requests.filter { $0.url?.path.hasSuffix("/sdk/batch") == true } }
    var messageRequests: [URLRequest] { requests.filter { $0.url?.path.hasSuffix("/sdk/messages") == true } }

    func setBatchDelay(milliseconds: UInt64) { state.withLock { $0.batchDelayNanoseconds = milliseconds * 1_000_000 } }
    func enqueueBatch(_ response: FakeResponse) { state.withLock { $0.batchResponses.append(.success(response)) } }
    func enqueueBatchError(_ error: URLError) { state.withLock { $0.batchResponses.append(.failure(error)) } }
    func enqueueMessages(_ response: FakeResponse) { state.withLock { $0.messageResponses.append(response) } }

    func batchBodies() throws -> [HeraldValue] {
        try batchRequests.map { try JSONDecoder().decode(HeraldValue.self, from: XCTUnwrap($0.httpBody)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isBatch = request.url?.path.hasSuffix("/sdk/batch") == true
        let result: Result<FakeResponse, URLError> = state.withLock { s in
            s.requests.append(request)
            if isBatch {
                return s.batchResponses.isEmpty
                    ? .success(FakeResponse(status: 200, body: Data(#"{"data":{"accepted":1,"duplicates":0}}"#.utf8)))
                    : s.batchResponses.removeFirst()
            }
            return .success(
                s.messageResponses.isEmpty
                    ? FakeResponse(status: 200, body: Data(#"{"data":{"syncedAt":null,"contentCards":[],"inAppMessages":[]}}"#.utf8))
                    : s.messageResponses.removeFirst()
            )
        }
        let delay = state.withLock { $0.batchDelayNanoseconds }
        if isBatch, delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        let response = try result.get()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!
        return (response.body, http)
    }
}

/// Device facts matching `batch-full.json`.
struct FixtureDeviceInfo: DeviceInfoProvider {
    func current() async -> DeviceInfo {
        DeviceInfo(
            appName: "Lumen", appVersion: "4.2.0", appBuild: "812", appNamespace: "com.lumen.app",
            osName: "iOS", osVersion: "18.1", region: "US",
            manufacturer: "Apple", model: "iPhone16,1", deviceType: "phone",
            screenWidth: 393, screenHeight: 852, screenDensity: 3,
            locale: "en-US", language: "en", timezone: "America/Chicago",
            networkType: "wifi", pushAuthorization: "authorized"
        )
    }
}

/// `FixtureDeviceInfo` with notifications denied.
struct DeniedPushDeviceInfo: DeviceInfoProvider {
    func current() async -> DeviceInfo {
        var info = await FixtureDeviceInfo().current()
        info.pushAuthorization = "denied"
        return info
    }
}

/// Records card updates; answers in-app offers with a fixed choice (nil = no presenter).
final class RecordingOutput: CoreOutput {
    private struct State {
        var cards: [[ContentCard]] = []
        var offered: [InAppMessage] = []
        var onClose: [@MainActor @Sendable () -> Void] = []
        var choice: InAppMessageDisplayChoice? = .display
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var lastCards: [ContentCard]? { state.withLock { $0.cards.last } }
    var offered: [InAppMessage] { state.withLock { $0.offered } }
    func setChoice(_ choice: InAppMessageDisplayChoice?) { state.withLock { $0.choice = choice } }

    @MainActor func closeAll() {
        let closers = state.withLock { s -> [@MainActor @Sendable () -> Void] in
            defer { s.onClose = [] }
            return s.onClose
        }
        closers.forEach { $0() }
    }

    func cardsChanged(_ cards: [ContentCard]) async {
        state.withLock { $0.cards.append(cards) }
    }

    func offer(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) async -> InAppMessageDisplayChoice? {
        state.withLock { s in
            s.offered.append(message)
            if s.choice == .display { s.onClose.append(onClose) }
            return s.choice
        }
    }
}

struct CoreHarness {
    let directory: URL
    let transport = FakeTransport()
    let output = RecordingOutput()
    let clock = TestClock()
    let ids = SequentialIds()

    init(directory: URL = tempDirectory()) {
        self.directory = directory
    }

    func makeCore(
        deviceInfo: DeviceInfoProvider = FixtureDeviceInfo(), _ configure: (inout HeraldConfiguration) -> Void = { _ in }
    ) -> HeraldCore {
        var configuration = HeraldConfiguration(appKey: "pk_test", endpoint: URL(string: "https://herald.example.com")!)
        configuration.flushAt = 100_000  // tests flush explicitly
        configure(&configuration)
        let clock = clock
        let ids = ids
        return HeraldCore(
            configuration: configuration, storage: Storage(directory: directory), transport: transport,
            deviceInfo: deviceInfo, output: output,
            now: { clock.now }, random: { 1 }, makeId: { ids.next() }, bundleId: "com.lumen.app"
        )
    }
}

/// Replaces every leaf with its JSON type name, so two documents compare by shape.
func shape(_ value: HeraldValue) -> HeraldValue {
    switch value {
    case .string: return "string"
    case .number: return "number"
    case .bool: return "bool"
    case .null: return "null"
    case .array(let items): return .array(items.map(shape))
    case .object(let object): return .object(object.mapValues(shape))
    }
}
