import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import UserNotifications
#endif

/// The SDK entry point. Call `Herald.configure` once at launch, then use `Herald.shared`.
///
/// Every call is safe from any thread, returns immediately and is applied in call order.
/// Calls made before `configure` are kept (up to 1,000; later ones are dropped with a warning) and
/// applied once it runs. The SDK never throws into
/// the host app: invalid input is logged and skipped.
public final class Herald: Sendable {
    public static let shared = Herald()
    public static let sdkVersion = "0.2.0"
    /// Calls kept before `configure` runs (and while the core is busy); newer calls are dropped beyond it.
    static let maxBufferedCalls = 1_000

    /// The current user's content cards.
    public let contentCards: ContentCardStore

    /// Synchronous on purpose: a command can never wait on the network, so every call is on disk
    /// before the next one runs.
    typealias Command = @Sendable (isolated HeraldCore) -> Void

    private let bridge: MainActorBridge
    private let commands: AsyncStream<Command>.Continuation
    private let stream: AsyncStream<Command>
    private let configured = OSAllocatedUnfairLock(initialState: false)

    init() {
        contentCards = ContentCardStore()
        bridge = MainActorBridge(store: contentCards)
        (stream, commands) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .bufferingOldest(Self.maxBufferedCalls))
    }

    // MARK: - Setup

    public static func configure(_ configuration: HeraldConfiguration) {
        shared.start(configuration)
    }

    /// `Herald.configure(appKey: "pk_…", endpoint: url) { $0.deviceDataCollection = .minimal }`
    public static func configure(
        appKey: String, endpoint: URL, options: (inout HeraldConfiguration) -> Void = { _ in }
    ) {
        var configuration = HeraldConfiguration(appKey: appKey, endpoint: endpoint)
        options(&configuration)
        configure(configuration)
    }

    func start(
        _ configuration: HeraldConfiguration,
        storage: @escaping @Sendable () -> Storage = { Storage(directory: Storage.defaultDirectory()) },
        transport: HeraldTransport = URLSessionTransport(),
        deviceInfo: DeviceInfoProvider = SystemDeviceInfoProvider()
    ) {
        let first = configured.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else {
            Log.warning("Herald.configure was called more than once; ignoring the later call")
            return
        }
        Log.level = configuration.logLevel
        let bridge = bridge
        let stream = stream
        Task.detached(priority: .utility) {
            let core = HeraldCore(
                configuration: configuration, storage: storage(), transport: transport, deviceInfo: deviceInfo,
                output: bridge
            )
            await core.start()
            for await command in stream {
                await command(core)
            }
        }
        #if canImport(UIKit) && !os(watchOS)
        Task { @MainActor in LifecycleObserver.install(self) }
        #else
        send { core in core.appDidBecomeActive() }
        #endif
    }

    /// Returns false when the call was dropped.
    @discardableResult
    func send(_ command: @escaping Command) -> Bool {
        if case .dropped = commands.yield(command) {
            Log.warning("Herald call dropped: more than \(Self.maxBufferedCalls) calls are waiting (is Herald.configure called?)")
            return false
        }
        return true
    }

    // MARK: - Identity

    /// Identifies the user. A different user id than the current one ends the session and clears the
    /// previous user's token, cards and messages. Call `setUserToken` after `identify`.
    public func identify(userId: String, traits: [String: HeraldValue] = [:]) {
        send { core in core.identify(userId: userId, traits: traits) }
    }

    /// Identity verification token for the current user: hex HMAC-SHA256 of the user id, minted by
    /// your server. Pass nil to clear it.
    public func setUserToken(_ token: String?) {
        send { core in core.setUserToken(token) }
    }

    /// Logs the user out: anonymous again on this device, with a new session. Clears the user id,
    /// token, cards, in-app messages and that user's in-app history.
    public func reset() {
        send { core in core.reset() }
    }

    // MARK: - Events and attributes

    public func track(_ event: String, properties: [String: HeraldValue] = [:]) {
        send { core in core.track(event, properties: properties) }
    }

    public func screen(_ name: String, properties: [String: HeraldValue] = [:]) {
        send { core in core.screen(name, properties: properties) }
    }

    /// `currency` is an ISO 4217 code such as "USD".
    public func trackPurchase(
        productId: String, price: Double, currency: String, quantity: Int = 1,
        properties: [String: HeraldValue] = [:]
    ) {
        send { core in
            core.trackPurchase(productId: productId, price: price, currency: currency, quantity: quantity, properties: properties)
        }
    }

    /// Values may be string, number, bool, nil or an array of strings. Keys starting with `$` are reserved.
    public func setAttribute(_ key: String, _ value: HeraldValue) {
        setAttributes([key: value])
    }

    public func setAttributes(_ attributes: [String: HeraldValue]) {
        send { core in core.setAttributes(attributes) }
    }

    /// A string must be a valid email; nil is sent as null.
    public func setEmail(_ email: String?) {
        setAttributes(["$email": email.map(HeraldValue.string) ?? .null])
    }

    /// E.164 format, for example "+15551234567"; nil is sent as null.
    public func setPhone(_ phone: String?) {
        setAttributes(["$phone": phone.map(HeraldValue.string) ?? .null])
    }

    public func setSubscription(_ channel: SubscriptionChannel, _ state: SubscriptionState) {
        send { core in core.setSubscription(channel, state) }
    }

    /// Stores a location the app obtained itself. The SDK never reads location on its own.
    public func setLocation(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            Log.error("setLocation: latitude must be -90...90 and longitude -180...180")
            return
        }
        setAttributes(["$latitude": .number(latitude), "$longitude": .number(longitude)])
    }

    // MARK: - Data control

    /// Sends queued events now (subject to any server-requested retry delay).
    public func flush() {
        send { core in core.scheduleFlush() }
    }

    /// Turns all collection, sending and message display on or off. Persisted across launches.
    public func setEnabled(_ enabled: Bool) {
        send { core in core.setEnabled(enabled) }
    }

    /// Deletes all SDK data on this device and disables the SDK. Call `setEnabled(true)` to start
    /// again with a new device id.
    public func wipeData() {
        send { core in core.wipeData() }
    }

    // MARK: - Push

    /// Asks for notification permission and, when granted, registers with APNs. Records the push
    /// subscription state (sent after the APNs token arrives). Returns false on platforms without push.
    public func requestPushAuthorization() async -> Bool {
        #if os(iOS)
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.error("Push authorization failed: \(error.localizedDescription)")
            granted = false
        }
        if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
        setSubscription(.push, granted ? .optedIn : .unsubscribed)
        return granted
        #else
        return false
        #endif
    }

    /// Forward the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func setPushToken(_ token: Data) {
        let hex = PushToken.hex(token)
        guard !hex.isEmpty else { return }
        send { core in core.setPushToken(hex: hex) }
    }

    #if os(iOS)
    /// Forward from `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Logs the open, button
    /// (a button tap logs the open too) or dismissal, evaluates `push_open` in-app triggers and opens the
    /// push's deep link (a button's own `deeplink` when it has one). Callable from any isolation.
    /// Returns false when the notification did not come from Herald.
    @discardableResult
    public nonisolated func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        handleNotificationResponse(
            userInfo: response.notification.request.content.userInfo, actionIdentifier: response.actionIdentifier
        )
    }

    /// The same as `handleNotificationResponse(_:)`, from the notification's `userInfo` and the
    /// response's `actionIdentifier`.
    @discardableResult
    public nonisolated func handleNotificationResponse(userInfo: [AnyHashable: Any], actionIdentifier: String) -> Bool {
        guard let payload = HeraldPushPayload(userInfo: userInfo) else { return false }
        let action: String
        let buttonId: String?
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            action = "open"
            buttonId = nil
        case UNNotificationDismissActionIdentifier:
            action = "dismiss"
            buttonId = nil
        default:
            action = "button"
            buttonId = actionIdentifier
        }
        let decisionId = payload.decisionId
        let messageId = payload.interactionId
        send { core in core.pushResponse(messageId: messageId, decisionId: decisionId, action: action, buttonId: buttonId) }
        if action != "dismiss", let url = payload.deeplink(forAction: buttonId) {
            Task { @MainActor in self.openDeepLink(url) }
        }
        return true
    }
    #endif

    /// The data key of a Herald sync push (value "1").
    static let syncKey = "herald_sync"

    /// Handles a Herald sync push: a silent push (`content-available: 1`, no alert) Herald sends after it
    /// writes new cards or in-app messages for the user. Refreshes cards and in-app messages (with the
    /// usual ETag check; nothing happens while the SDK is disabled) and returns true when the push was a
    /// Herald sync (`herald_sync` is "1"), false otherwise. A sync push never shows anything and is never
    /// logged as a push open. One that arrives within 30 s of the last refreshed one is skipped.
    /// Main actor, like the app delegate it is called from.
    ///
    /// Wiring: turn on the Remote notifications background mode (`UIBackgroundModes` contains
    /// `remote-notification`), then forward from your app delegate:
    /// ```swift
    /// func application(
    ///     _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    ///     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    /// ) {
    ///     Task {
    ///         let synced = await Herald.shared.handleRemoteNotification(userInfo)
    ///         completionHandler(synced ? .newData : .noData)
    ///     }
    /// }
    /// ```
    /// Without the background mode, iOS does not wake the app and new messages arrive at the next session.
    @MainActor public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard userInfo[Self.syncKey] as? String == "1" else { return false }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let queued = send { core in core.syncFromPush { done.resume() } }
            if !queued { done.resume() }
        }
        return true
    }

    // MARK: - Content cards

    /// Fetches the latest cards and in-app messages now.
    public func refreshContentCards() {
        send { core in core.scheduleSync(thenFire: nil) }
    }

    public func logImpression(_ card: ContentCard) {
        send { core in core.logCardImpression(card) }
    }

    public func logClick(_ card: ContentCard) {
        send { core in core.logCardClick(card) }
    }

    /// Hides the card on this device and tells Herald.
    public func logDismissal(_ card: ContentCard) {
        send { core in core.logCardDismissal(card) }
    }

    // MARK: - In-app messages

    /// Decides whether each triggered message shows now, later or never. Held weakly.
    @MainActor public var inAppMessageDelegate: InAppMessageDelegate? {
        get { bridge.delegate }
        set { bridge.delegate = newValue }
    }

    /// Draws in-app messages. `HeraldUI` sets its default presenter; messages are not shown while nil.
    @MainActor public var inAppMessagePresenter: InAppMessagePresenter? {
        get { bridge.presenter }
        set {
            bridge.presenter = newValue
            if newValue != nil { send { core in core.showPendingIfPossible() } }
        }
    }

    /// Opens Herald deep links (push, card and message clicks). Return true when handled; when nil
    /// or returning false, the SDK opens the URL with the system.
    @MainActor public var deepLinkHandler: ((URL) -> Bool)? {
        get { bridge.deepLinkHandler }
        set { bridge.deepLinkHandler = newValue }
    }

    /// Shows the next pending message now (for example one the delegate deferred with `.later`),
    /// skipping the minimum interval. Does nothing while another message is on screen.
    public func showNext() {
        send { core in core.showNext() }
    }

    /// Only for custom displays: the SDK already logs the impression when it hands a message to the presenter.
    public func logImpression(_ message: InAppMessage) {
        send { core in core.logMessageImpression(message) }
    }

    /// A tap on the message body (`buttonId` nil) or on one of its buttons (non-empty id).
    public func logClick(_ message: InAppMessage, buttonId: String? = nil) {
        send { core in core.logMessageClick(message, buttonId: buttonId) }
    }

    public func logDismissal(_ message: InAppMessage) {
        send { core in core.logMessageDismissal(message) }
    }

    /// Debug and preview only: loads the cards and in-app messages of a `GET /api/v1/sdk/messages`
    /// response body (for example the shared `messages.json` fixture) without a server. Nothing is saved
    /// and the next sync replaces them. An unreadable body is logged and ignored.
    public func debugLoadMessages(_ json: Data) {
        do {
            let payload = try MessagesPayload.decode(json)
            send { core in core.debugApply(payload) }
        } catch {
            Log.warning("debugLoadMessages: unreadable body")
        }
    }

    /// Debug and preview only: shows a loaded (or synced) in-app message now, skipping its trigger,
    /// eligibility and the minimum interval. Does nothing while another message is on screen.
    public func debugShowInAppMessage(_ messageId: String) {
        send { core in core.debugShowInAppMessage(messageId) }
    }

    /// Routes a URL through `deepLinkHandler`, falling back to the system.
    @MainActor public func openDeepLink(_ url: URL) {
        if bridge.deepLinkHandler?(url) == true { return }
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.open(url)
        #endif
    }
}

