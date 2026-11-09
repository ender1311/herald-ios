import Foundation

/// One queued event plus the user it was recorded for, so a batch never mixes users.
struct QueuedEvent: Codable, Equatable {
    let userId: String?
    let event: [String: HeraldValue]

    var id: String { event["id"]?.stringValue ?? "" }
}

/// Disk-backed FIFO of events, one JSON object per line. Appends are O(1); removals rewrite the file
/// atomically. A torn last line (crash mid-append) is skipped on load and the file is rewritten clean.
/// Not thread-safe: owned by `HeraldCore`.
final class EventQueue {
    static let defaultCap = 1000

    private let fileURL: URL
    private let cap: Int
    private(set) var entries: [QueuedEvent] = []

    init(fileURL: URL, cap: Int = EventQueue.defaultCap) {
        self.fileURL = fileURL
        self.cap = cap
        load()
    }

    var count: Int { entries.count }

    /// Appends an event; returns how many of the oldest events were dropped to stay under the cap.
    @discardableResult
    func append(_ entry: QueuedEvent) -> Int {
        guard let line = Self.encodeLine(entry) else {
            // For example a NaN or infinite number in properties.
            Log.error("Skipping an event that cannot be encoded as JSON")
            return 0
        }
        entries.append(entry)
        let overflow = entries.count - cap
        if overflow > 0 {
            entries.removeFirst(overflow)
            rewrite()
            return overflow
        }
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            Log.error("Could not persist event: \(error.localizedDescription)")
        }
        return 0
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        rewrite()
    }

    func removeAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        var sawBadLine = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let entry = try? JSONDecoder().decode(QueuedEvent.self, from: Data(line)) {
                entries.append(entry)
            } else {
                sawBadLine = true
            }
        }
        if sawBadLine || data.last != UInt8(ascii: "\n") || entries.count > cap {
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
            rewrite()
        }
    }

    private func rewrite() {
        var data = Data()
        for entry in entries {
            if let line = Self.encodeLine(entry) { data.append(line) }
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Could not rewrite event queue: \(error.localizedDescription)")
        }
    }

    private static func encodeLine(_ entry: QueuedEvent) -> Data? {
        guard var data = try? JSONEncoder().encode(entry) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
