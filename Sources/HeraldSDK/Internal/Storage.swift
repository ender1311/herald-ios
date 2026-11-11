import Foundation

struct SessionState: Codable, Equatable {
    var id: String
    var startedAt: Date
    var lastActivityAt: Date
}

/// Everything the SDK keeps between launches, except the event queue and the message cache.
struct PersistedState: Codable, Equatable {
    var deviceId: String
    var userId: String?
    var userToken: String?
    /// Tokens of previous users whose events are still queued; pruned after each flush.
    var pendingTokens: [String: String] = [:]
    /// Events dropped by the queue cap, reported on the next successful batch.
    var dropped: Int = 0
    var enabled: Bool = true
    var session: SessionState?
    /// In-app re-eligibility: user id (or "anonymous") → message id → last shown. Survives reset and
    /// user switches; only `wipeData()` clears it.
    var lastShown: [String: [String: Date]] = [:]
    /// When the last in-app message was displayed: the minimum-interval clock.
    var lastDisplayAt: Date?
    /// Triggered in-app messages that could not show yet, oldest first.
    var pendingMessageIds: [String] = []
    /// Cards dismissed on this device that the server may not have seen yet.
    var dismissedCardIds: Set<String> = []
    var messagesETag: String?
    var pushToken: String?
    /// A push subscription change recorded before any APNs token existed; sent right after the token.
    var deferredPushSubscription: SubscriptionState?
    /// Decision ids of recently opened pushes (newest last, capped), so a redelivered open counts once.
    var recentPushOpens: [String] = []
    /// Cards whose impression this session already logged; cleared when a session starts.
    var impressedCardIds: Set<String> = []

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, userId, userToken, pendingTokens, dropped, enabled, session, lastShown, lastDisplayAt
        case pendingMessageIds, dismissedCardIds, messagesETag, pushToken, deferredPushSubscription, recentPushOpens
        case impressedCardIds
    }

    /// Every field but the device id is optional, so state written by an older SDK version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        userId = c.lenient(String.self, .userId)
        userToken = c.lenient(String.self, .userToken)
        pendingTokens = c.lenient([String: String].self, .pendingTokens) ?? [:]
        dropped = c.lenient(Int.self, .dropped) ?? 0
        enabled = c.lenient(Bool.self, .enabled) ?? true
        session = c.lenient(SessionState.self, .session)
        lastShown = c.lenient([String: [String: Date]].self, .lastShown) ?? [:]
        lastDisplayAt = c.lenient(Date.self, .lastDisplayAt)
        pendingMessageIds = c.lenient([String].self, .pendingMessageIds) ?? []
        dismissedCardIds = c.lenient(Set<String>.self, .dismissedCardIds) ?? []
        messagesETag = c.lenient(String.self, .messagesETag)
        pushToken = c.lenient(String.self, .pushToken)
        deferredPushSubscription = c.lenient(SubscriptionState.self, .deferredPushSubscription)
        recentPushOpens = c.lenient([String].self, .recentPushOpens) ?? []
        impressedCardIds = c.lenient(Set<String>.self, .impressedCardIds) ?? []
    }
}

/// Files under Application Support/Herald (or a test directory). All writes are atomic.
struct Storage {
    let directory: URL

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Herald", isDirectory: true)
    }

    init(directory: URL) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Log.error("Could not create storage directory: \(error.localizedDescription)")
        }
    }

    var queueURL: URL { directory.appendingPathComponent("events.jsonl") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var messagesURL: URL { directory.appendingPathComponent("messages.json") }
    /// The opt-out lives in its own marker file (as on Android), so an unreadable state.json can never
    /// re-enable a disabled SDK.
    private var disabledMarkerURL: URL { Self.disabledMarkerURL(in: directory) }
    private static func disabledMarkerURL(in directory: URL) -> URL { directory.appendingPathComponent("state.json.disabled") }

    var isDisabledMarked: Bool { Self.isDisabledMarked(in: directory) }

    /// One `stat`, no directory creation: safe and cheap from any thread.
    static func isDisabledMarked(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: disabledMarkerURL(in: directory).path)
    }

    func loadState() -> PersistedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func saveState(_ state: PersistedState) {
        if state.enabled {
            try? FileManager.default.removeItem(at: disabledMarkerURL)
        } else if !isDisabledMarked, !FileManager.default.createFile(atPath: disabledMarkerURL.path, contents: Data()) {
            Log.error("Could not save the opt-out marker")
        }
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.error("Could not save state: \(error.localizedDescription)")
        }
    }

    func loadMessages() -> Data? { try? Data(contentsOf: messagesURL) }

    func saveMessages(_ data: Data?) {
        guard let data else {
            try? FileManager.default.removeItem(at: messagesURL)
            return
        }
        do {
            try data.write(to: messagesURL, options: .atomic)
        } catch {
            Log.error("Could not cache messages: \(error.localizedDescription)")
        }
    }

    /// Keeps the opt-out marker: a wipe leaves the SDK disabled.
    func wipe() {
        for url in [queueURL, stateURL, messagesURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
