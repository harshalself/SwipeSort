import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("SwipeSessionModel.commitDecisions")
struct CommitDeletionsTests {

    private let targetSize = CGSize(width: 300, height: 400)

    @Test("pendingDeletions collects only .delete decisions in order")
    func pendingDeletionsCollected() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeDelete()
        await m.swipeFavorite()
        await m.swipeDelete()

        #expect(m.pendingDeletions.count == 2)
        #expect(m.pendingDeletions[0].rawValue == "mock-asset-0")
        #expect(m.pendingDeletions[1].rawValue == "mock-asset-2")
    }

    @Test("commitDecisions returns success and forwards batch to library")
    func commitSuccess() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        await m.swipeDelete()
        await m.swipeDelete()

        let result = await m.commitDecisions()
        #expect(result == .success(affectedCount: 2))
        #expect(mock.lastCommittedDeletions.count == 2)
    }

    @Test("commitDecisions with cancellation preserves the queue")
    func commitCancelled() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.nextCommitResult = .cancelledByUser
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        await m.swipeDelete()

        let result = await m.commitDecisions()
        #expect(result == .cancelledByUser)
        #expect(m.pendingDeletions.count == 1)
    }

    @Test("empty deletion queue returns success(0) without hitting library")
    func emptyBatch() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        await m.swipeFavorite()

        let result = await m.commitDecisions()
        #expect(result == .success(affectedCount: 0))
        #expect(mock.lastCommittedDeletions.isEmpty)
    }
}
