import Foundation

/// When a card's video plays on its own, and the play button's VoiceOver label.
enum VideoAutoplay {
    static let playButtonLabel = "Play video"

    /// Muted autoplay runs only for a card with `videoAutoplay`, while at least half of it is visible,
    /// and never with Reduce Motion on.
    static func shouldPlay(visibleFraction: CGFloat, autoplay: Bool, reduceMotion: Bool) -> Bool {
        autoplay && !reduceMotion && visibleFraction >= 0.5
    }
}

/// Decides when a video's `video_play` and `video_complete` go out: one of each per play. A play starts
/// on a tap, an autoplay start, or a replay from the controls after the end; it completes when an item
/// the view created reaches its end. A loop or a resume after pausing is not a new play.
struct VideoPlayEvents {
    private(set) var playing = false

    /// True when this start begins a new play (log `video_play`).
    mutating func started() -> Bool {
        guard !playing else { return false }
        playing = true
        return true
    }

    /// True when the end belongs to this view's play in progress (log `video_complete`).
    mutating func ended(ownItem: Bool) -> Bool {
        guard ownItem, playing else { return false }
        playing = false
        return true
    }
}

#if os(iOS)
import AVKit
import SwiftUI

extension EnvironmentValues {
    /// How much of the card is on screen (0...1). `ContentCardFeed` sets it for cards with an autoplay
    /// video; elsewhere it stays 0, so autoplay never starts.
    @Entry var heraldVisibleFraction: CGFloat = 0
}

/// A video in a card or in-app message: the poster with a centered play button; a tap plays it inline
/// with sound and the standard controls, pausing on the last frame at the end (replay from the controls).
/// With `autoplay`, it plays muted and looped while at least half visible (paused otherwise, and never
/// under Reduce Motion). `onPlay` and `onComplete` run once per play (see `VideoPlayEvents`).
struct HeraldVideoView: View {
    let url: URL
    let posterUrl: URL?
    let aspectRatio: CGFloat
    var autoplay = false
    let onPlay: () -> Void
    let onComplete: () -> Void

    @Environment(\.heraldVisibleFraction) private var visibleFraction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    /// The item a tap created; the looper keeps its own replicas.
    @State private var tappedItem: AVPlayerItem?
    @State private var looper: AVPlayerLooper?
    @State private var tapped = false
    @State private var events = VideoPlayEvents()

    var body: some View {
        let shouldAutoplay = VideoAutoplay.shouldPlay(visibleFraction: visibleFraction, autoplay: autoplay, reduceMotion: reduceMotion)
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .onReceive(
                        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main)
                    ) { note in
                        guard let item = note.object as? AVPlayerItem else { return }
                        if events.ended(ownItem: isOwn(item)) { onComplete() }
                    }
                    .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
                        // A replay from the controls after the end starts a new play.
                        if status == .playing { started() }
                    }
            } else {
                HeraldImage(url: posterUrl, aspectRatio: aspectRatio)
                Button(action: playWithSound) {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(VideoAutoplay.playButtonLabel))
            }
        }
        .onChange(of: shouldAutoplay) { updateAutoplay($0) }
        .onAppear { updateAutoplay(shouldAutoplay) }
        .onDisappear { player?.pause() }
    }

    private func isOwn(_ item: AVPlayerItem) -> Bool {
        item === tappedItem || (looper?.loopingPlayerItems.contains { $0 === item } ?? false)
    }

    /// The poster's play button: a plain player that pauses on the last frame, so it can be replayed.
    private func playWithSound() {
        tapped = true
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        tappedItem = item
        self.player = player
        player.play()
        started()
    }

    /// Starts or pauses the muted loop; a video the user started is left to its controls.
    private func updateAutoplay(_ shouldPlay: Bool) {
        guard !tapped else { return }
        if shouldPlay {
            if player == nil {
                let queue = AVQueuePlayer()
                queue.isMuted = true
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                player = queue
            }
            player?.play()
            started()
        } else {
            player?.pause()
        }
    }

    private func started() {
        if events.started() { onPlay() }
    }
}
#endif
