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

#if os(iOS)
import AVKit
import SwiftUI

extension EnvironmentValues {
    /// How much of the card is on screen (0...1). `ContentCardFeed` sets it for cards with an autoplay
    /// video; elsewhere it stays 0, so autoplay never starts.
    @Entry var heraldVisibleFraction: CGFloat = 0
}

/// A video in a card or in-app message: the poster with a centered play button; a tap plays it inline
/// with sound and the standard controls. With `autoplay`, it plays muted and looped while at least half
/// visible (paused otherwise, and never under Reduce Motion). `onPlay` runs when playback first starts
/// and `onComplete` when it first reaches the end.
struct HeraldVideoView: View {
    let url: URL
    let posterUrl: URL?
    let aspectRatio: CGFloat
    var autoplay = false
    let onPlay: () -> Void
    let onComplete: () -> Void

    @Environment(\.heraldVisibleFraction) private var visibleFraction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var tapped = false
    @State private var played = false
    @State private var completed = false

    var body: some View {
        let shouldAutoplay = VideoAutoplay.shouldPlay(visibleFraction: visibleFraction, autoplay: autoplay, reduceMotion: reduceMotion)
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
                        guard let item = note.object as? AVPlayerItem, item === player.currentItem, !completed else { return }
                        completed = true
                        onComplete()
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

    private func playWithSound() {
        tapped = true
        let player = self.player ?? AVQueuePlayer(url: url)
        looper = nil
        player.isMuted = false
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
        guard !played else { return }
        played = true
        onPlay()
    }
}
#endif
