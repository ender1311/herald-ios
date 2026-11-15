// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeraldSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HeraldSDK", targets: ["HeraldSDK"]),
        .library(name: "HeraldUI", targets: ["HeraldUI"]),
        // For a Notification Service Extension. Depends on Foundation and UserNotifications only.
        .library(name: "HeraldNotificationService", targets: ["HeraldNotificationService"]),
        // For a widget extension: the Live Activity attributes and widget. No dependency on HeraldSDK.
        .library(name: "HeraldLiveActivity", targets: ["HeraldLiveActivity"]),
    ],
    targets: [
        .target(name: "HeraldSDK", dependencies: ["HeraldLiveActivity"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "HeraldUI", dependencies: ["HeraldSDK"]),
        .target(name: "HeraldNotificationService"),
        .target(name: "HeraldLiveActivity"),
        .testTarget(
            name: "HeraldSDKTests",
            dependencies: ["HeraldSDK"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HeraldUITests", dependencies: ["HeraldUI"]),
        .testTarget(name: "HeraldNotificationServiceTests", dependencies: ["HeraldNotificationService"]),
        .testTarget(name: "HeraldLiveActivityTests", dependencies: ["HeraldLiveActivity"]),
    ],
    swiftLanguageModes: [.v6]
)
