import Foundation
import os

/// Hooks from the core to the main-actor world (card store, in-app delegate and presenter).
protocol CoreOutput: Sendable {
    func cardsChanged(_ cards: [ContentCard]) async
    /// Asks the delegate and hands the message to the presenter. Returns nil when no presenter is set
    /// or the presenter could not show it.
    func offer(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) async
        -> InAppMessageDisplayChoice?
}

/// All SDK state lives here. Public calls reach it in order through `Herald`'s command stream and are
/// written to disk before the call returns; network work (flush, sync) and main-actor hops run in
/// child tasks, so recording never waits on them.
actor HeraldCore {
    static let sdkName = "herald-ios"
    static let maxBatchEvents = 100
    static let maxBatchBytes = 512 * 1024
    /// Herald rejects a single event over 32 KB of JSON, so a bigger one is dropped here and counted in `dropped`.
    static let maxEventBytes = 32 * 1024
    static let anonymousKey = "anonymous"
    static let maxRecentPushOpens = 50

    /// What the app configured; `configuration` is it with the remote settings laid over.
    private let localConfiguration: HeraldConfiguration
    private(set) var configuration: HeraldConfiguration
    /// The cached or fetched remote settings. `enabled: false` (the kill switch) stops collection and sending.
    private var remote: RemoteConfig?
    /// `Herald.remoteConfigVersion`, readable from any thread.
    nonisolated let remoteVersion: OSAllocatedUnfairLock<String?>
    /// The last config fetch: at launch, then on a foreground at most once an hour.
    private var configFetchedAt: Date?
    static let configFetchInterval: TimeInterval = 3600
    private let storage: Storage
    private let transport: HeraldTransport
    private let deviceInfo: DeviceInfoProvider
    private let output: CoreOutput
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let makeId: @Sendable () -> String
    /// Asks iOS for the APNs token again; it comes back through the app's `setPushToken` forwarding.
    private let registerForPush: @Sendable () async -> Void
    /// Set when `configuration.crashReports` is on.
    private let crashReports: CrashReports?
    /// `state.heraldId`, readable from any thread for `Herald.heraldId`.
    nonisolated let heraldIdMirror: OSAllocatedUnfairLock<String?>

    private(set) var state: PersistedState
    private let queue: EventQueue
    var queuedCount: Int { queue.count }
    private(set) var engine: InAppEngine
    private(set) var cards: [ContentCard] = []
    /// Id of the in-app message on screen (or being offered), so a stale `onClose` cannot free the slot.
    private(set) var showingId: String?

    private var currentFlush: Task<Void, Never>?
    /// While any `confirmFlush` waits: ids of events the server accepted. Success is tracked, not failure, so
    /// any other way an event leaves the queue (eviction, wipe, rejection) counts as not delivered.
    private var confirmations = 0
    private var acceptedIds: Set<String> = []
    private var isSyncing = false
    private var resyncRequested = false
    private(set) var failureCount = 0
    private(set) var nextAttemptAt: Date?
    /// Users whose batch got 401: their events stay queued and unsent until `setUserToken`.
    private(set) var usersAwaitingToken: Set<String> = []
    /// The server refused the app key: nothing is sent (and nothing dropped) until the next launch.
    private(set) var appKeyRejected = false
    private(set) var isForeground = false
    /// No state on disk at launch: the first launch of this install.
    private let isFreshInstall: Bool
    /// `$app_opened` waits for this launch's first foreground; a push tap seen before it sets `from_push`.
    private var appOpenPending = true
    private var openedFromPush = false
    private var flushTimer: Task<Void, Never>?
    private var intervalRetry: Task<Void, Never>?
    private var expiryRefresh: Task<Void, Never>?
    private var activityPersistedAt: Date?
    private let bundleId: String
    /// Child tasks (flush, sync, output), tracked so tests can wait for them.
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// When the last sync push refreshed; a sync push within `syncPushDebounce` of it is skipped.
    private var lastSyncPushAt: Date?
    static let syncPushDebounce: TimeInterval = 30

    init(
        configuration: HeraldConfiguration,
        storage: Storage,
        transport: HeraldTransport = URLSessionTransport(),
        deviceInfo: DeviceInfoProvider,
        output: CoreOutput,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        bundleId: String = Bundle.main.bundleIdentifier ?? "",
        registerForPush: @escaping @Sendable () async -> Void = PushRegistrar.register,
        queueCap: Int = EventQueue.defaultCap,
        heraldIdMirror: OSAllocatedUnfairLock<String?> = OSAllocatedUnfairLock(initialState: nil),
        remoteVersion: OSAllocatedUnfairLock<String?> = OSAllocatedUnfairLock(initialState: nil)
    ) {
        self.heraldIdMirror = heraldIdMirror
        self.bundleId = bundleId
        self.registerForPush = registerForPush
        localConfiguration = configuration
        // The cached remote settings apply before anything is recorded; the launch fetch refreshes them.
        remote = storage.loadRemoteConfig(appKey: configuration.appKey)
        self.configuration = remote?.applied(to: configuration) ?? configuration
        self.remoteVersion = remoteVersion
        remoteVersion.withLock { [remote] in $0 = remote?.version }
        self.storage = storage
        self.transport = transport
        self.deviceInfo = deviceInfo
        self.output = output
        self.now = now
        self.random = random
        self.makeId = makeId
        crashReports = configuration.crashReports
            ? CrashReports(configuration: configuration, fileURL: storage.diagnosticsURL, transport: transport) : nil
        let loaded = storage.loadState()
        isFreshInstall = loaded == nil
        state = loaded ?? PersistedState(deviceId: UUID().uuidString.lowercased())
        if storage.isDisabledMarked { state.enabled = false }
        queue = EventQueue(fileURL: storage.queueURL, cap: queueCap)
        engine = InAppEngine(minimumInterval: configuration.inAppMinimumInterval)
        engine.lastShown = state.lastShown[state.userId ?? Self.anonymousKey] ?? [:]
        engine.lastDisplayAt = state.lastDisplayAt
        if let cached = storage.loadMessages(), let payload = try? MessagesPayload.decode(cached) {
            cards = payload.contentCards
            engine.messages = payload.inAppMessages
        }
        storage.saveState(state)
        heraldIdMirror.withLock { [id = state.heraldId] in $0 = id }
    }

    /// Publishes the cached cards once the store is listening.
    func start() async {
        if configFetchedAt == nil { fetchConfig() }  // one launch fetch, even if a foreground came first
        let visible = visibleCards()
        scheduleExpiryRefresh(visible)
        await output.cardsChanged(visible)
        // A launch only asks for the token; it never changes the push subscription.
        if state.enabled, state.pushToken == nil { restorePushIfAuthorized(resubscribe: false) }
        if state.enabled, remoteCollects, let crashReports {
            spawn { core in await crashReports.send { await core.collectsNow } }
        }
        if state.enabled, configuration.trackLifecycleEvents { await recordAppVersion() }
    }

    /// `$app_installed` on this install's first launch, `$app_updated` when the version or build changed. State
    /// from an SDK before 0.6.0 has no stored version: that launch only stores it.
    private func recordAppVersion() async {
        let info = await deviceInfo.current()
        guard state.enabled else { return }
        let version = Validation.truncated(info.appVersion, 64)
        let build = Validation.truncated(info.appBuild, 64)
        if isFreshInstall {
            recordLifecycle("$app_installed", ["version": .string(version), "build": .string(build)], session: false)
        } else if let previous = state.appVersion, previous != version || state.appBuild != build {
            recordLifecycle("$app_updated", [
                "version": .string(version), "build": .string(build),
                "previous_version": .string(previous), "previous_build": .string(state.appBuild ?? ""),
            ], session: false)
        }
        // Under the kill switch the event was dropped, so the version isn't stored: the update reports once it resumes.
        guard remoteCollects, state.appVersion != version || state.appBuild != build else { return }
        state.appVersion = version
        state.appBuild = build
        persist()
    }

    /// `session` false queues the event without starting or ending a session (going to the background, launch).
    private func recordLifecycle(_ name: String, _ properties: [String: HeraldValue] = [:], session: Bool = true) {
        guard state.enabled, configuration.trackLifecycleEvents else { return }
        let fields: [String: HeraldValue] = ["name": .string(name), "properties": .object(properties)]
        if session { record("track", fields) } else { enqueue("track", fields) }
    }

    /// `$deep_link_opened` for a deep link the SDK routes. No query or fragment unless `trackDeepLinkQuery`; scheme
    /// and host only in minimal data collection. A URL without a host (`mailto:`, `tel:`) sends its scheme only, so an
    /// address or number never reaches the event log.
    func deepLinkOpened(_ url: URL, source: String) {
        guard state.enabled, configuration.trackDeepLinks else { return }
        let t = { (s: String) in HeraldValue.string(Validation.truncated(s, Validation.maxName)) }
        var properties: [String: HeraldValue] = ["scheme": t(url.scheme ?? ""), "source": .string(source)]
        if let host = url.host, !host.isEmpty {
            properties["host"] = t(host)
            if configuration.deviceDataCollection == .standard {
                // `;params` (session ids) are cut, like the query.
                properties["path"] = t(String(url.path.prefix { $0 != ";" }))
                if configuration.trackDeepLinkQuery, let query = url.query { properties["query"] = t(query) }
            }
        }
        record("track", ["name": "$deep_link_opened", "properties": .object(properties)])
    }

    /// MetricKit crash and hang reports: kept and sent only while enabled and `crashReports` is on.
    func recordDiagnostics(_ reports: [DiagnosticReport]) {
        guard state.enabled, remoteCollects, let crashReports else { return }
        spawn { core in
            let device = await core.deviceInfo.current()
            // Consent may have changed during the await; add() is synchronous, so nothing can slip in after this.
            guard core.state.enabled, core.remoteCollects else { return }
            let binary = Bundle.main.executableURL?.lastPathComponent
            crashReports.add(reports.map { $0.item(device: device, appBinaryName: binary) })
            await crashReports.send { await core.collectsNow }
        }
    }

    private var userKey: String { state.userId ?? Self.anonymousKey }

    /// Logs and returns true when a call fails validation; such calls are never queued.
    private func rejected(_ call: String, _ problem: String?) -> Bool {
        guard let problem else { return false }
        Log.error("\(call) ignored: \(problem)")
        return true
    }

    // MARK: - Identity

    func identify(userId: String, traits: [String: HeraldValue]) {
        guard state.enabled else { return }
        if rejected("identify", Validation.length("userId", userId, max: Validation.maxUserId)
            ?? Validation.attributes("traits", traits)) { return }
        let previous = state.userId
        if let previous, previous != userId {
            clearUserState()
        }
        state.userId = userId
        engine.lastShown = state.lastShown[userId] ?? [:]
        persist()
        record("identify", ["userId": .string(userId), "traits": .object(traits)])
        if previous == nil {
            // Same session, now identified: fetch this user's messages.
            scheduleSync(thenFire: nil)
        }
        if previous != userId { resendPushToken() }
    }

    func setUserToken(_ token: String?) {
        let token = (token?.isEmpty ?? true) ? nil : token
        let changed = state.userToken != token
        state.userToken = token
        persist()
        if !usersAwaitingToken.isEmpty {
            usersAwaitingToken = []
            if state.enabled { scheduleFlush() }
        }
        // identify() already synced without the token, which a server requiring verification refuses.
        if changed, token != nil, state.userId != nil, state.enabled { scheduleSync(thenFire: nil) }
    }

    /// Back to an anonymous user on the same device, with a new session.
    func reset() {
        clearUserState()
        state.userId = nil
        engine.lastShown = state.lastShown[Self.anonymousKey] ?? [:]
        persist()
        guard state.enabled else { return }
        ensureSession()
        resendPushToken()
    }

    /// Ends the session and forgets the current user's token, cards, messages and pending messages.
    /// In-app history (re-eligibility) is kept per user; only `wipeData()` clears it.
    private func clearUserState() {
        if let session = state.session {
            if state.enabled { enqueueSessionEnd(session) }
            state.session = nil
        }
        if let userId = state.userId, let token = state.userToken {
            state.pendingTokens[userId] = token
        }
        state.userToken = nil
        setHeraldId(nil)
        state.dismissedCardIds = []
        state.impressedCardIds = []
        state.messagesETag = nil
        state.pendingMessageIds = []
        state.deferredPushSubscription = nil
        storage.saveMessages(nil)
        cards = []
        engine.messages = []
        publishCards()
    }

    // MARK: - Events

    func track(_ name: String, properties: [String: HeraldValue], schemaVersion: String? = nil) {
        guard state.enabled else { return }
        if rejected("track", Validation.length("name", name, max: Validation.maxName)
            ?? Validation.properties("properties", properties)) { return }
        var fields: [String: HeraldValue] = ["name": .string(name), "properties": .object(properties)]
        if let schemaVersion {
            // SchemaVer MODEL-REVISION-ADDITION; a malformed one is dropped, not the event.
            if schemaVersion.range(of: #"^[1-9][0-9]*-(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil {
                fields["schemaVersion"] = .string(schemaVersion)
            } else {
                Log.debug("Ignoring schemaVersion \"\(schemaVersion)\" on \(name): expected a version such as 1-0-0")
            }
        }
        record("track", fields)
        fire(.event(name: name, properties: properties))
    }

    /// `automatic`: recorded by the SDK itself, only with `trackExternalPushes` on.
    func trackExternalPush(messageId: String?, category: ExternalPushCategory, source: String?, automatic: Bool) {
        if automatic && !configuration.trackExternalPushes { return }
        guard let properties = ExternalPush.properties(messageId: messageId, category: category, source: source) else {
            _ = rejected("trackExternalPush", ExternalPush.tooLong)
            return
        }
        track(ExternalPush.eventName, properties: properties)
    }

    func screen(_ name: String, properties: [String: HeraldValue]) {
        guard state.enabled else { return }
        if rejected("screen", Validation.length("name", name, max: Validation.maxName)
            ?? Validation.properties("properties", properties)) { return }
        record("screen", ["name": .string(name), "properties": .object(properties)])
    }

    func trackPurchase(productId: String, price: Double, currency: String, quantity: Int, properties: [String: HeraldValue]) {
        guard state.enabled else { return }
        let code = currency.uppercased()
        var problem = Validation.length("productId", productId, max: Validation.maxName)
        if code.utf16.count != 3 { problem = problem ?? "currency must be a 3-letter ISO 4217 code" }
        if quantity <= 0 { problem = problem ?? "quantity must be positive" }
        if !price.isFinite { problem = problem ?? "price must be finite" }
        if rejected("trackPurchase", problem ?? Validation.properties("properties", properties)) { return }
        record("purchase", [
            "productId": .string(productId), "price": .number(price), "currency": .string(code),
            "quantity": .number(Double(quantity)), "properties": .object(properties),
        ])
    }

    func setAttributes(_ attributes: [String: HeraldValue]) {
        guard state.enabled else { return }
        let attributes = Validation.droppingInvalidContacts(attributes)
        guard !attributes.isEmpty else { return }
        if rejected("setAttributes", Validation.attributes("attribute", attributes)) { return }
        record("attributes", ["attributes": .object(attributes)])
    }

    /// A push opt-in made before any APNs token exists waits for the token, so the server sees the
    /// device's push_token first. An opt-out is sent at once (a denied permission never yields a token)
    /// and cancels any deferred opt-in.
    func setSubscription(_ channel: SubscriptionChannel, _ subscriptionState: SubscriptionState) {
        guard state.enabled else { return }
        if channel == .push {
            if subscriptionState != .unsubscribed, state.pushToken == nil {
                state.deferredPushSubscription = subscriptionState
                persist()
                return
            }
            if state.deferredPushSubscription != nil {
                state.deferredPushSubscription = nil
                persist()
            }
        }
        record("subscription", ["channel": .string(channel.rawValue), "state": .string(subscriptionState.rawValue)])
    }

    func setPushToken(hex: String) {
        guard !rejected("setPushToken", Validation.length("token", hex, max: Validation.maxPushToken)) else { return }
        state.pushToken = hex
        persist()
        guard state.enabled else { return }
        enqueuePushToken(hex)
        if let deferred = state.deferredPushSubscription {
            state.deferredPushSubscription = nil
            persist()
            setSubscription(.push, deferred)
        }
    }

    /// A Live Activity push-to-start token (iOS 18+), sent as `push_token` platform `apns_live_activity`.
    func setLiveActivityToken(hex: String) {
        guard !rejected("setLiveActivityToken", Validation.length("token", hex, max: Validation.maxPushToken)) else { return }
        state.liveActivityToken = hex
        persist()
        guard state.enabled else { return }
        enqueuePushToken(hex, platform: "apns_live_activity")
    }

    private func resendPushToken() {
        if let token = state.pushToken { enqueuePushToken(token) }
        resendLiveActivityToken()
    }

    private func resendLiveActivityToken() {
        guard let token = state.liveActivityToken else { return }
        enqueuePushToken(token, platform: "apns_live_activity")
    }

    private func enqueuePushToken(_ token: String, platform: String = "apns") {
        var fields: [String: HeraldValue] = [
            "platform": .string(platform), "token": .string(token), "environment": .string(PushEnvironment.current),
        ]
        if !bundleId.isEmpty { fields["bundleId"] = .string(Validation.truncated(bundleId, Validation.maxName)) }
        record("push_token", fields)
    }

    /// The user acted on a Herald push (`open`, `button` or `dismiss`). Opens evaluate `push_open` triggers.
    /// `action` is open, button or dismiss. A button tap is also an open (Android parity): the open is
    /// logged first, then the button, each at most once per decision id. Without a decision id there is
    /// no per-send key, so nothing is deduplicated.
    func pushResponse(messageId: String, decisionId: String?, action: String, buttonId: String?) {
        guard state.enabled else { return }
        switch action {
        case "button":
            let opened = recordPush(messageId: messageId, decisionId: decisionId, action: "open", buttonId: nil)
            recordPush(messageId: messageId, decisionId: decisionId, action: "button", buttonId: buttonId)
            if opened { pushOpened() }
        case "open":
            if recordPush(messageId: messageId, decisionId: decisionId, action: "open", buttonId: nil) { pushOpened() }
        default:
            recordPush(messageId: messageId, decisionId: decisionId, action: action, buttonId: buttonId)
        }
    }

    /// A first (not redelivered) push open: it marks this launch as `from_push` and fires `push_open` triggers.
    private func pushOpened() {
        openedFromPush = true
        fire(.pushOpen)
    }

    /// Logs one push interaction; false when it was a repeat or invalid.
    @discardableResult
    private func recordPush(messageId: String, decisionId: String?, action: String, buttonId: String?) -> Bool {
        if action != "dismiss", let decisionId, !decisionId.isEmpty {
            // Opens keep the bare decision id as their key (the format already persisted).
            let key = action == "open" ? decisionId : "\(decisionId)#\(action)"
            if state.recentPushOpens.contains(key) { return false }
            state.recentPushOpens.append(key)
            if state.recentPushOpens.count > Self.maxRecentPushOpens {
                state.recentPushOpens.removeFirst(state.recentPushOpens.count - Self.maxRecentPushOpens)
            }
            persist()
        }
        return logInteraction(messageId: messageId, kind: "push", action: action, decisionId: decisionId, buttonId: buttonId)
    }

    // MARK: - Content cards

    /// Logged once per card per session, however many feeds show it (persisted with the session).
    func logCardImpression(_ card: ContentCard) {
        guard state.enabled else { return }
        ensureSession()  // a timed-out session ends first, clearing the set
        guard !state.impressedCardIds.contains(card.id),
            logInteraction(messageId: card.id, kind: "content_card", action: "impression", decisionId: card.decisionId)
        else { return }
        state.impressedCardIds.insert(card.id)
        persist()
        updateCard(card.id) { $0.viewed = true }
    }

    func logCardClick(_ card: ContentCard) {
        guard logInteraction(messageId: card.id, kind: "content_card", action: "click", decisionId: card.decisionId)
        else { return }
        updateCard(card.id) { $0.clicked = true }
    }

    func logCardDismissal(_ card: ContentCard) {
        guard logInteraction(messageId: card.id, kind: "content_card", action: "dismiss", decisionId: card.decisionId)
        else { return }
        state.dismissedCardIds.insert(card.id)
        persist()
        updateCard(card.id) { $0.dismissed = true }
    }

    private func updateCard(_ id: String, _ change: (inout ContentCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
        publishCards()
    }

    /// Empty while the SDK is disabled: cached cards stay hidden until `setEnabled(true)`.
    func visibleCards() -> [ContentCard] {
        guard state.enabled else { return [] }
        let date = now()
        return cards.filter { !$0.dismissed && !$0.isExpired(at: date) && !state.dismissedCardIds.contains($0.id) }
    }

    private func publishCards() {
        let visible = visibleCards()
        scheduleExpiryRefresh(visible)
        spawn { core in await core.output.cardsChanged(visible) }
    }

    /// Republishes when the soonest visible card expires, so an open feed drops it without a sync.
    private func scheduleExpiryRefresh(_ visible: [ContentCard]) {
        expiryRefresh?.cancel()
        guard let soonest = visible.compactMap(\.expiresAt).min() else { return }
        let seconds = max(soonest.timeIntervalSince(now()), 0)
        // Not tracked by `drain()`: it sleeps in real time.
        expiryRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(seconds, 365 * 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.publishCards()
        }
    }

    // MARK: - In-app messages

    func logMessageImpression(_ message: InAppMessage) {
        logInteraction(messageId: message.id, kind: "in_app", action: "impression", decisionId: message.decisionId)
    }

    func logMessageClick(_ message: InAppMessage, buttonId: String?) {
        logInteraction(
            messageId: message.id, kind: "in_app", action: buttonId == nil ? "click" : "button",
            decisionId: message.decisionId, buttonId: buttonId
        )
    }

    func logMessageDismissal(_ message: InAppMessage) {
        logInteraction(messageId: message.id, kind: "in_app", action: "dismiss", decisionId: message.decisionId)
    }

    /// Evaluates a trigger. The winning message joins the pending list and shows as soon as nothing
    /// else is on screen, the minimum interval has passed, the app is active and a presenter exists.
    func fire(_ trigger: TriggerEvent) {
        guard state.enabled, let message = engine.candidate(for: trigger, now: now()) else { return }
        if !state.pendingMessageIds.contains(message.id) {
            state.pendingMessageIds.append(message.id)
            persist()
        }
        showPendingIfPossible()
    }

    /// Shows the next pending message (including ones the delegate deferred with `.later`), ignoring
    /// the minimum interval.
    func showNext() {
        showPendingIfPossible(ignoringInterval: true)
    }

    /// Offers the highest-priority pending message when one may show now; otherwise keeps it pending.
    /// Called on triggers, `appDidBecomeActive`, after a message closes, when a presenter is set, and
    /// when the minimum interval runs out.
    func showPendingIfPossible(ignoringInterval: Bool = false) {
        guard state.enabled, isForeground, showingId == nil else { return }
        let date = now()
        let before = state.pendingMessageIds
        // Drop ids that are gone, expired or no longer eligible for this user.
        state.pendingMessageIds.removeAll { id in
            guard let message = engine.messages.first(where: { $0.id == id }) else { return true }
            return !engine.isEligible(message, now: date)
        }
        if state.pendingMessageIds != before { persist() }
        guard let message = engine.nextPending(state.pendingMessageIds, now: date) else { return }
        let remaining = engine.intervalRemaining(now: date)
        if !ignoringInterval, remaining > 0 {
            scheduleIntervalRetry(after: remaining)
            return
        }
        showingId = message.id
        engine.isShowing = true
        spawn { core in await core.offer(message) }
    }

    private func scheduleIntervalRetry(after seconds: TimeInterval) {
        intervalRetry?.cancel()
        // Not tracked by `drain()`: it sleeps in real time.
        intervalRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.showPendingIfPossible()
        }
    }

    private func offer(_ message: InAppMessage) async {
        let user = userKey
        let messageId = message.id
        let choice = await output.offer(message) { [weak self] in
            Task { await self?.messageClosed(id: messageId) }
        }
        // wipeData() (or anything else that freed the slot) may have run while the main actor decided.
        // A reset or identify does not make the hand-off stale: history goes under the user captured at
        // hand-off.
        let stillOnScreen = showingId == messageId
        switch choice {
        case .display:
            // On screen now; the slot stays taken until onClose.
            guard stillOnScreen else { return }
            let date = now()
            engine.recordDisplay(message, now: date)
            state.lastShown[user, default: [:]][messageId] = date
            state.lastDisplayAt = date
            state.pendingMessageIds.removeAll { $0 == messageId }
            persist()
            logMessageImpression(message)
        case .discard:
            releaseSlot(messageId)
            state.pendingMessageIds.removeAll { $0 == messageId }
            persist()
        case .later, nil:
            // Stays pending; retried on the next trigger, activation, close, presenter change or showNext().
            if choice == nil { Log.info("In-app message \(messageId) not shown (no presenter or no active scene); stays pending") }
            releaseSlot(messageId)
        }
    }

    private func releaseSlot(_ id: String) {
        guard showingId == id else { return }
        showingId = nil
        engine.isShowing = false
    }

    func messageClosed(id: String) {
        guard showingId == id else { return }
        releaseSlot(id)
        showPendingIfPossible()
    }

    // MARK: - Recording

    /// Queues an interaction; returns false when the SDK is disabled or the ids break server limits.
    @discardableResult
    private func logInteraction(
        messageId: String, kind: String, action: String, decisionId: String?, buttonId: String? = nil
    ) -> Bool {
        guard state.enabled else { return false }
        let decisionId = decisionId?.isEmpty == true ? nil : decisionId
        var problem = Validation.length("messageId", messageId, max: Validation.maxMessageId)
        if let decisionId { problem = problem ?? Validation.length("decisionId", decisionId, max: Validation.maxMessageId) }
        if action == "button" {
            problem = problem ?? Validation.length("buttonId", buttonId ?? "", max: Validation.maxMessageId)
        }
        if rejected("Interaction \(kind) \(action)", problem) { return false }
        var fields: [String: HeraldValue] = [
            "messageId": .string(messageId), "kind": .string(kind), "action": .string(action),
        ]
        if let decisionId { fields["decisionId"] = .string(decisionId) }
        if action == "button", let buttonId { fields["buttonId"] = .string(buttonId) }
        record("interaction", fields)
        return true
    }

    /// Records an event in the current session, starting a new session first if needed.
    private func record(_ type: String, _ fields: [String: HeraldValue]) {
        ensureSession()
        enqueue(type, fields)
    }

    private func enqueue(_ type: String, _ fields: [String: HeraldValue], sessionId: String? = nil, at date: Date? = nil) {
        // Push tokens and subscriptions are queued under the kill switch (and sent once it lifts), so a device that
        // registered or unsubscribed meanwhile isn't lost; nothing is sent while it is on.
        guard remoteCollects || Self.deliveryTypes.contains(type) else { return }
        var event = fields
        event["id"] = .string(makeId())
        event["type"] = .string(type)
        event["timestamp"] = .string(WireDate.format(date ?? now()))
        if let id = sessionId ?? state.session?.id { event["sessionId"] = .string(id) }
        if let data = try? JSONEncoder().encode(HeraldValue.object(event)), data.count > Self.maxEventBytes {
            Log.debug("Dropping a \(type) event larger than \(Self.maxEventBytes / 1024) KB")
            state.dropped += 1
            persist()
            return
        }
        let dropped = queue.append(QueuedEvent(userId: state.userId, event: event))
        if dropped > 0 {
            state.dropped += dropped
            persist()
            Log.warning("Event queue full: dropped \(dropped) oldest event(s)")
        }
        if queue.count >= configuration.flushAt { scheduleFlush() }
    }

    // MARK: - Sessions

    /// Continues the current session or, after the foreground (or, once backgrounded, the background) timeout of
    /// inactivity, ends it and starts a new one. A session persisted by an earlier launch continues the same way.
    func ensureSession() {
        let date = now()
        let timeout = state.inBackground ? configuration.backgroundSessionTimeout : configuration.foregroundSessionTimeout
        if var session = state.session {
            if date.timeIntervalSince(session.lastActivityAt) < timeout {
                session.lastActivityAt = date
                state.session = session
                // Activity is persisted at most once a minute (and on background); a crash costs at most
                // a minute of session duration.
                if activityPersistedAt.map({ date.timeIntervalSince($0) >= 60 }) ?? true {
                    activityPersistedAt = date
                    persist()
                }
                return
            }
            enqueueSessionEnd(session)
        }
        let session = SessionState(id: String(Int64(date.timeIntervalSince1970 * 1000)), startedAt: date, lastActivityAt: date)
        let previousId = state.session?.id ?? state.lastSessionId
        state.session = session
        state.sessionIndex += 1
        state.lastSessionId = session.id
        state.impressedCardIds = []
        activityPersistedAt = date
        persist()
        enqueue("session_start", ["properties": [
            "session_index": .number(Double(state.sessionIndex)),
            "previous_session_id": previousId.map(HeraldValue.string) ?? .null,
        ]])
        scheduleSync(thenFire: .sessionStart)
    }

    private func enqueueSessionEnd(_ session: SessionState) {
        let duration = max(0, session.lastActivityAt.timeIntervalSince(session.startedAt)).rounded()
        enqueue("session_end", ["durationSeconds": .number(duration)], sessionId: session.id, at: session.lastActivityAt)
    }

    /// Test hook: ends the session now without starting a new one.
    func endSessionForTesting() {
        guard let session = state.session else { return }
        enqueueSessionEnd(session)
        state.session = nil
        persist()
    }

    // MARK: - Lifecycle

    /// Every `didBecomeActive`. Lifecycle events go out only on a real move to the foreground: the launch's first
    /// activation or one after `appDidEnterBackground`, never after an alert, Control Center or Face ID sheet.
    /// `lifecycle` false (re-enabled while in the foreground) sends none.
    func appDidBecomeActive(lifecycle: Bool = true) {
        isForeground = true
        if configFetchedAt.map({ now().timeIntervalSince($0) >= Self.configFetchInterval }) ?? true { fetchConfig() }
        let opened = appOpenPending
        appOpenPending = false
        guard state.enabled else { return }
        ensureSession()  // uses the background timeout when coming back from the background
        let fromBackground = opened || state.inBackground
        if state.inBackground {
            state.inBackground = false
            persist()
        }
        if lifecycle, fromBackground {
            if opened { recordLifecycle("$app_opened", ["from_push": .bool(openedFromPush)]) }
            recordLifecycle("$app_foreground")
        }
        startFlushTimer()
        // Timers do not run while the app is suspended: drop cards that expired meanwhile and reschedule.
        publishCards()
        showPendingIfPossible()
    }

    /// Persists session activity and starts (or joins) a flush. Returns the flush task so the caller can
    /// hold its background-task assertion until the upload really finishes, without blocking recording.
    func appDidEnterBackground() -> Task<Void, Never> {
        isForeground = false
        // Persisted: a cold start after a kill in the background decides continuation with the background timeout.
        state.inBackground = true
        persist()
        // Never starts or ends a session: going to the background isn't activity.
        recordLifecycle("$app_background", session: false)
        flushTimer?.cancel()
        flushTimer = nil
        intervalRetry?.cancel()
        if var session = state.session {
            session.lastActivityAt = now()
            state.session = session
            activityPersistedAt = session.lastActivityAt
            persist()
        }
        return startFlush()
    }

    private func startFlushTimer() {
        flushTimer?.cancel()
        let interval = configuration.flushInterval
        flushTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.scheduleFlush()
            }
        }
    }

    // MARK: - Enable / wipe

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = state.enabled
        if !enabled { sendPushUnsubscribe() }
        state.enabled = enabled
        persist()
        publishCards()
        if enabled {
            if !wasEnabled { restorePushIfAuthorized() }
            if isForeground { appDidBecomeActive(lifecycle: false) }
        } else {
            flushTimer?.cancel()
            flushTimer = nil
        }
    }

    /// Undoes the unsubscribe sent when the SDK was turned off: when notification permission is still
    /// granted, queues the push token and a `subscription push subscribed` for the next batch. With no
    /// stored token (after `wipeData()`, or a launch whose registration never finished) it asks iOS for
    /// the token again; the subscription waits for it, as any push opt-in does. `resubscribe` false
    /// (launch) only asks for a missing token.
    private func restorePushIfAuthorized(resubscribe: Bool = true) {
        spawn { core in
            let authorization = await core.deviceInfo.current().pushAuthorization ?? ""
            guard ["authorized", "provisional", "ephemeral"].contains(authorization), core.state.enabled else { return }
            if resubscribe { core.resendLiveActivityToken() }
            if let token = core.state.pushToken {
                core.enqueuePushToken(token)
                core.setSubscription(.push, .subscribed)
            } else {
                if resubscribe { core.setSubscription(.push, .subscribed) }
                await core.registerForPush()
            }
        }
    }

    /// Before the SDK goes quiet, tells Herald to stop pushing to this device: one `subscription push
    /// unsubscribed` batch, sent once in the background and never queued or retried (best effort).
    private func sendPushUnsubscribe() {
        guard state.enabled, state.pushToken != nil else { return }
        var event: [String: HeraldValue] = [
            "id": .string(makeId()), "type": "subscription", "timestamp": .string(WireDate.format(now())),
            "channel": "push", "state": "unsubscribed",
        ]
        if let id = state.session?.id { event["sessionId"] = .string(id) }
        let userId = state.userId
        let deviceId = state.deviceId
        // Built now: wipeData() replaces the device id and token right after this returns.
        var request = makeRequest(path: "api/v1/sdk/batch", userId: userId)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let batch = [QueuedEvent(userId: userId, event: event)]
        let headers = request
        spawn { core in
            guard let (body, _) = await core.batchBody(batch, userId: userId, dropped: 0, deviceId: deviceId) else { return }
            var request = headers
            request.httpBody = body
            _ = try? await core.transport.send(request)
        }
    }

    /// Deletes every file and in-memory record, gives the device a new id and leaves the SDK disabled
    /// until `setEnabled(true)`.
    func wipeData() {
        sendPushUnsubscribe()
        flushTimer?.cancel()
        flushTimer = nil
        queue.removeAll()
        crashReports?.wipe()
        storage.wipe()
        intervalRetry?.cancel()
        state = PersistedState(deviceId: UUID().uuidString.lowercased())
        heraldIdMirror.withLock { $0 = nil }
        state.enabled = false
        cards = []
        engine = InAppEngine(minimumInterval: configuration.inAppMinimumInterval)
        showingId = nil
        failureCount = 0
        nextAttemptAt = nil
        usersAwaitingToken = []
        persist()
        publishCards()
    }

    private func persist() { storage.saveState(state) }

    /// A new person (sign-out, another user) has no User ID until their first accepted batch.
    private func setHeraldId(_ id: String?) {
        state.heraldId = id
        heraldIdMirror.withLock { $0 = id }
    }

    /// `data.heraldId` of an accepted batch response, when the server sent one.
    static func heraldId(in body: Data) -> String? {
        struct Response: Decodable {
            struct Payload: Decodable { let heraldId: String? }
            let data: Payload
        }
        return (try? JSONDecoder().decode(Response.self, from: body))?.data.heraldId
    }

    @discardableResult
    private func spawn(_ work: @escaping @Sendable (isolated HeraldCore) async -> Void) -> Task<Void, Never> {
        let id = UUID()
        // The task runs on this actor only after the current call returns, so the entry exists before removal.
        let task = Task {
            await work(self)
            self.inFlight[id] = nil
        }
        inFlight[id] = task
        return task
    }

    /// Waits until every child task (and any task they started) has finished.
    func drain() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    // MARK: - Flush

    func scheduleFlush() {
        startFlush()
    }

    /// The running flush, or a new one. Only one flush runs at a time.
    @discardableResult
    func startFlush() -> Task<Void, Never> {
        if let currentFlush { return currentFlush }
        let task = spawn { core in
            await core.runFlush()
            core.currentFlush = nil
        }
        currentFlush = task
        return task
    }

    /// Flushes and waits for it (tests and internal callers only; public calls never wait).
    func flushNow() async {
        await startFlush().value
    }

    /// Flushes and reports, through `done`, whether every event queued before this call was accepted by the
    /// server: false when one is still queued (offline, backoff, disabled, waiting for a user token) or was
    /// dropped. Events queued later don't count. Waits in a child task, so the actor keeps taking calls.
    func confirmFlush(_ done: @escaping @Sendable (Bool) -> Void) {
        // Disabled, calls aren't recorded, so an empty queue proves nothing.
        guard state.enabled, !appKeyRejected else { return done(false) }
        let ids = Set(queue.entries.map(\.id))
        guard !ids.isEmpty else { return done(true) }
        confirmations += 1
        spawn { core in
            await core.flushNow()
            let delivered = ids.isSubset(of: core.acceptedIds)
            core.confirmations -= 1
            if core.confirmations == 0 { core.acceptedIds = [] }
            done(delivered)
        }
    }

    /// Sends queued events in batches until the queue is empty, a batch must be retried, or the SDK is disabled.
    private func runFlush() async {
        guard state.enabled, remoteCollects, !appKeyRejected else { return }
        if let nextAttemptAt, now() < nextAttemptAt { return }
        dropExpiredEvents()

        while state.enabled, remoteCollects, !queue.entries.isEmpty {
            let (batch, userId) = nextBatch()
            guard !batch.isEmpty else { break }
            let droppedReported = state.dropped
            guard let (body, sent) = await batchBody(batch, userId: userId, dropped: droppedReported) else {
                // A single event too large to send: drop it rather than block the queue forever.
                Log.error("Dropping an event larger than \(Self.maxBatchBytes / 1024) KB")
                queue.remove(ids: [batch[0].id])
                continue
            }
            var request = makeRequest(path: "api/v1/sdk/batch", userId: userId)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            let ids = Set(sent.map(\.id))
            let outcome: BatchOutcome
            var responseBody = Data()
            do {
                let (data, response) = try await transport.send(request)
                responseBody = data
                outcome = Backoff.outcome(
                    status: response.statusCode, response: response, body: data,
                    attempt: failureCount + 1, random: random(), now: now()
                )
            } catch {
                Log.info("Batch send failed: \(error.localizedDescription)")
                outcome = .retry(delay: Backoff.delay(attempt: failureCount + 1, random: random()))
            }

            switch outcome {
            case .accepted:
                let rejected = Backoff.rejectedEvents(responseBody)
                // A rejected event was not accepted, so a confirmed flush waiting on it reports false.
                let rejectedIds = Set(rejected.compactMap { sent.indices.contains($0.index) ? sent[$0.index].id : nil })
                if confirmations > 0 { acceptedIds.formUnion(ids.subtracting(rejectedIds)) }
                queue.remove(ids: ids)
                for r in rejected { Log.debug("Herald rejected event \(r.line)") }
                // A signed-in batch accepted without a token: verification is off, so identified syncs resume.
                if userId != nil, request.value(forHTTPHeaderField: "x-herald-user-token") == nil, state.userTokenRequired {
                    state.userTokenRequired = false
                    persist()
                }
                state.dropped = max(0, state.dropped - droppedReported)
                // Only the current user's: a batch from before a sign-out or switch names the previous person.
                if let userId, userId == state.userId, let id = Self.heraldId(in: responseBody), id != state.heraldId {
                    setHeraldId(id)
                    persist()
                }
                failureCount = 0
                nextAttemptAt = nil
                pruneTokens()
            case .rejected(401) where Backoff.isAppKeyRejection(responseBody):
                // Retrying cannot help, but dropping would lose the events to a configuration mistake.
                Log.error("Herald rejected the app key: check the publishable key in configure")
                appKeyRejected = true
                return
            case .rejected(401) where userId != nil:
                // Most likely identify() ran and setUserToken() has not yet: keep the events for the token.
                // A token set while this request was in flight is tried on the next loop pass.
                if token(for: userId) != request.value(forHTTPHeaderField: "x-herald-user-token") { continue }
                if usersAwaitingToken.isEmpty { Log.warning("Herald needs a user token: call setUserToken") }
                usersAwaitingToken.insert(userId!)
                state.userTokenRequired = true
                persist()
                failureCount = 0
                nextAttemptAt = nil
            case .rejected(let status):
                Log.error("Herald rejected a batch of \(sent.count) event(s) with HTTP \(status); dropping it")
                queue.remove(ids: ids)
                failureCount = 0
                nextAttemptAt = nil
                pruneTokens()
            case .retry(let delay):
                failureCount += 1
                nextAttemptAt = now().addingTimeInterval(delay)
                Log.info("Batch will be retried in \(Int(delay)) s")
                return
            }
        }
    }

    /// Drops queued events older than `maxQueuedEventAge` (Herald would reject them) and counts them in `dropped`.
    private func dropExpiredEvents() {
        let cutoff = now().addingTimeInterval(-configuration.maxQueuedEventAge)
        let expired = queue.entries.filter { entry in
            entry.event["timestamp"]?.stringValue.flatMap(WireDate.parse).map { $0 < cutoff } ?? false
        }
        guard !expired.isEmpty else { return }
        queue.remove(ids: Set(expired.map(\.id)))
        state.dropped += expired.count
        persist()
        Log.debug("Dropped \(expired.count) queued event(s) older than \(Int(configuration.maxQueuedEventAge / 86_400)) days")
    }

    /// The oldest run of events for one user, up to 100, skipping users waiting for a token. Events
    /// never cross from one user to another or from a user back to anonymous.
    func nextBatch() -> (events: [QueuedEvent], userId: String?) {
        // Each batch holds one recorded user (anonymous counts as one), so pre-login events stay anonymous.
        let sendable = queue.entries.filter { $0.userId.map { !usersAwaitingToken.contains($0) } ?? true }
        guard let first = sendable.first else { return ([], nil) }
        var batch: [QueuedEvent] = []
        for entry in sendable {
            if batch.count == Self.maxBatchEvents || entry.userId != first.userId { break }
            batch.append(entry)
        }
        return (Self.pushTokensFirst(batch), first.userId)
    }

    /// Moves each push_token ahead of the batch's first push subscription event, keeping the order
    /// otherwise, so the server registers the token before it applies the push subscription.
    static func pushTokensFirst(_ batch: [QueuedEvent]) -> [QueuedEvent] {
        let isPushSubscription = { (e: QueuedEvent) in e.event["type"] == "subscription" && e.event["channel"] == "push" }
        guard let first = batch.firstIndex(where: isPushSubscription) else { return batch }
        let lateTokens = batch[first...].filter { $0.event["type"] == "push_token" }
        guard !lateTokens.isEmpty else { return batch }
        var result = Array(batch[..<first])
        result.append(contentsOf: lateTokens)
        result.append(contentsOf: batch[first...].filter { $0.event["type"] != "push_token" })
        return result
    }

    /// Encodes the batch, halving it until it fits 512 KB. Returns the body and the events it holds
    /// (the rest stay queued), or nil when even one event is too large.
    private func batchBody(
        _ batch: [QueuedEvent], userId: String?, dropped: Int, deviceId: String? = nil
    ) async -> (Data, [QueuedEvent])? {
        var context = DeviceContext.build(await deviceInfo.current(), collection: configuration.deviceDataCollection)
        if let consent = state.consent, case .object(var fields) = context {
            var record: [String: HeraldValue] = ["basis": .string(consent.basis), "recordedAt": .string(WireDate.format(consent.recordedAt))]
            if let id = consent.documentId { record["documentId"] = .string(id) }
            if let version = consent.documentVersion { record["documentVersion"] = .string(version) }
            fields["consent"] = .object(record)
            context = .object(fields)
        }
        var events = batch
        while !events.isEmpty {
            let payload: HeraldValue = [
                "sdk": ["name": .string(Self.sdkName), "version": .string(Herald.sdkVersion)],
                "deviceId": .string(deviceId ?? state.deviceId),
                "userId": userId.map(HeraldValue.string) ?? .null,
                "sentAt": .string(WireDate.format(now())),
                "dropped": .number(Double(dropped)),
                "context": context,
                "events": .array(events.map { .object($0.event) }),
            ]
            if let data = try? JSONEncoder().encode(payload), data.count <= Self.maxBatchBytes {
                return (data, events)
            }
            if events.count == 1 { return nil }
            events = Array(events.prefix(events.count / 2))
        }
        return nil
    }

    private func pruneTokens() {
        let queuedUsers = Set(queue.entries.compactMap(\.userId))
        state.pendingTokens = state.pendingTokens.filter { queuedUsers.contains($0.key) }
        persist()
    }

    private func token(for userId: String?) -> String? {
        guard let userId else { return nil }
        return userId == state.userId ? state.userToken : state.pendingTokens[userId]
    }

    private func makeRequest(path: String, userId: String?, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: configuration.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        // URLComponents leaves "+" as is, and the server's URLSearchParams reads it as a space.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        var request = URLRequest(url: components?.url ?? configuration.endpoint.appendingPathComponent(path))
        request.setValue(configuration.appKey, forHTTPHeaderField: "x-herald-app-key")
        if let token = token(for: userId) {
            request.setValue(token, forHTTPHeaderField: "x-herald-user-token")
        }
        return request
    }

    // MARK: - Remote config

    private var remoteCollects: Bool { remote?.collects ?? true }
    /// On, and not turned off remotely: crash reports go out only then.
    var collectsNow: Bool { state.enabled && remoteCollects }
    static let deliveryTypes: Set<String> = ["push_token", "subscription"]

    /// Fetches the remote settings in a child task (startup never waits). A network or parse error, or any status but
    /// 200 / 304, keeps what is applied. Skipped while the app turned the SDK off.
    private func fetchConfig() {
        guard state.enabled else { return }
        configFetchedAt = now()
        var request = makeRequest(path: "api/v1/sdk/config", userId: nil)
        request.httpMethod = "GET"
        if let version = remote?.version { request.setValue("\"\(version)\"", forHTTPHeaderField: "If-None-Match") }
        let sent = request
        spawn { core in
            guard let (data, response) = try? await core.transport.send(sent), response.statusCode == 200,
                let config = RemoteConfig.decode(data)
            else { return }
            core.storage.saveRemoteConfig(data, appKey: core.localConfiguration.appKey)
            core.applyRemote(config)
        }
    }

    func applyRemote(_ config: RemoteConfig) {
        let wasCollecting = remoteCollects
        remote = config
        remoteVersion.withLock { $0 = config.version }
        let previousInterval = configuration.flushInterval
        configuration = config.applied(to: localConfiguration)
        if !config.collects {
            // The kill switch: queued events are never sent, except push tokens and subscriptions.
            queue.remove(ids: Set(queue.entries.filter { !Self.deliveryTypes.contains($0.event["type"]?.stringValue ?? "") }.map(\.id)))
            flushTimer?.cancel()
            flushTimer = nil
            Log.info("Collection is turned off remotely")
        } else {
            if !wasCollecting, state.enabled {
                resendPushToken()
                scheduleFlush()
            }
            if isForeground, state.enabled, !wasCollecting || configuration.flushInterval != previousInterval {
                startFlushTimer()
            }
        }
    }

    // MARK: - Consent

    func setConsent(basis: ConsentBasis, documentId: String?, documentVersion: String?) {
        let documentId = documentId?.isEmpty == true ? nil : documentId
        let documentVersion = documentVersion?.isEmpty == true ? nil : documentVersion
        if rejected("setConsent", Validation.length("documentId", documentId ?? "", min: 0, max: 100)
            ?? Validation.length("documentVersion", documentVersion ?? "", min: 0, max: 100)) { return }
        state.consent = ConsentRecord(basis: basis.rawValue, documentId: documentId, documentVersion: documentVersion, recordedAt: now())
        persist()
    }

    func clearConsent() {
        state.consent = nil
        persist()
    }

    // MARK: - Message sync

    func scheduleSync(thenFire trigger: TriggerEvent?) {
        spawn { core in
            await core.syncMessages()
            if let trigger { core.fire(trigger) }
        }
    }

    /// A Herald sync push: refreshes (with the usual ETag) unless another sync push did within
    /// `syncPushDebounce`. Never shows anything or logs a push interaction. Calls `done` when finished.
    func syncFromPush(done: @escaping @Sendable () -> Void) {
        let date = now()
        guard state.enabled else { return done() }
        if let last = lastSyncPushAt, date >= last, date.timeIntervalSince(last) < Self.syncPushDebounce {
            Log.debug("Sync push skipped: another one refreshed less than \(Int(Self.syncPushDebounce)) s ago")
            return done()
        }
        lastSyncPushAt = date
        spawn { core in
            await core.syncMessages()
            done()
        }
    }

    /// Identified, without a token, on a server known to require one: the sync would only get a 401.
    private var syncAwaitsToken: Bool {
        state.userId != nil && state.userToken == nil && state.userTokenRequired
    }

    /// Fetches cards and in-app messages; a 304 keeps the cache. Waits for `setUserToken` (which syncs) while
    /// `syncAwaitsToken`.
    func syncMessages() async {
        guard state.enabled, remoteCollects else { return }
        guard !isSyncing else {
            // A sync for a possibly different user is in flight: run once more when it finishes.
            resyncRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            resyncRequested = false
            if syncAwaitsToken {
                Log.debug("Message sync waits for setUserToken")
                return
            }
            await performSync()
        } while resyncRequested && state.enabled
    }

    private func performSync() async {
        let userId = state.userId
        var query = [URLQueryItem(name: "deviceId", value: state.deviceId)]
        if let userId { query.append(URLQueryItem(name: "userId", value: userId)) }
        var request = makeRequest(path: "api/v1/sdk/messages", userId: userId, query: query)
        request.httpMethod = "GET"
        if let etag = state.messagesETag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let sentToken = request.value(forHTTPHeaderField: "x-herald-user-token") != nil

        do {
            let (data, response) = try await transport.send(request)
            // The user may have changed while the request was in flight: that response is not theirs.
            guard state.userId == userId else { return }
            switch response.statusCode {
            case 304:
                Log.debug("Messages unchanged")
            case 200..<300:
                let payload = try MessagesPayload.decode(data)
                storage.saveMessages(data)
                state.messagesETag = response.value(forHTTPHeaderField: "ETag")
                // Accepted without a token: verification is not required (any more).
                if userId != nil, !sentToken { state.userTokenRequired = false }
                persist()
                apply(payload)
            case 401 where userId != nil && !Backoff.isAppKeyRejection(data):
                state.userTokenRequired = true
                persist()
                // Expected before the first setUserToken, which syncs again: not an error then.
                if !sentToken {
                    Log.debug("Message sync needs a user token; waiting for setUserToken")
                } else {
                    Log.warning("Message sync failed with HTTP 401: Herald refused the user token")
                }
            default:
                Log.warning("Message sync failed with HTTP \(response.statusCode)")
            }
        } catch {
            Log.info("Message sync failed: \(error.localizedDescription)")
        }
    }

    func debugApply(_ payload: MessagesPayload) {
        apply(payload)
    }

    func debugShowInAppMessage(_ messageId: String) {
        guard state.enabled, showingId == nil, let message = engine.messages.first(where: { $0.id == messageId }) else { return }
        showingId = message.id
        engine.isShowing = true
        spawn { core in await core.offer(message) }
    }

    private func apply(_ payload: MessagesPayload) {
        cards = payload.contentCards
        engine.messages = payload.inAppMessages
        // Forget local dismissals the server no longer returns.
        let ids = Set(cards.map(\.id))
        state.dismissedCardIds = state.dismissedCardIds.filter { ids.contains($0) }
        publishCards()
    }
}
