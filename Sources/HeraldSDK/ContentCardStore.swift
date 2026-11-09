import Combine
import Foundation

/// The current user's content cards: unexpired and not dismissed, in server order.
/// Observe it from SwiftUI (`@ObservedObject var store = Herald.shared.contentCards`) or iterate
/// `updates` from any async context.
@MainActor
public final class ContentCardStore: ObservableObject {
    @Published public private(set) var cards: [ContentCard] = []

    private var continuations: [UUID: AsyncStream<[ContentCard]>.Continuation] = [:]

    nonisolated init() {}

    /// A stream that yields the current cards immediately, then every change.
    public var updates: AsyncStream<[ContentCard]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ContentCard].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(cards)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    func update(_ cards: [ContentCard]) {
        guard cards != self.cards else { return }
        self.cards = cards
        for continuation in continuations.values { continuation.yield(cards) }
    }
}
