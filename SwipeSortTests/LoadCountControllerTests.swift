import Testing
import Foundation
import UIKit
@testable import SwipeSort

@Suite("LoadCountController")
@MainActor
struct LoadCountControllerTests {

    @Test("refresh does not eagerly fetch identifiers")
    func noEagerIdentifierFetch() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.totalCount == 10_000)
        #expect(controller.hasIndexed == true)
        #expect(controller.generation == 1)
        #expect(mock.identifiersCallRanges.isEmpty,
                "loadCount() must not call identifiers(in:) — the grid resolves per-cell on demand")
    }

    @Test("each refresh bumps generation by exactly one")
    func generationIncrementsPerRefresh() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 100)
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)
        await controller.refresh(from: mock, filter: .unfiltered)
        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.generation == 3)
    }

    @Test("refresh does not bump generation when fetch result unchanged")
    func doesNotBumpGenerationWhenFetchUnchanged() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 100)
        let controller = LoadCountController()

        // First refresh is a cold start — generation bumps to 1 to unblock
        // the initial render.
        await controller.refresh(from: mock, filter: .unfiltered)
        #expect(controller.generation == 1)

        // Subsequent refreshes where the library reports "nothing changed"
        // must leave generation alone so on-screen cells don't re-resolve.
        mock.nextRefreshReturnsChanged = false
        await controller.refresh(from: mock, filter: .unfiltered)
        mock.nextRefreshReturnsChanged = false
        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.generation == 1,
                "generation must not advance when refreshFetchResult() reports no change")
    }

    @Test("refresh requests authorization when notDetermined")
    func requestsAuthorizationWhenNotDetermined() async {
        let mock = MockPhotoLibrary(authorization: .notDetermined, assetCount: 5)
        mock.nextAuthorizationDecision = .authorized
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.totalCount == 5)
        let auth = await mock.currentAuthorization()
        #expect(auth == .authorized)
    }
}
