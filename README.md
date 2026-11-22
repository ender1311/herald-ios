# Herald iOS SDK

The Herald iOS SDK connects an iOS app to Herald. It identifies users, records events and attributes, registers the device for push through APNs, and shows content cards and in-app messages. `HeraldSDK` holds the core calls, `HeraldUI` adds the default SwiftUI views, and `HeraldNotificationService` adds images and action buttons to push notifications from a Notification Service Extension.

## Requirements

- iOS 16 or later (macOS 13 for `HeraldSDK` only)
- Xcode 16 or later (Swift tools version 6.0); your app can use Swift 5 or 6

## Install

In Xcode, choose **File > Add Package Dependencies**, enter `https://github.com/ender1311/herald-ios` and add `HeraldSDK` and `HeraldUI` to your app target. In a `Package.swift` manifest:

```swift
dependencies: [
    .package(url: "https://github.com/ender1311/herald-ios", from: "0.6.0"),
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

Herald checks each event on its own: an event it can't accept is left out of an otherwise accepted batch, logged at debug level with its reason (`Herald rejected event <id>: <reason> (<detail>)`) and never retried. An event over 32 KB is dropped on the device and counted in `dropped`. The console lists rejected events on the connection's page. Event times are corrected for the device's clock on the server.

The full guide, including push setup, is at https://heraldsdk.com/docs.

## Support ID

`Herald.shared.heraldId` is the identified person's User ID (`XXXX-XXXX`), which support can search on People in
Herald. Show it on a settings or help screen labeled "Support ID". It is nil until the first batch after `identify` is
accepted, and again after `reset()`.

## Pushes your app sends

Herald limits how many pushes a person gets in 24 hours, counting pushes your app sends itself. Report each one from
your backend with the `$external_push` event (`POST /api/v1/events`), or from the app:

```swift
Herald.shared.trackExternalPush(messageId: "order-42-shipped", category: .transactional, source: "orders")
```

With `trackExternalPushes` on (the default), the SDK also records a push that isn't from Herald when it's tapped and
forwarded to `handleNotificationResponse`. Silent pushes and local notifications are never recorded. Put the id your
backend reports in the payload key `herald_external_id` (else the notification's request id is used) and
`transactional`, `marketing` or `other` in `herald_category`, so the backend's report and the SDK's count once.
The SDKs also record some of these pushes on their own: on iOS when someone taps one, and on Android when one
arrives. To count every push, report them from your backend. The Notification Service Extension doesn't record anything. Guide:
https://heraldsdk.com/docs/push-notifications/pushes-your-app-sends

## License

Apache License 2.0. See [LICENSE](LICENSE).
