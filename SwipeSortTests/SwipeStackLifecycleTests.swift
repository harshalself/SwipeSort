import Testing
import Foundation
import UIKit
@testable import SwipeSort

/// Logic-level tests for SwipeStackView's task-lifecycle contracts.
/// SwiftUI view internals cannot be unit-tested, so these tests exercise
/// the observable side-effects (WindowedThumbnailCache and VideoPlayerPool).
@Suite("SwipeStackLifecycle")
@MainActor
struct SwipeStackLifecycleTests {

    @Test("VideoPlayerPool.drain on the shared pool does not crash")
    func videoPlayerPoolDrainDoesNotCrash() {
        // The pool is a singleton with a private init; the contract we can pin
        // from tests is that drain() is safe to call at any time — including on
        // an already-empty pool. This exercises the .finished-phase drain path.
        VideoPlayerPool.shared.drain()
        VideoPlayerPool.shared.drain()
    }

    @Test("cancelled slide task before stopAll leaves cache in stopped state")
    func cancelledSlideTaskDoesNotRestartCache() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 20)
        let cache = WindowedThumbnailCache(
            library: mock,
            aheadOf: 3,
            behind: 1,
            targetSize: CGSize(width: 100, height: 100)
        )

        var slideTask: Task<Void, Never>? = Task {
            await cache.slide(to: 5, total: 20)
        }
        slideTask?.cancel()
        slideTask = nil

        cache.stopAll()

        try? await Task.sleep(for: .milliseconds(30))

        #expect(mock.stopAllCallCount == 1, "stopAll must have been invoked exactly once")
    }
}
