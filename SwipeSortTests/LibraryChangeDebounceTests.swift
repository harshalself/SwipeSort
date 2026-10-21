import Testing
import Foundation
@testable import SwipeSort

/// Validates the debounce contract used by the three onReceive handlers in
/// RecentsView, AlbumsView, and AlbumGridView. The pattern is exercised
/// directly (SwiftUI view internals cannot be unit-tested), so this test
/// anchors the cancel-and-respawn semantics.
@Suite("LibraryChangeDebounce")
struct LibraryChangeDebounceTests {

    @Test("rapid notifications coalesce into exactly one load call")
    func rapidNotificationsCoalesce() async {
        let callCount = Counter()
        var currentTask: Task<Void, Never>? = nil

        for _ in 0..<10 {
            currentTask?.cancel()
            currentTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await callCount.increment()
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        let final = await callCount.value
        #expect(final == 1,
            "10 rapid notifications must coalesce into exactly 1 load call, got \(final)")
    }

    @Test("two separate bursts produce two load calls")
    func separateBurstsProduceTwoCalls() async {
        let callCount = Counter()
        var currentTask: Task<Void, Never>? = nil

        for _ in 0..<5 {
            currentTask?.cancel()
            currentTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await callCount.increment()
            }
        }
        try? await Task.sleep(for: .milliseconds(120))

        for _ in 0..<5 {
            currentTask?.cancel()
            currentTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await callCount.increment()
            }
        }
        try? await Task.sleep(for: .milliseconds(120))

        let final = await callCount.value
        #expect(final == 2,
            "Two separate bursts must each fire exactly one load call, got \(final)")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
