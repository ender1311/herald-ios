import Foundation
import Network
import os
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import UserNotifications
#endif

/// A snapshot of device facts. Optional fields are omitted from the context when unknown.
struct DeviceInfo: Sendable, Equatable {
    var appName: String
    var appVersion: String
    var appBuild: String
    var appNamespace: String
    var osName: String
    var osVersion: String
    var region: String?
    // Tier 2
    var manufacturer: String
    var model: String
    var deviceType: String
    var screenWidth: Double?
    var screenHeight: Double?
    var screenDensity: Double?
    var locale: String?
    var language: String?
    var timezone: String?
    var networkType: String?
    var pushAuthorization: String?
}

protocol DeviceInfoProvider: Sendable {
    func current() async -> DeviceInfo
}

enum DeviceContext {
    /// The batch `context` block. Tier-2 keys are absent (not null) in minimal mode.
    static func build(_ info: DeviceInfo, collection: DeviceDataCollection) -> HeraldValue {
        var context: [String: HeraldValue] = [
            "app": [
                "name": .string(info.appName), "version": .string(info.appVersion),
                "build": .string(info.appBuild), "namespace": .string(info.appNamespace),
            ],
            "os": ["name": .string(info.osName), "version": .string(info.osVersion)],
        ]
        if let region = info.region { context["region"] = .string(region) }
        guard collection == .standard else { return .object(context) }

        context["device"] = [
            "manufacturer": .string(info.manufacturer), "model": .string(info.model), "type": .string(info.deviceType),
        ]
        if let width = info.screenWidth, let height = info.screenHeight, let density = info.screenDensity {
            context["screen"] = ["width": .number(width), "height": .number(height), "density": .number(density)]
        }
        if let locale = info.locale { context["locale"] = .string(locale) }
        if let language = info.language { context["language"] = .string(language) }
        if let timezone = info.timezone { context["timezone"] = .string(timezone) }
        if let network = info.networkType { context["network"] = ["type": .string(network)] }
        if let push = info.pushAuthorization { context["push"] = ["authorization": .string(push)] }
        return .object(context)
    }
}

/// Reads device facts from the system. Never reads IDFA, IDFV, carrier or location.
final class SystemDeviceInfoProvider: DeviceInfoProvider {
    private let monitor = NWPathMonitor()
    private let networkType = OSAllocatedUnfairLock<String?>(initialState: nil)

    init() {
        let networkType = self.networkType
        monitor.pathUpdateHandler = { path in
            let type: String
            if path.status != .satisfied {
                type = "none"
            } else if path.usesInterfaceType(.wifi) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                type = "ethernet"
            } else {
                type = "other"
            }
            networkType.withLock { $0 = type }
        }
        monitor.start(queue: DispatchQueue(label: "com.herald.sdk.network"))
    }

    deinit { monitor.cancel() }

    func current() async -> DeviceInfo {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let locale = Locale.current
        var device = DeviceInfo(
            appName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "",
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? "",
            appBuild: (info["CFBundleVersion"] as? String) ?? "",
            appNamespace: bundle.bundleIdentifier ?? "",
            osName: Self.osName,
            osVersion: Self.osVersion,
            region: locale.region?.identifier,
            manufacturer: "Apple",
            model: Self.modelIdentifier,
            deviceType: "desktop",
            locale: locale.identifier(.bcp47),
            language: locale.language.languageCode?.identifier,
            timezone: TimeZone.current.identifier,
            networkType: networkType.withLock { $0 }
        )
        #if canImport(UIKit) && !os(watchOS)
        let ui = await Self.mainActorFacts()
        device.deviceType = ui.type
        device.screenWidth = ui.width
        device.screenHeight = ui.height
        device.screenDensity = ui.density
        #endif
        #if os(iOS)
        device.pushAuthorization = await Self.pushAuthorization()
        #endif
        return device
    }

    static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "Apple"
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    private static func mainActorFacts() -> (type: String, width: Double?, height: Double?, density: Double?) {
        let type: String
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: type = "tablet"
        case .tv: type = "tv"
        case .mac: type = "desktop"
        case .carPlay: type = "car"
        case .vision: type = "headset"
        default: type = "phone"
        }
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        guard let screen else { return (type, nil, nil, nil) }
        return (type, Double(screen.bounds.width), Double(screen.bounds.height), Double(screen.scale))
    }
    #endif

    #if os(iOS)
    static func pushAuthorization() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        default: return "not_determined"
        }
    }
    #endif
}
