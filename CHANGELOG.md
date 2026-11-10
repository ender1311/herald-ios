# Changelog

Releases follow the policy on [Versioning and support](https://beaconfrontier.com/herald/docs/operations/versioning-and-support). iOS and Android share version numbers.

## 0.1.0

The first public release. iOS 16 and later; Android 8.0 (API level 26) and later.

### Distribution

- iOS: Swift Package Manager, from `https://github.com/ender1311/herald-ios`.
- Android: JitPack, as `com.github.ender1311.herald-android:herald-core`, `herald-ui` and `herald-fcm`.
- Source for both under the Apache License 2.0.

### Modules

| iOS | Android | Contents |
|---|---|---|
| `HeraldSDK` | `herald-core` | Identity, events, sessions, push registration, content card data, in-app message rules |
| `HeraldUI` | `herald-ui` | Default content card feed and in-app message views, with theming and dark mode |
| `HeraldNotificationService` | `herald-fcm` | Push images and action buttons (iOS extension); FCM service, token sync, channel and notification display (Android) |

### Data collection

- Users: anonymous and identified users, `identify` with traits, `reset`, user switching, and identity verification with user tokens in three modes (required, optional, off).
- Events: `track`, `screen`, `trackPurchase`, user attributes, email and phone contacts, channel subscriptions, and an app-supplied location.
- Sessions with a configurable inactivity timeout.
- Two device data tiers, with a minimal mode. No advertising identifiers, carrier or automatic location.
- An on-disk queue of up to 1,000 events, batched uploads, retries with backoff, and validation of every call on the device.
- `setEnabled` and `wipeData` for consent and deletion. Calls made before `configure` are kept, up to 1,000.
- A privacy manifest in `HeraldSDK`.

### Push

- APNs and FCM token registration, re-sent after sign-in and sign-out.
- A permission prompt helper on both platforms that records the push subscription.
- Open tracking, deep link routing, and `push_open` in-app triggers.
- Images: a Notification Service Extension class on iOS, big picture style on Android.
- Up to three action buttons from a `herald_actions` payload key, reported as an open, then a button tap.

### Content cards

- Classic, captioned image and image-only cards; pinning, expiry, categories and extras.
- A default feed with impression, click and swipe-to-dismiss logging.
- Data APIs for a custom UI.

### In-app messages

- Slideup, modal, full-screen and HTML messages.
- Triggers on session start, custom events with property filters, and push opens; priority, re-eligibility, expiry and a minimum interval.
- Pending messages that wait until they can show, a delegate to show, hold or drop each one, and `showNext()`.
- Default views and presenter, with themes, per-message colors, custom views and accessibility support.
- Debug-only preview hooks: `debugLoadMessages` and `debugShowInAppMessage`.

### Known limitations

- Herald authors classic and captioned image cards, and slideup and modal messages that trigger at session start, once. Other card and message options work in the SDK and the sync API, and creating them from Herald is planned. See [Rebuilding cards and in-app messages](https://beaconfrontier.com/herald/docs/migration/rebuilding-cards-and-messages).
- Herald's push senders do not yet add action buttons, a per-message Android channel or silent pushes.
- App keys cannot be rotated.
