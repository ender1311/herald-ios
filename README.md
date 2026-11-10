# Herald iOS SDK

The Herald iOS SDK connects an iOS app to Herald. It identifies users, records events and attributes, registers the device for push through APNs, and shows content cards and in-app messages. `HeraldSDK` holds the core calls, `HeraldUI` adds the default SwiftUI views, and `HeraldNotificationService` adds images and action buttons to push notifications from a Notification Service Extension.

## Requirements

- iOS 16 or later (macOS 13 for `HeraldSDK` only)
- Xcode 16 or later (Swift tools version 6.0); your app can use Swift 5 or 6

## Install

In Xcode, choose **File > Add Package Dependencies**, enter `https://github.com/ender1311/herald-ios` and add `HeraldSDK` and `HeraldUI` to your app target. In a `Package.swift` manifest:

```swift
dependencies: [
    .package(url: "https://github.com/ender1311/herald-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "HeraldSDK", package: "herald-ios"),
        .product(name: "HeraldUI", package: "herald-ios"),
    ]),
]
```

## Quickstart

```swift
import HeraldSDK
import HeraldUI

// At launch, in application(_:didFinishLaunchingWithOptions:)
Herald.configure(appKey: "YOUR_APP_KEY", endpoint: URL(string: "https://YOUR_HERALD_HOST")!)
Herald.useDefaultInAppUI()

// After sign-in
Herald.shared.identify(userId: "user-123", traits: ["plan": "free"])
Herald.shared.setUserToken(userTokenFromYourBackend)
Herald.shared.track("workout_completed", properties: ["minutes": 32])

// In a SwiftUI view: ContentCardFeed()
```

The full guide, including push setup, is at https://beaconfrontier.com/herald/docs.

## License

Apache License 2.0. See [LICENSE](LICENSE).
