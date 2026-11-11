import Foundation

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
    static let anonymousKey = "anonymous"
    static let maxRecentPushOpens = 50

    let configuration: HeraldConfiguration
    private let storage: Storage
    private let transport: HeraldTransport
    private let deviceInfo: DeviceInfoProvider
    private let output: CoreOutput
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let makeId: @Sendable () -> String

    private(set) var state: PersistedState
    private let queue: EventQueue
    var queuedCount: Int { queue.count }
    private(set) var engine: InAppEngine
    private(set) var cards: [ContentCard] = []
    /// Id of the in-app message on screen (or being offered), so a stale `onClose` cannot free the slot.
    private(set) var showingId: String?

    private var currentFlush: Task<Void, Never>?
    private var isSyncing = false
    private var resyncRequested = false
    private(set) var failureCount = 0
    private(set) var nextAttemptAt: Date?
    /// Users whose batch got 401: their events stay queued and unsent until `setUserToken`.
    private(set) var usersAwaitingToken: Set<String> = []
    private(set) var isForeground = false
    private var flushTimer: Task<Void, Never>?
    private var intervalRetry: Task<Void, Never>?
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
        bundleId: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.bundleId = bundleId
        self.configuration = configuration
        self.storage = storage
        self.transport = transport
        self.deviceInfo = deviceInfo
        self.output = output
        self.now = now
        self.random = random
        self.makeId = makeId
        state = storage.loadState() ?? PersistedState(deviceId: UUID().uuidString.lowercased())
        if storage.isDisabledMarked { state.enabled = false }
        queue = EventQueue(fileURL: storage.queueURL)
        engine = InAppEngine(minimumInterval: configuration.inAppMinimumInterval)
        engine.lastShown = state.lastShown[state.userId ?? Self.anonymousKey] ?? [:]
        engine.lastDisplayAt = state.lastDisplayAt
        if let cached = storage.loadMessages(), let payload = try? MessagesPayload.decode(cached) {
            cards = payload.contentCards
            engine.messages = payload.inAppMessages
        }
        storage.saveState(state)
    }

    /// Publishes the cached cards once the store is listening.
    func start() async {
        await output.cardsChanged(visibleCards())
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
        state.dismissedCardIds = []
        state.messagesETag = nil
        state.pendingMessageIds = []
        state.deferredPushSubscription = nil
        storage.saveMessages(nil)
        cards = []
        engine.messages = []
        publishCards()
    }

    // MARK: - Events

    func track(_ name: String, properties: [String: HeraldValue]) {
        guard state.enabled else { return }
        if rejected("track", Validation.length("name", name, max: Validation.maxName)
            ?? Validation.properties("properties", properties)) { return }
        record("track", ["name": .string(name), "properties": .object(properties)])
        fire(.event(name: name, properties: properties))
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

    private func resendPushToken() {
        guard let token = state.pushToken else { return }
        enqueuePushToken(token)
    }

    private func enqueuePushToken(_ token: String) {
        var fields: [String: HeraldValue] = [
            "platform": "apns", "token": .string(token), "environment": .string(PushEnvironment.current),
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
            if opened { fire(.pushOpen) }
        case "open":
            if recordPush(messageId: messageId, decisionId: decisionId, action: "open", buttonId: nil) { fire(.pushOpen) }
        default:
            recordPush(messageId: messageId, decisionId: decisionId, action: action, buttonId: buttonId)
        }
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

    func logCardImpression(_ card: ContentCard) {
        guard logInteraction(messageId: card.id, kind: "content_card", action: "impression", decisionId: card.decisionId)
        else { return }
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

    func visibleCards() -> [ContentCard] {
        let date = now()
        return cards.filter { !$0.dismissed && !$0.isExpired(at: date) && !state.dismissedCardIds.contains($0.id) }
    }

    private func publishCards() {
        let visible = visibleCards()
        spawn { core in await core.output.cardsChanged(visible) }
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
        var event = fields
        event["id"] = .string(makeId())
        event["type"] = .string(type)
        event["timestamp"] = .string(WireDate.format(date ?? now()))
        if let id = sessionId ?? state.session?.id { event["sessionId"] = .string(id) }
        let dropped = queue.append(QueuedEvent(userId: state.userId, event: event))
        if dropped > 0 {
            state.dropped += dropped
            persist()
            Log.warning("Event queue full: dropped \(dropped) oldest event(s)")
        }
        if queue.count >= configuration.flushAt { scheduleFlush() }
    }

    // MARK: - Sessions

    /// Continues the current session or, after `sessionTimeout` of inactivity, ends it and starts a new one.
    func ensureSession() {
        let date = now()
        if var session = state.session {
            if date.timeIntervalSince(session.lastActivityAt) < configuration.sessionTimeout {
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
        state.session = session
        activityPersistedAt = date
        persist()
        enqueue("session_start", [:])
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

    func appDidBecomeActive() {
        isForeground = true
        guard state.enabled else { return }
        ensureSession()
        startFlushTimer()
        showPendingIfPossible()
    }

    /// Persists session activity and starts (or joins) a flush. Returns the flush task so the caller can
    /// hold its background-task assertion until the upload really finishes, without blocking recording.
    func appDidEnterBackground() -> Task<Void, Never> {
        isForeground = false
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
        state.enabled = enabled
        persist()
        if enabled {
            if isForeground { appDidBecomeActive() }
        } else {
            flushTimer?.cancel()
            flushTimer = nil
        }
    }

    /// Deletes every file and in-memory record, gives the device a new id and leaves the SDK disabled
    /// until `setEnabled(true)`.
    func wipeData() {
        flushTimer?.cancel()
        flushTimer = nil
        queue.removeAll()
        storage.wipe()
        intervalRetry?.cancel()
        state = PersistedState(deviceId: UUID().uuidString.lowercased())
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

    /// Sends queued events in batches until the queue is empty, a batch must be retried, or the SDK is disabled.
    private func runFlush() async {
        guard state.enabled else { return }
        if let nextAttemptAt, now() < nextAttemptAt { return }

        while state.enabled, !queue.entries.isEmpty {
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
            do {
                let (data, response) = try await transport.send(request)
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
                queue.remove(ids: ids)
                state.dropped = max(0, state.dropped - droppedReported)
                failureCount = 0
                nextAttemptAt = nil
                pruneTokens()
            case .rejected(401) where userId != nil:
                // Most likely identify() ran and setUserToken() has not yet: keep the events for the token.
                // A token set while this request was in flight is tried on the next loop pass.
                if token(for: userId) != request.value(forHTTPHeaderField: "x-herald-user-token") { continue }
                if usersAwaitingToken.isEmpty { Log.warning("Herald needs a user token: call setUserToken") }
                usersAwaitingToken.insert(userId!)
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
    private func batchBody(_ batch: [QueuedEvent], userId: String?, dropped: Int) async -> (Data, [QueuedEvent])? {
        let context = DeviceContext.build(await deviceInfo.current(), collection: configuration.deviceDataCollection)
        var events = batch
        while !events.isEmpty {
            let payload: HeraldValue = [
                "sdk": ["name": .string(Self.sdkName), "version": .string(Herald.sdkVersion)],
                "deviceId": .string(state.deviceId),
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
        var request = URLRequest(url: components?.url ?? configuration.endpoint.appendingPathComponent(path))
        request.setValue(configuration.appKey, forHTTPHeaderField: "x-herald-app-key")
        if let token = token(for: userId) {
            request.setValue(token, forHTTPHeaderField: "x-herald-user-token")
        }
        return request
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

    /// Fetches cards and in-app messages; a 304 keeps the cache.
    func syncMessages() async {
        guard state.enabled else { return }
        guard !isSyncing else {
            // A sync for a possibly different user is in flight: run once more when it finishes.
            resyncRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            resyncRequested = false
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
                persist()
                apply(payload)
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
