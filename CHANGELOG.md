# Changelog

Releases follow the policy on [Versioning and support](https://heraldsdk.com/docs/operations/versioning-and-support). iOS and Android share version numbers.

## 0.6.0

### Added

- `trackExternalPush(messageId:category:source:)` reports a push your app sent itself (`$external_push`), so Herald's push limit across all sources counts it. `ExternalPushCategory` is `.transactional`, `.marketing` or `.other` (the default). Never include the push's title or body.
- `HeraldConfiguration.trackExternalPushes` (default `true`): a tapped push that isn't from Herald, forwarded to `handleNotificationResponse`, is recorded as `$external_push`. Silent pushes and local notifications never are. The id is the payload key `herald_external_id` when present, else the notification's request id; the category is `herald_category` (`transactional`, `marketing` or `other`), else `other`. Pushes shown in the foreground without a tap, and the Notification Service Extension, record nothing.
- `Herald.shared.heraldId: String?`: the identified person's User ID (`XXXX-XXXX`), which support can search on People. Read from the batch response (`data.heraldId`) and cached; nil until the first accepted batch after `identify`, and cleared by `reset()` or identifying another user. Show it as a "Support ID".
- Lifecycle events, on by default (`trackLifecycleEvents`): `$app_installed` (first launch of the install), `$app_updated` (a new version or build, with `previous_version` and `previous_build`), `$app_opened` (cold start, at its first foreground, with `from_push`), `$app_foreground` and `$app_background` (only on a real move between foreground and background, not after an alert or Control Center). They are `track` events with reserved names, sent in minimal data collection too. State from an earlier SDK only stores the version on its first 0.6.0 launch.
- `$deep_link_opened` (`trackDeepLinks`, on by default) when a URL goes through `openDeepLink` or a push tap: `scheme`, `host`, `path` and `source` (`push` or `link`). No fragment or `;parameters`, and no query unless `trackDeepLinkQuery` is on. A URL without a host (`mailto:`, `tel:`) sends its scheme only. Minimal data collection sends scheme and host only.
- `foregroundSessionTimeout` and `backgroundSessionTimeout` (both 30 minutes): a session ends after the foreground timeout of inactivity, or after the background timeout once the app is in the background. A cold start within the foreground timeout of the last activity continues the session.
- A cold start after the app was last in the background decides continuation with the background timeout.
- `session_start` carries `properties.session_index` (sessions on this install, from 1) and `properties.previous_session_id` (null for the first).
- `maxQueuedEventAge` (30 days): older queued events are dropped before a batch is built, logged at debug level and counted in `dropped` (Herald would reject them as `too_old`).
- Remote config: the SDK fetches the app's SDK settings from Herald (`GET /api/v1/sdk/config`) at launch and on a foreground at most once an hour, caches them and applies the cached ones at launch. Set in the console under Settings, SDK settings: collect events (the kill switch), send interval, foreground and background session timeouts, data collection, lifecycle events and deep links. A setting left at "Use app's value" keeps your `HeraldConfiguration`. A network or parse error keeps what is applied, and startup never waits for the fetch. With collection off, the SDK records and sends nothing (crash reports included) and clears its queue, but keeps fetching config so it can be turned back on; push tokens and subscription changes wait and go out when it is. The cache is tied to the app key. `Herald.shared.remoteConfigVersion` shows the version in use.
- `setConsent(basis:documentId:documentVersion:)` and `clearConsent()`: records the GDPR lawful basis (`ConsentBasis`) and your policy's id and version (each at most 100 characters), persisted and sent in each batch's `context.consent` until cleared. For your compliance records only: it doesn't change what the SDK collects.
- `track(_:properties:schemaVersion:)`: an optional event schema version (such as `"1-0-0"`) sent as the event's `schemaVersion`, so Herald checks it against that version of the event's schema instead of the latest. Existing calls are unchanged.

### Deprecated

- `sessionTimeout`: setting it sets both new timeouts.

### Changed

- Events over 32 KB of JSON are dropped before they are queued, logged at debug level and counted in `dropped` (Herald would reject them).
- Partial rejects: when Herald accepts a batch but lists events it couldn't accept in `rejected`, the batch leaves the queue as before, each rejected event is logged at debug level with its reason, and none is retried. `flush(timeout:)` returns `false` when an event it waited for was rejected. A 400 from an older server still drops the batch.

### Changed in Herald (server, every SDK version)

- Per-event validation: each event in a batch is checked on its own. An invalid event (unknown type, missing or invalid field, over 32 KB, or more than 30 days old) is rejected and listed in the response's `rejected`; the rest of the batch is kept. Before, one bad event failed the whole batch with a 400 and the SDK dropped all of it. The console lists rejected events on the connection's page for 30 days.
- Event schemas (optional, set in the console under Settings, Event schemas): a `track` event whose name has a schema is checked against it. In "Reject invalid events" mode a failing event is rejected (`schema_violation`, or `unknown_schema_version` for a `schemaVersion` the schema doesn't have) and logged at debug level like any reject; in "Accept and warn" mode it is kept. Events without a schema are accepted as before.
- Clock correction: event times are corrected for the device's clock using the batch's `sentAt` and the time it arrived, so a phone with a wrong clock no longer puts activity, send times or goal credit in the wrong window. The device's own timestamp is kept.
- Lifecycle event and `session_start` properties are checked for their types (`invalid_field`). `$app_opened` and `$app_foreground` count as app activity; `$app_installed`, `$app_updated` and `$app_background` don't.
- "Store location from IP address" (console, per app, on by default): when off, Herald records no country from the request's IP address. The region your app sends from the device locale is still kept.
- The consent record is kept on the device and, for a verified user, as the reserved attribute `$consent`, shown to admins on the person's page. Apps can't set `$consent` with `setAttributes`. An invalid one is left out (the batch is kept) and listed with the rejected events as `invalid_consent`.

## 0.5.0

### Added

- Build kind in device context: `context.app.distribution` is `development` (simulator, Xcode or development-signed), `testflight` or `appstore`. It is detected once in the background (StoreKit `AppTransaction`), left out of batches until known, and sent in minimal mode too because it doesn't identify anyone. The Herald console shows it next to each test phone.
- `flush(timeout:) async -> Bool`: sends queued events and waits, returning `true` once every event recorded before the call was accepted by Herald, `false` on timeout, offline, a server retry delay, while disabled, or when Herald refused an event. Events recorded after the call don't hold it up, and other SDK calls keep running while it waits. Use it before `setEnabled(false)` to make sure a last change (such as `setAttributes(["email": .null])` at sign-out) was delivered; events still queued when the SDK is disabled stay on the device and go out after `setEnabled(true)`. The existing `flush()` is unchanged. `timeout` has no default, so a plain `flush()` in async code still calls the non-waiting one.

### Changed in Herald (server, every SDK version)

- Attributes set to `null` (from the SDK or `POST /api/v1/users`) now remove the key from the user's profile instead of storing a null. A segment condition that checks an attribute exists no longer matches a user who sent `null` for it (it used to). Apps can clear `email` at sign-out this way. The stored event log no longer keeps `email` or `$email` values from identify traits or attribute events; the profile and contacts still get them.

## 0.4.0

### Added

- Crash and hang reports on iPhone, off by default: set `crashReports = true` on `HeraldConfiguration`. The SDK then sends Apple MetricKit crash and hang diagnostics to Herald (`POST /api/v1/sdk/diagnostics`), with no user or device id.
- Reports that fail to send wait in a small file (newest 50) and go out on the next launch. Nothing is sent while the SDK is disabled, and `wipeData()` deletes waiting reports.
- The privacy manifest declares crash data: not linked to the user, not used for tracking, for app functionality.

## 0.3.0

### Added

- Live Activities (iPhone, iOS 18+). New library product `HeraldLiveActivity`, with no dependency on HeraldSDK so a widget extension can link it. It holds `HeraldActivityAttributes` and `HeraldLiveActivityWidget`, a lock screen and Dynamic Island view that shows a title, body and either a progress bar or a countdown, and opens the campaign's deep link on tap. Add `HeraldLiveActivityWidget()` to your `WidgetBundle` and set `NSSupportsLiveActivities` to YES.
- On iOS 18+, HeraldSDK sends the Live Activity push-to-start token to Herald (`push_token` with platform `apns_live_activity`), so campaigns can start a Live Activity. Like the APNs token, it is not sent while the SDK is disabled, and is sent again on `setEnabled(true)` and when the user changes.

## 0.2.3

### Fixed

- Push comes back after `wipeData()` then `setEnabled(true)` while notification permission is still granted: the SDK calls `registerForRemoteNotifications()` so iOS hands the token back through your `didRegisterForRemoteNotificationsWithDeviceToken` forwarding, then sends the push token and a push `subscribed`. Each launch while enabled, authorized and without a stored token also registers (without changing the subscription).
- Content card impressions are logged once per card per session, not each time a feed is built (relaunch, filter change). Reset when a session starts or the user changes.
- An expired content card leaves the card list (and an open `ContentCardFeed`) at its expiry time, without waiting for a sync, and on return to the foreground if the app was suspended past it.
- HeraldUI: slideups dismiss only by swiping toward their edge (up for a top slideup, down for a bottom one), as on Android; a sideways swipe no longer dismisses. The VoiceOver **Dismiss** action and escape gesture still work.
- Once the server has refused an identified message sync without a user token, later identified syncs wait for `setUserToken` instead of collecting a 401. The expected 401 before the first `setUserToken` is logged at debug level, not as a warning.

## 0.2.2

### Added

- `Herald.shared.isEnabled`: whether the SDK is on. Reflects `setEnabled` / `wipeData` at once; safe from any thread.

### Fixed

- Events recorded between `identify` and `setUserToken` are no longer lost. A 401 on a signed-in user's batch keeps it on the device, logs `Herald needs a user token: call setUserToken` once and holds that user's events until `setUserToken` is called, which sends them. Anonymous events keep flowing; the 1,000-event queue cap still applies.
- A 401 whose body is `Invalid app key` no longer drops events: the SDK keeps them, logs `Herald rejected the app key: check the publishable key in configure` and sends nothing more until the next launch.
- A corrupt or unreadable `state.json` no longer re-enables an opted-out SDK: the opt-out now lives in its own marker file (as on Android). An existing opt-out is migrated on first launch.
- `setEnabled(false)` and `wipeData()` first send one best-effort `subscription` push `unsubscribed` event for the device (only when it has a push token), so Herald stops sending it pushes. Cached content cards are hidden while disabled and come back on `setEnabled(true)`, which also re-sends the stored push token and a push `subscribed` event when notification permission is still granted, so pushes resume.
- HeraldUI: an in-app message that sets `backgroundColor` without `textColor` (or `buttonColor` without `buttonTextColor`) gets black or white text by WCAG contrast instead of the theme's text color, so it stays readable in dark mode.
- `handleRemoteNotification` returns within 25 seconds even if the refresh has not finished, and at once (still `true` for a Herald sync push) before `configure` has run.

## 0.2.1

No functional change; version kept in step with Android.

## 0.2.0

### Added

- Sync push handling. Herald sends a silent push (`herald_sync` = "1") after it writes new content cards or in-app messages for a user; the SDK refreshes them in the background with the usual ETag check. A sync push never shows a notification and is never logged as a push open, and one that arrives within 30 seconds of the last one is skipped.
  - iOS: `Herald.shared.handleRemoteNotification(_:)`, called from `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`; it returns true for a Herald sync push (complete with `.newData`) and false otherwise. Needs the Remote notifications background mode.
  - Android: herald-fcm's `HeraldMessagingService` handles sync pushes on its own. Apps with their own `FirebaseMessagingService` call `Herald.handleRemoteMessage(data)` from `onMessageReceived`.

### Fixed

- iOS: `HeraldNotificationService` adds the push's `herald_actions` buttons when `aps.category` is a Herald category (an id starting with `herald.`), not only when `aps.category` is absent. A category the app registered itself is still kept.
- Push payloads that carry `herald_sync` are never treated as a push to open (iOS `handleNotificationResponse`, Android `handleNotificationIntent`).

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
