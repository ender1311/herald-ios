import Foundation

/// HTTP seam: production uses URLSession, tests inject a fake.
protocol HeraldTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HeraldTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// How a batch response is handled.
enum BatchOutcome: Equatable {
    case accepted
    /// Retrying will not help (400, 401, 413, other 4xx): drop the batch.
    case rejected(status: Int)
    /// 408, 429, 5xx or a network error: keep the batch and retry after `delay` seconds.
    case retry(delay: TimeInterval)
}

enum Backoff {
    static let base: TimeInterval = 1
    static let cap: TimeInterval = 300

    /// Exponential backoff with jitter: attempt 1 → 0.5–1 s, 2 → 1–2 s, … capped at 300 s.
    /// `random` is in 0...1; the delay is `exp * (0.5 + 0.5 * random)`.
    static func delay(attempt: Int, random: Double) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 20)
        let full = min(cap, base * pow(2, Double(exponent)))
        return full * (0.5 + 0.5 * min(max(random, 0), 1))
    }

    /// Seconds from a `Retry-After` header (delta-seconds or HTTP date), else the body's `retryAfterSeconds`.
    static func retryAfter(_ response: HTTPURLResponse, body: Data, now: Date) -> TimeInterval? {
        if let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) {
            if let seconds = TimeInterval(header), seconds >= 0 { return min(seconds, 3600) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return min(max(date.timeIntervalSince(now), 0), 3600) }
        }
        if let object = try? JSONDecoder().decode(HeraldValue.self, from: body).objectValue,
            let seconds = object["retryAfterSeconds"]?.numberValue, seconds >= 0
        {
            return min(seconds, 3600)
        }
        return nil
    }

    static func outcome(status: Int, response: HTTPURLResponse, body: Data, attempt: Int, random: Double, now: Date)
        -> BatchOutcome
    {
        switch status {
        case 200..<300:
            return .accepted
        case 408, 429, 500...599:
            let backoff = delay(attempt: attempt, random: random)
            return .retry(delay: retryAfter(response, body: body, now: now) ?? backoff)
        default:
            return .rejected(status: status)
        }
    }
}

/// `GET /api/v1/sdk/messages` response body (`{ "data": { … } }`). Malformed items are skipped.
struct MessagesPayload {
    var syncedAt: Date?
    var contentCards: [ContentCard]
    var inAppMessages: [InAppMessage]

    static let empty = MessagesPayload(syncedAt: nil, contentCards: [], inAppMessages: [])

    static func decode(_ data: Data) throws -> MessagesPayload {
        try JSONDecoder().decode(Envelope.self, from: data).data.payload
    }

    private struct Envelope: Decodable { let data: Body }

    private struct Body: Decodable {
        let payload: MessagesPayload

        private enum CodingKeys: String, CodingKey { case syncedAt, contentCards, inAppMessages }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            payload = MessagesPayload(
                syncedAt: c.lenientDate(.syncedAt),
                contentCards: (c.lenient([Lossy<ContentCard>].self, .contentCards) ?? []).compactMap(\.value),
                inAppMessages: (c.lenient([Lossy<InAppMessage>].self, .inAppMessages) ?? []).compactMap(\.value)
            )
        }
    }
}
