import SwiftUI
import AVKit

/// A card view that autoplays a video asset muted while the card is visible.
///
/// Delegates `AVPlayer` lifecycle to `VideoPlayerPool.shared` so at most
/// three hardware decoders are live at any time. Pauses when the card
/// disappears or when another video card calls `pauseAllExcept`.
///
/// Threading: relies on `VideoPlayerPool` being `@MainActor`-isolated;
/// all `player` access happens from `body` and its subview modifiers, which
/// run on the main actor.
struct VideoCardView: View {
    let assetId: AssetIdentifier
    let library: PhotoLibraryProviding
    let thumbnail: AssetThumbnail?
    var autoplay: Bool = true

    @State private var player: AVPlayer?
    @State private var isVideoVisible = false

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(.secondarySystemBackground)
            }

            if let player {
                VideoPlayer(player: player)
                    .opacity(isVideoVisible ? 1 : 0)
                    .onAppear {
                        VideoPlayerPool.shared.pauseAllExcept(assetId)
                        if autoplay {
                            player.isMuted = true
                            player.play()
                        } else {
                            player.isMuted = false
                            player.pause()
                        }
                        
                        // Give the hardware decoder a brief moment to render the first frame
                        // before cross-fading over the static thumbnail.
                        withAnimation(.easeIn(duration: 0.25).delay(0.05)) {
                            isVideoVisible = true
                        }
                    }
                    .onDisappear { player.pause() }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in
                        player.seek(to: .zero)
                        if autoplay {
                            player.play()
                        }
                    }
            }
        }
        .task(id: assetId) {
            // The handle lets `VideoPlayerPool` release in-flight iCloud
            // bandwidth when the slot is later evicted. The thumbnail is
            // already visible behind the player, so no progress spinner is
            // needed here.
            let (item, handle) = await library.avPlayerItem(for: assetId, progressHandler: nil)
            if let item {
                player = VideoPlayerPool.shared.player(for: assetId, item: item, requestHandle: handle)
            } else {
                handle?.cancel()
            }
        }
    }
}
