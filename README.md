# Herald iOS SDK

The Herald iOS SDK connects an iOS app to Herald. It identifies users, records events and attributes, registers the device for push through APNs, and shows content cards and in-app messages. `HeraldSDK` holds the core calls, `HeraldUI` adds the default SwiftUI views, and `HeraldNotificationService` adds images, videos and action buttons to push notifications from a Notification Service Extension.

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
// From 0.6.0, pin an event schema version (Settings, Event schemas in the console); nil checks against the latest.
Herald.shared.track("signup", properties: ["plan": "pro"], schemaVersion: "1-0-0")

// In a SwiftUI view: ContentCardFeed()
```

Herald checks each event on its own: an event it can't accept is left out of an otherwise accepted batch, logged at debug level with its reason (`Herald rejected event <id>: <reason> (<detail>)`) and never retried. An event over 32 KB is dropped on the device and counted in `dropped`. The console lists rejected events on the connection's page. Event times are corrected for the device's clock on the server.

From 0.6.0 the SDK sends lifecycle events on its own (`$app_installed`, `$app_updated`, `$app_opened`, `$app_foreground`, `$app_background`; turn off with `trackLifecycleEvents = false`) and `$deep_link_opened` for links that go through `openDeepLink` or a push tap (`trackDeepLinks`; no query unless `trackDeepLinkQuery`). Sessions have separate `foregroundSessionTimeout` and `backgroundSessionTimeout` (30 minutes each; `sessionTimeout` is deprecated and sets both), continue across a cold start within the foreground timeout, and `session_start` carries `session_index` and `previous_session_id`. Queued events older than `maxQueuedEventAge` (30 days) are dropped and counted in `dropped`.

The SDK also fetches remote settings from the console (Settings, SDK settings) at launch and at most hourly on foreground, and applies the cached ones at launch: they override your configuration, and turning off "Collect events" there stops collection and clears the queue until it is turned back on (push tokens and subscription changes wait and go out then). `Herald.shared.remoteConfigVersion` shows the version in use. `setConsent(basis:documentId:documentVersion:)` / `clearConsent()` record the lawful basis your app uses, sent with each batch for your compliance records; it doesn't change what is collected.

The full guide, including push setup, is at https://heraldsdk.com/docs.

## Video

A push with a video carries `video_url` beside its poster in `image_url`. `HeraldNotificationService` attaches the
video when it's https, MP4 or QuickTime and at most 10 MB; otherwise, or when the download fails or is slow, it
attaches the poster, then shows the text. The push is always delivered, within 25 seconds.

In-app messages and content cards with `videoUrl` show the poster with a play button ("Play video" in VoiceOver); a
tap plays the video inline with sound. Cards with `videoAutoplay` play muted and looped in `ContentCardFeed` while at
least half visible, and not at all with Reduce Motion on. `HeraldUI` sends `video_play` and `video_complete`
interactions; a custom display calls `Herald.shared.logVideoPlay(_:)` and `logVideoComplete(_:)`. `credit` holds the
photographer's name and links for apps that show a credit.

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
