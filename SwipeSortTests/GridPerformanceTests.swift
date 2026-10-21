import XCTest
import Testing
@testable import SwipeSort

// MARK: - Performance Benchmarks (XCTestCase)

@MainActor
final class GridPerformanceBenchmarks: XCTestCase {

    /// Measures the speed and CPU/Memory efficiency of batch resolving 10,000 asset identifiers.
    /// In our zero-lag architecture, this occurs once on grid appear instead of per-cell lookups.
    func testBatchIdentifierLookupPerformance() {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            let exp = expectation(description: "Batch lookup")
            Task {
                let _ = await mock.identifiers(in: 0..<10_000)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5.0)
        }
    }

    /// Simulates rapid ProMotion 120 FPS scrolling through 5,000 grid items,
    /// firing `onAppear` and `onDisappear` continuously on `GridScrollTracker`.
    /// Benchmarks that visible index tracking and window sliding take sub-millisecond clock/CPU time
    /// without parent view `@State` thrashing or memory bloat.
    func testGridScrollTrackerFastScrollPerformance() {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)
        let cache = WindowedThumbnailCache(library: mock, targetSize: CGSize(width: 200, height: 200))
        let tracker = GridScrollTracker(cache: cache)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            // Simulate swiping rapidly from index 0 to 5,000 where 18 cells (6 rows of 3) are visible at a time.
            for i in 0..<5_000 {
                tracker.onAppear(index: i + 18, total: 10_000)
                if i >= 18 {
                    tracker.onDisappear(index: i, total: 10_000)
                }
            }
        }
    }

    /// Measures the speed and memory footprint of switching filters on a large 10,000-item library.
    func testFilterSwitchingPerformance() {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)
        let controller = LoadCountController()
        let favFilter = SwipeFilter(selectedMediaTypes: [.favorites])

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            let exp = expectation(description: "Filter refresh")
            Task {
                await controller.refresh(from: mock, filter: favFilter)
                await controller.refresh(from: mock, filter: .unfiltered)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5.0)
        }
    }

    /// Benchmarks lookahead window sliding and cache eviction under extreme virtual scroll jumps across 10,000 items.
    func testWindowedCacheEvictionPerformance() {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)
        let cache = WindowedThumbnailCache(library: mock, targetSize: CGSize(width: 200, height: 200))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            let exp = expectation(description: "Window sliding")
            Task {
                await cache.slide(to: 1_000, total: 10_000)
                await cache.slide(to: 5_000, total: 10_000)
                await cache.slide(to: 9_000, total: 10_000)
                await cache.slide(to: 500, total: 10_000)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5.0)
        }
    }
}

// MARK: - Scroll Debouncing Verification (Swift Testing)

@Suite("GridScrollTracker Debouncing & Performance Invariants")
@MainActor
struct GridScrollTrackerDebouncingTests {

    @Test("checkSlide debounces window adjustments until crossing 3-row threshold")
    func testScrollDebouncingUnderRapidScroll() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)
        let cache = WindowedThumbnailCache(library: mock, targetSize: CGSize(width: 200, height: 200))
        let tracker = GridScrollTracker(cache: cache)

        // Initial slide at index 0
        tracker.onAppear(index: 0, total: 10_000)
        await Task.yield() // Allow initial slide task to start

        let initialSlideCalls = mock.startCachingCalls.count

        // Scrolling forward by 1 or 2 indices (within the same row / threshold < 3)
        // must NOT trigger any new slide calls, preventing high-frequency cache thrashing.
        tracker.onAppear(index: 1, total: 10_000)
        tracker.onDisappear(index: 0, total: 10_000)
        tracker.onAppear(index: 2, total: 10_000)
        tracker.onDisappear(index: 1, total: 10_000)
        await Task.yield()

        #expect(mock.startCachingCalls.count == initialSlideCalls,
                "Sliding fewer than 3 indices must be debounced and trigger zero new caching requests")

        // Once we shift by >= 3 indices (a full row or more), checkSlide must trigger exactly one adjustment.
        tracker.onAppear(index: 3, total: 10_000)
        tracker.onDisappear(index: 2, total: 10_000)
        await Task.yield()
        // Wait a tiny bit for the async Task in checkSlide to execute
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(mock.startCachingCalls.count > initialSlideCalls,
                "Crossing the 3-row threshold must trigger the lookahead window slide")
    }
}
