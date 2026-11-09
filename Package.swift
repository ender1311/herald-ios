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
    ],
    targets: [
        .target(name: "HeraldSDK", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "HeraldUI", dependencies: ["HeraldSDK"]),
        .target(name: "HeraldNotificationService"),
        .testTarget(
            name: "HeraldSDKTests",
            dependencies: ["HeraldSDK"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HeraldUITests", dependencies: ["HeraldUI"]),
        .testTarget(name: "HeraldNotificationServiceTests", dependencies: ["HeraldNotificationService"]),
    ],
    swiftLanguageModes: [.v6]
)
