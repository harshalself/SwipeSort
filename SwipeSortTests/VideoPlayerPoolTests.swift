import Testing
import AVFoundation
@testable import SwipeSort

@MainActor
@Suite("VideoPlayerPool iCloud-cancel")
struct VideoPlayerPoolTests {

    @Test("evicting an LRU slot cancels its in-flight PhotoKit request")
    func evictionCancelsRequestHandle() {
        let pool = VideoPlayerPool.shared
        pool.drain()

        let h1 = MockVideoRequestHandle()
        let h2 = MockVideoRequestHandle()
        let h3 = MockVideoRequestHandle()
        let h4 = MockVideoRequestHandle()

        _ = pool.player(for: id(1), item: item(), requestHandle: h1)
        _ = pool.player(for: id(2), item: item(), requestHandle: h2)
        _ = pool.player(for: id(3), item: item(), requestHandle: h3)

        // Pool is at capacity (3). Inserting a 4th must evict the LRU
        // — id(1), since it was inserted first and never re-touched.
        _ = pool.player(for: id(4), item: item(), requestHandle: h4)

        #expect(h1.isCancelled == true, "evicted slot's request handle must be cancelled")
        #expect(h2.isCancelled == false)
        #expect(h3.isCancelled == false)
        #expect(h4.isCancelled == false)

        pool.drain()
    }

    @Test("drain cancels every retained request handle")
    func drainCancelsAllHandles() {
        let pool = VideoPlayerPool.shared
        pool.drain()

        let h1 = MockVideoRequestHandle()
        let h2 = MockVideoRequestHandle()

        _ = pool.player(for: id(10), item: item(), requestHandle: h1)
        _ = pool.player(for: id(11), item: item(), requestHandle: h2)

        pool.drain()

        #expect(h1.isCancelled == true)
        #expect(h2.isCancelled == true)
    }

    @Test("cache hit does not cancel — LRU is refreshed instead")
    func cacheHitPreservesHandle() {
        let pool = VideoPlayerPool.shared
        pool.drain()

        let h1 = MockVideoRequestHandle()
        _ = pool.player(for: id(20), item: item(), requestHandle: h1)

        // Second call for the same id must return the cached player and leave
        // the handle intact.
        _ = pool.player(for: id(20), item: item(), requestHandle: MockVideoRequestHandle())

        #expect(h1.isCancelled == false, "cache hit must not cancel the original request")

        pool.drain()
    }

    private func id(_ n: Int) -> AssetIdentifier {
        AssetIdentifier("mock-video-\(n)")
    }

    private func item() -> AVPlayerItem {
        // Synthetic URL — the item is never played in these tests, only stored
        // in a pool slot so we can drive eviction / drain paths.
        AVPlayerItem(url: URL(string: "file:///dev/null")!)
    }
}