/// Main-actor side of the core: publishes cards and asks the delegate and presenter.
@MainActor
final class MainActorBridge: CoreOutput {
    weak var delegate: InAppMessageDelegate?
    var presenter: InAppMessagePresenter?
    var deepLinkHandler: ((URL) -> Bool)?
    private let store: ContentCardStore

    nonisolated init(store: ContentCardStore) {
        self.store = store
    }

    func cardsChanged(_ cards: [ContentCard]) {
        store.update(cards)
    }

    func offer(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) -> InAppMessageDisplayChoice? {
        guard let presenter else { return nil }
        let choice = delegate?.shouldDisplay(message) ?? .display
        // A presenter that cannot show now (no active scene) leaves the message pending, like no presenter.
        if choice == .display, !presenter.present(message, onClose: onClose) {
            return nil
        }
        return choice
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Forwards app foreground/background to the core and keeps the app alive for the background flush.
@MainActor
enum LifecycleObserver {
    private static var tokens: [NSObjectProtocol] = []

    static func install(_ herald: Herald) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            herald.send { core in core.appDidBecomeActive() }
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let task = BackgroundTask()
                herald.send { core in
                    let flush = core.appDidEnterBackground()
                    // Hold the background assertion until the upload ends, outside the command stream.
                    Task {
                        await flush.value
                        await task.end()
                    }
                }
            }
        })
        if UIApplication.shared.applicationState == .active {
            herald.send { core in core.appDidBecomeActive() }
        }
    }
}

@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Herald flush") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
