import Foundation
import AVFoundation

/// LRU pool of up to three `AVPlayer` instances, one per recently-visible video card.
///
/// LRU eviction policy is chosen deliberately over FIFO: when the user presses
/// Undo and returns to the previous card, that card is still a cache hit. FIFO
/// would evict the just-swiped card, guaranteeing a re-decode on every undo.
///
/// Why `AVPlayer` and not `AVQueuePlayer`: `AVQueuePlayer` does not preload
/// independent items efficiently and stalls on arbitrary seeks, which are common
/// in the swipe-and-return flow.
///
/// Each new player is muted and has `automaticallyWaitsToMinimizeStalling`
/// disabled to prioritise immediate playback over buffering optimality.
/// `preferredForwardBufferDuration` is capped at 5 s so three pooled players
/// hold at most ~15 s of video data rather than unbounded RAM.
///
/// Threading: `@MainActor`-isolated. All `VideoCardView` callers run on the
/// main actor, so the pool's mutable `slots` array is never accessed
/// concurrently.
@MainActor
final class VideoPlayerPool {

    /// The shared pool. One pool per process is sufficient for the swipe deck.
    static let shared = VideoPlayerPool()

    private struct Slot {
        var assetId: AssetIdentifier
        var player: AVPlayer
        var lastTouched: Date
        var requestHandle: VideoRequestHandle?
    }

    private var slots: [Slot] = []
    private let capacity = 3

    private init() {}

    /// Returns the cached `AVPlayer` for `id`, or creates a new one from `item`.
    ///
    /// On cache miss, if the pool is at capacity the least-recently-used slot is
    /// paused, its player item is released, and any in-flight PhotoKit request
    /// for that slot is cancelled via `requestHandle` — this is what releases
    /// iCloud bandwidth still tied to the evicted asset.
    ///
    /// Pass `requestHandle: nil` when there is no PhotoKit request to cancel
    /// (mock/test paths); otherwise pass the handle returned by
    /// `PhotoLibraryProviding.avPlayerItem(for:progressHandler:)`.
    func player(for id: AssetIdentifier, item: AVPlayerItem, requestHandle: VideoRequestHandle?) -> AVPlayer {
        if let idx = slots.firstIndex(where: { $0.assetId == id }) {
            slots[idx].lastTouched = .now
            slots[idx].player.isMuted = true
            return slots[idx].player
        }

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        item.preferredForwardBufferDuration = 5
        item.preferredPeakBitRate = 2_000_000

        if slots.count >= capacity {
            if let evictIdx = slots.enumerated()
                .min(by: { $0.element.lastTouched < $1.element.lastTouched })?.offset {
                let evicted = slots.remove(at: evictIdx)
                evicted.player.pause()
                evicted.requestHandle?.cancel()
                evicted.player.replaceCurrentItem(with: nil)
            }
        }
        slots.append(Slot(assetId: id, player: player, lastTouched: .now, requestHandle: requestHandle))
        return player
    }

    /// Pauses every retained player except the one for `id`. Called when a
    /// new video card becomes visible so we never have two videos playing.
    func pauseAllExcept(_ id: AssetIdentifier) {
        for slot in slots where slot.assetId != id {
            slot.player.pause()
        }
    }

    /// Pauses and evicts all retained players from the pool.
    /// Called when exiting a swipe session to free hardware decoders, AVPlayer
    /// memory, and any in-flight iCloud downloads still tied to a pooled slot.
    func drain() {
        for slot in slots {
            slot.player.pause()
            slot.requestHandle?.cancel()
            slot.player.replaceCurrentItem(with: nil)
        }
        slots.removeAll()
    }
}
