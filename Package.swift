// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeraldSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HeraldSDK", targets: ["HeraldSDK"]),
    ],
    targets: [
        .target(name: "HeraldSDK"),
        .testTarget(
            name: "HeraldSDKTests",
            dependencies: ["HeraldSDK"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
