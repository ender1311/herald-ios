import Foundation
import os
#if os(iOS)
import MetricKit
#endif

/// One MetricKit crash or hang, already extracted. Metadata fields are nil when the diagnostic lacks them.
struct DiagnosticReport: Sendable, Equatable {
    var kind: String
    var payload: [String: HeraldValue]
    var build: String?
    var osVersion: String?
    var deviceModel: String?

    /// The `POST /api/v1/sdk/diagnostics` item: no user or device id. Missing metadata comes from the current device.
    func item(device: DeviceInfo, appBinaryName: String?) -> HeraldValue {
        // The server takes 1–100 characters per field.
        func text(_ value: String?) -> HeraldValue {
            let clipped = String((value ?? "").prefix(100))
            return .string(clipped.isEmpty ? "unknown" : clipped)
        }
        return [
            "kind": .string(kind),
            "appVersion": text(device.appVersion),
            "build": text(build ?? device.appBuild),
            "osVersion": text(osVersion ?? device.osVersion),
            "deviceModel": text(deviceModel ?? device.model),
            "appBinaryName": text(appBinaryName),
            "payload": .object(payload),
        ]
    }
}

/// Keeps crash and hang reports in a small file and sends them in chunks; a failed send waits for the next
/// report or launch.
actor CrashReports {
    static let maxItems = 20
    static let maxBytes = 256 * 1024
    static let maxPending = 50

    private struct Pending: Codable {
        var id: String
        var item: HeraldValue
    }

    private let fileURL: URL
    private let transport: HeraldTransport
    private let request: URLRequest
    private var isSending = false

    init(configuration: HeraldConfiguration, fileURL: URL, transport: HeraldTransport) {
        self.fileURL = fileURL
        self.transport = transport
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("api/v1/sdk/diagnostics"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.appKey, forHTTPHeaderField: "x-herald-app-key")
        self.request = request
    }

    /// Keeps at most the newest 50.
    func add(_ items: [HeraldValue]) {
        let pending = load() + items.map { Pending(id: UUID().uuidString, item: $0) }
        save(Array(pending.suffix(Self.maxPending)))
    }

    /// Sends pending items oldest first, up to 20 (and 256 KB) per request, until one fails.
    func send() async {
        guard !isSending else { return }  // the running loop re-reads the file, so it picks up new items
        isSending = true
        defer { isSending = false }
        while true {
            var chunk = Array(load().prefix(Self.maxItems))
            guard !chunk.isEmpty else { return }
            var body = encode(chunk)
            while body.count > Self.maxBytes, chunk.count > 1 {
                chunk = Array(chunk.prefix(chunk.count / 2))
                body = encode(chunk)
            }
            let ids = Set(chunk.map(\.id))
            if body.count > Self.maxBytes {
                Log.warning("Dropped a crash report larger than 256 KB")
                remove(ids)
                continue
            }
            var request = request
            request.httpBody = body
            guard let (_, response) = try? await transport.send(request) else { return }
            switch response.statusCode {
            case 200..<300:
                remove(ids)
            case 401, 408, 429, 500...599:
                return
            default:
                Log.warning("Herald refused crash reports (HTTP \(response.statusCode)); dropping them")
                remove(ids)
            }
        }
    }

    private func encode(_ chunk: [Pending]) -> Data {
        let body: HeraldValue = ["items": .array(chunk.map(\.item))]
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    private func load() -> [Pending] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private func save(_ pending: [Pending]) {
        do {
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Could not save crash reports: \(error.localizedDescription)")
        }
    }

    private func remove(_ ids: Set<String>) {
        save(load().filter { !ids.contains($0.id) })
    }

    /// Subscribes to MetricKit diagnostics (iOS only; a no-op elsewhere).
    static func subscribeToMetricKit(_ herald: Herald) {
        #if os(iOS)
        MetricKitSubscriber.install(herald)
        #endif
    }
}

#if os(iOS)
private final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private static let installed = OSAllocatedUnfairLock<MetricKitSubscriber?>(initialState: nil)
    private let herald: Herald

    private init(herald: Herald) { self.herald = herald }

    static func install(_ herald: Herald) {
        let subscriber = MetricKitSubscriber(herald: herald)
        // MXMetricManager does not keep its subscribers alive.
        installed.withLock { $0 = subscriber }
        MXMetricManager.shared.add(subscriber)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).compactMap { Self.report("crash", $0) }
                + (payload.hangDiagnostics ?? []).compactMap { Self.report("hang", $0) }
        }
        guard !reports.isEmpty else { return }
        herald.send { core in core.recordDiagnostics(reports) }
    }

    private static func report(_ kind: String, _ diagnostic: MXDiagnostic) -> DiagnosticReport? {
        guard let payload = (try? JSONDecoder().decode(HeraldValue.self, from: diagnostic.jsonRepresentation()))?.objectValue
        else { return nil }
        let meta = diagnostic.metaData
        return DiagnosticReport(
            kind: kind, payload: payload, build: meta.applicationBuildVersion, osVersion: meta.osVersion,
            deviceModel: meta.deviceType
        )
    }
}
#endif
