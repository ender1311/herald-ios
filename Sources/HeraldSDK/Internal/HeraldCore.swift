import Foundation

/// Hooks from the core to the main-actor world (card store, in-app delegate and presenter).
protocol CoreOutput: Sendable {
    func cardsChanged(_ cards: [ContentCard]) async
    /// Asks the delegate and hands the message to the presenter. Returns nil when no presenter is set.
    func offer(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) async
        -> InAppMessageDisplayChoice?
}

/// All SDK state lives here. Public calls reach it in order through `Herald`'s command stream;
/// network work runs in child tasks so a slow request never blocks event recording.
actor HeraldCore {
    static let sdkName = "herald-ios"
    static let maxBatchEvents = 100
    static let maxBatchBytes = 512 * 1024

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
    private var heldMessages: [InAppMessage] = []

    private var isFlushing = false
    private var isSyncing = false
    private var resyncRequested = false
    private(set) var failureCount = 0
    private(set) var nextAttemptAt: Date?
    private var isForeground = false
    private var flushTimer: Task<Void, Never>?
    private let bundleId: String
    /// Child tasks (flush, sync, output), tracked so tests can wait for them.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

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
        queue = EventQueue(fileURL: storage.queueURL)
        engine = InAppEngine(minimumInterval: configuration.inAppMinimumInterval)
        engine.lastShown = state.lastShown[state.userId ?? ""] ?? [:]
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

    // MARK: - Identity

    func identify(userId: String, traits: [String: HeraldValue]) {
        guard state.enabled else { return }
        guard !userId.isEmpty, userId.count <= 200 else {
            Log.error("identify: userId must be 1 to 200 characters")
            return
        }
        let previous = state.userId
        if let previous, previous != userId {
            clearUserState()
        }
        state.userId = userId
        engine.lastShown = state.lastShown[userId] ?? [:]
        persist()
        record("identify", ["userId": .string(userId), "traits": .object(Self.validAttributes(traits))])
        if previous == nil {
            // Same session, now identified: fetch this user's messages.
            scheduleSync(thenFire: nil)
        }
        if previous != userId { resendPushToken() }
    }

    func setUserToken(_ token: String?) {
        state.userToken = (token?.isEmpty ?? true) ? nil : token
        persist()
    }

    /// Back to an anonymous user on the same device, with a new session.
    func reset() {
        clearUserState()
        state.userId = nil
        engine.lastShown = state.lastShown[""] ?? [:]
        persist()
        guard state.enabled else { return }
        ensureSession()
        resendPushToken()
    }

    /// Ends the session and forgets the current user's token, cards, messages and re-eligibility.
    private func clearUserState() {
        if let session = state.session {
            if state.enabled { enqueueSessionEnd(session) }
            state.session = nil
        }
        if let userId = state.userId, let token = state.userToken {
            state.pendingTokens[userId] = token
        }
        state.userToken = nil
        state.lastShown[state.userId ?? ""] = nil
        state.dismissedCardIds = []
        state.messagesETag = nil
        storage.saveMessages(nil)
        cards = []
        engine.messages = []
        engine.lastShown = [:]
        heldMessages = []
        publishCards()
    }

    // MARK: - Events

    func track(_ name: String, properties: [String: HeraldValue]) {
        guard state.enabled, Self.validName(name, "track") else { return }
        record("track", ["name": .string(name), "properties": .object(properties)])
        fire(.event(name: name, properties: properties))
    }

    func screen(_ name: String, properties: [String: HeraldValue]) {
        guard state.enabled, Self.validName(name, "screen") else { return }
        record("screen", ["name": .string(name), "properties": .object(properties)])
    }

    func trackPurchase(productId: String, price: Double, currency: String, quantity: Int, properties: [String: HeraldValue]) {
        guard state.enabled, Self.validName(productId, "trackPurchase") else { return }
        let code = currency.uppercased()
        guard code.count == 3, quantity > 0, price.isFinite else {
            Log.error("trackPurchase: currency must be a 3-letter code, quantity positive and price finite")
            return
        }
        record("purchase", [
            "productId": .string(productId), "price": .number(price), "currency": .string(code),
            "quantity": .number(Double(quantity)), "properties": .object(properties),
        ])
    }

    func setAttributes(_ attributes: [String: HeraldValue]) {
        guard state.enabled else { return }
        let valid = Self.validAttributes(attributes)
        guard !valid.isEmpty else { return }
        record("attributes", ["attributes": .object(valid)])
    }

    func setSubscription(_ channel: SubscriptionChannel, _ subscriptionState: SubscriptionState) {
        guard state.enabled else { return }
        record("subscription", ["channel": .string(channel.rawValue), "state": .string(subscriptionState.rawValue)])
    }

    func setPushToken(hex: String) {
        state.pushToken = hex
        persist()
        guard state.enabled else { return }
        enqueuePushToken(hex)
    }

    private func resendPushToken() {
        guard let token = state.pushToken else { return }
        enqueuePushToken(token)
    }

    private func enqueuePushToken(_ token: String) {
        var fields: [String: HeraldValue] = [
            "platform": "apns", "token": .string(token), "environment": .string(PushEnvironment.current),
        ]
        if !bundleId.isEmpty { fields["bundleId"] = .string(bundleId) }
        record("push_token", fields)
    }

    /// The user acted on a Herald push (`open`, `button` or `dismiss`). Opens evaluate `push_open` triggers.
    func pushResponse(messageId: String, decisionId: String?, action: String, buttonId: String?) {
        guard state.enabled else { return }
        logInteraction(messageId: messageId, kind: "push", action: action, decisionId: decisionId, buttonId: buttonId)
        if action != "dismiss" { fire(.pushOpen) }
    }

    // MARK: - Content cards

    func logCardImpression(_ card: ContentCard) {
        updateCard(card.id) { $0.viewed = true }
        logInteraction(messageId: card.id, kind: "content_card", action: "impression", decisionId: card.decisionId, buttonId: nil)
    }

    func logCardClick(_ card: ContentCard) {
        updateCard(card.id) { $0.clicked = true }
        logInteraction(messageId: card.id, kind: "content_card", action: "click", decisionId: card.decisionId, buttonId: nil)
    }

    func logCardDismissal(_ card: ContentCard) {
        state.dismissedCardIds.insert(card.id)
        persist()
        updateCard(card.id) { $0.dismissed = true }
        logInteraction(messageId: card.id, kind: "content_card", action: "dismiss", decisionId: card.decisionId, buttonId: nil)
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
        logInteraction(messageId: message.id, kind: "in_app", action: "impression", decisionId: message.decisionId, buttonId: nil)
    }

    func logMessageClick(_ message: InAppMessage, buttonId: String?) {
        logInteraction(
            messageId: message.id, kind: "in_app", action: buttonId == nil ? "click" : "button",
            decisionId: message.decisionId, buttonId: buttonId
        )
    }

    func logMessageDismissal(_ message: InAppMessage) {
        logInteraction(messageId: message.id, kind: "in_app", action: "dismiss", decisionId: message.decisionId, buttonId: nil)
    }

    /// Evaluates a trigger and, when a message wins, offers it to the delegate and presenter.
    func fire(_ trigger: TriggerEvent) {
        guard state.enabled, let message = engine.evaluate(trigger: trigger, now: now()) else { return }
        engine.isShowing = true  // reserved until the presenter answers, so a second trigger cannot overlap
        spawn { core in await core.offer(message) }
    }

    /// Shows the next message the delegate held with `.later`.
    func showNext() {
        guard state.enabled, !engine.isShowing else { return }
        let date = now()
        heldMessages.removeAll { message in !engine.messages.contains { $0.id == message.id } || !engine.isEligible(message, now: date) }
        guard !heldMessages.isEmpty else { return }
        let message = heldMessages.removeFirst()
        engine.isShowing = true
        spawn { core in await core.offer(message) }
    }

    private func offer(_ message: InAppMessage) async {
        let messageId = message.id
        let choice = await output.offer(message) { [weak self] in
            Task { await self?.messageClosed(id: messageId) }
        }
        switch choice {
        case .display:
            engine.recordDisplay(message, now: now())
            state.lastShown[state.userId ?? "", default: [:]][message.id] = now()
            persist()
            logMessageImpression(message)
        case .later:
            engine.isShowing = false
            if !heldMessages.contains(where: { $0.id == message.id }) { heldMessages.append(message) }
        case .discard:
            engine.isShowing = false
        case nil:
            engine.isShowing = false
            Log.info("No in-app presenter set; message \(message.id) not shown")
        }
    }

    func messageClosed(id: String) {
        engine.isShowing = false
    }

    // MARK: - Recording

    private func logInteraction(messageId: String, kind: String, action: String, decisionId: String?, buttonId: String?) {
        guard state.enabled, !messageId.isEmpty else { return }
        var fields: [String: HeraldValue] = [
            "messageId": .string(messageId), "kind": .string(kind), "action": .string(action),
        ]
        if let decisionId { fields["decisionId"] = .string(decisionId) }
        if let buttonId { fields["buttonId"] = .string(buttonId) }
        record("interaction", fields)
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
                persist()
                return
            }
            enqueueSessionEnd(session)
        }
        let session = SessionState(id: String(Int64(date.timeIntervalSince1970 * 1000)), startedAt: date, lastActivityAt: date)
        state.session = session
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
    }

    func appDidEnterBackground() async {
        isForeground = false
        flushTimer?.cancel()
        flushTimer = nil
        if var session = state.session {
            session.lastActivityAt = now()
            state.session = session
            persist()
        }
        await flushNow()
    }

    private func startFlushTimer() {
        flushTimer?.cancel()
        let interval = configuration.flushInterval
        flushTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.flushNow()
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
        state = PersistedState(deviceId: UUID().uuidString.lowercased())
        state.enabled = false
        cards = []
        engine = InAppEngine(minimumInterval: configuration.inAppMinimumInterval)
        heldMessages = []
        failureCount = 0
        nextAttemptAt = nil
        persist()
        publishCards()
    }

    private func persist() { storage.saveState(state) }

    private func spawn(_ work: @escaping @Sendable (isolated HeraldCore) async -> Void) {
        let id = UUID()
        // The task runs on this actor only after the current call returns, so the entry exists before removal.
        inFlight[id] = Task {
            await work(self)
            self.inFlight[id] = nil
        }
    }

    /// Waits until every child task (and any task they started) has finished.
    func drain() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    // MARK: - Flush

    func scheduleFlush() {
        spawn { core in await core.flushNow() }
    }

    /// Sends queued events in batches until the queue is empty, a batch must be retried, or the SDK is disabled.
    func flushNow() async {
        guard state.enabled, !isFlushing else { return }
        if let nextAttemptAt, now() < nextAttemptAt { return }
        isFlushing = true
        defer { isFlushing = false }

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

    /// The oldest run of events for one user, up to 100. Anonymous events may lead into the identified
    /// run that follows them (that is the identify), but events never cross from one user to another
    /// or from a user back to anonymous.
    func nextBatch() -> (events: [QueuedEvent], userId: String?) {
        var batch: [QueuedEvent] = []
        var batchUser: String?
        for entry in queue.entries {
            if batch.count == Self.maxBatchEvents { break }
            if let user = entry.userId {
                if batchUser == nil {
                    batchUser = user
                } else if batchUser != user {
                    break
                }
            } else if batchUser != nil {
                break
            }
            batch.append(entry)
        }
        return (batch, batchUser)
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

    private func scheduleSync(thenFire trigger: TriggerEvent?) {
        spawn { core in
            await core.syncMessages()
            if let trigger { core.fire(trigger) }
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

    private func apply(_ payload: MessagesPayload) {
        cards = payload.contentCards
        engine.messages = payload.inAppMessages
        // Forget local dismissals the server no longer returns.
        let ids = Set(cards.map(\.id))
        state.dismissedCardIds = state.dismissedCardIds.filter { ids.contains($0) }
        publishCards()
    }

    // MARK: - Validation

    private static func validName(_ name: String, _ call: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else {
            Log.error("\(call): name must be 1 to 255 characters")
            return false
        }
        return true
    }

    static let reservedAttributes: Set<String> = ["$email", "$phone"]

    /// Keeps attributes the server accepts: keys 1–255 chars, values string, number, bool, null or
    /// string array; `$` keys only for the reserved `$email` / `$phone`, which must look valid,
    /// because one invalid attribute makes the server reject the whole batch.
    static func validAttributes(_ attributes: [String: HeraldValue]) -> [String: HeraldValue] {
        var valid: [String: HeraldValue] = [:]
        for (key, value) in attributes {
            guard !key.isEmpty, key.count <= 255 else {
                Log.error("Attribute key must be 1 to 255 characters; skipped")
                continue
            }
            if key.hasPrefix("$"), !reservedAttributes.contains(key), !internalAttributes.contains(key) {
                Log.error("Attribute \(key): keys starting with $ are reserved; skipped")
                continue
            }
            switch value {
            case .string, .number, .bool, .null: break
            case .array(let items) where items.allSatisfy({ $0.stringValue != nil }): break
            default:
                Log.error("Attribute \(key): values must be string, number, bool, null or an array of strings; skipped")
                continue
            }
            if key == "$email", !isValidEmail(value.stringValue) {
                Log.error("Attribute $email is not a valid email; skipped")
                continue
            }
            if key == "$phone", !isValidPhone(value.stringValue) {
                Log.error("Attribute $phone must be an E.164 number such as +15551234567; skipped")
                continue
            }
            valid[key] = value
        }
        return valid
    }

    /// Location attributes written by `setLocation`.
    static let internalAttributes: Set<String> = ["$latitude", "$longitude"]

    static func isValidEmail(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces) else { return false }
        return value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    static func isValidPhone(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil
    }
}
