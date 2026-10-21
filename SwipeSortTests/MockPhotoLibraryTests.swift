import Testing
import UIKit
@testable import SwipeSort

@Suite("MockPhotoLibrary")
@MainActor
struct MockPhotoLibraryTests {

    @Test("reports authorization state set by test")
    func authorizationIsScriptable() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 0)
        let auth = await mock.currentAuthorization()
        #expect(auth == .authorized)
    }

    @Test("requestAuthorization returns pre-scripted decision")
    func requestReturnsScriptedDecision() async {
        let mock = MockPhotoLibrary(authorization: .notDetermined, assetCount: 0)
        mock.nextAuthorizationDecision = .authorized
        let decision = await mock.requestAuthorization()
        #expect(decision == .authorized)
        let current = await mock.currentAuthorization()
        #expect(current == .authorized)
    }

    @Test("assetCount matches injected value")
    func assetCountMatchesInjection() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 42)
        let n = await mock.assetCount()
        #expect(n == 42)
    }

    @Test("assetIdentifier is stable per index")
    func identifiersAreStable() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let a = await mock.assetIdentifier(at: 0)
        let b = await mock.assetIdentifier(at: 0)
        #expect(a == b)
        #expect(a != nil)
    }

    @Test("out-of-range index returns nil")
    func outOfRangeReturnsNil() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let x = await mock.assetIdentifier(at: 999)
        #expect(x == nil)
    }

    @Test("thumbnail returns non-nil for known identifier")
    func thumbnailForKnownIdentifier() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let id = await mock.assetIdentifier(at: 0)!
        let thumb = await mock.thumbnail(for: id, targetSize: CGSize(width: 100, height: 100))
        #expect(thumb != nil)
        #expect(thumb?.identifier == id)
    }

    @Test("commitDeletions records the batch and returns success")
    func commitRecordsBatch() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let ids = [AssetIdentifier("a"), AssetIdentifier("b")]
        let result = await mock.commitDeletions(ids)
        #expect(result == .success(affectedCount: 2))
        #expect(mock.lastCommittedDeletions == ids)
    }

    @Test("commitDeletions honors scripted cancel")
    func commitScriptedCancel() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.nextCommitResult = .cancelledByUser
        let result = await mock.commitDeletions([AssetIdentifier("x")])
        #expect(result == .cancelledByUser)
    }

    // MARK: - v0.4 albums

    @Test("userAlbums returns seeded list")
    func listsAlbums() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([
            UserAlbum(id: "alb-a", title: "Family", assetCount: 10, canAdd: true),
            UserAlbum(id: "alb-b", title: "Screenshots", assetCount: 500, canAdd: false),
        ])
        let albums = await mock.userAlbums()
        #expect(albums.count == 2)
        #expect(albums.first?.title == "Family")
    }

    @Test("createUserAlbum appends and returns the new album")
    func createAlbum() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 0)
        let created = await mock.createUserAlbum(title: "Trips")
        #expect(created?.title == "Trips")
        let listed = await mock.userAlbums()
        #expect(listed.count == 1)
        #expect(listed.first?.title == "Trips")
    }

    @Test("moveAssets from All Photos records add-only and returns success")
    func moveFromAllPhotos() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "alb-a", title: "Family", assetCount: 0, canAdd: true)])
        let r = await mock.moveAssets([AssetIdentifier("x")], fromAlbumId: nil, toAlbumId: "alb-a")
        #expect(r == .success(affectedCount: 1))
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastMoves[0].from == nil)
        #expect(mock.lastMoves[0].to == "alb-a")
        #expect(mock.lastMoves[0].ids == [AssetIdentifier("x")])
    }

    @Test("moveAssets between user albums records both source and destination")
    func moveBetweenAlbums() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([
            UserAlbum(id: "alb-src", title: "Inbox", assetCount: 1, canAdd: true),
            UserAlbum(id: "alb-dst", title: "Trips", assetCount: 0, canAdd: true),
        ])
        let r = await mock.moveAssets([AssetIdentifier("x")], fromAlbumId: "alb-src", toAlbumId: "alb-dst")
        #expect(r == .success(affectedCount: 1))
        #expect(mock.lastMoves[0].from == "alb-src")
        #expect(mock.lastMoves[0].to == "alb-dst")
    }

    @Test("setFavorite remembers state and returns true")
    func favorite() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let ok = await mock.setFavorite(AssetIdentifier("x"), isFavorite: true)
        #expect(ok)
        #expect(mock.favoriteState[AssetIdentifier("x")] == true)
    }

    @Test("MockPhotoLibrary mutable properties are accessible on the main actor without await")
    @MainActor
    func mockMutablePropertiesAccessibleOnMainActor() {
        // Compile-time + runtime pin: after @MainActor is added to MockPhotoLibrary,
        // all reads/writes of its stored properties must be from the main actor.
        // This test confirms the conformance is sound under @MainActor isolation.
        #expect(Thread.isMainThread, "MockPhotoLibrary must be accessed on main thread")
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        // Write mutable properties synchronously (no await).
        mock.seedAlbums([UserAlbum(id: "alb-ma", title: "Main Actor Album", assetCount: 0, canAdd: true)])
        mock.nextCommitResult = .cancelledByUser
        mock.scriptedMediaKinds["mock-asset-0"] = .livePhoto
        // Read them back synchronously.
        #expect(mock.appliedFilter == .unfiltered)
        #expect(mock.startCachingCalls.isEmpty)
        #expect(mock.stopCachingCalls.isEmpty)
        #expect(mock.stopAllCallCount == 0)
        // Call synchronous protocol methods.
        let ids = [AssetIdentifier("mock-asset-0")]
        mock.startCachingThumbnails(ids, targetSize: CGSize(width: 50, height: 50))
        #expect(mock.startCachingCalls.count == 1)
    }

    @Test("PhotoLibraryProviding synchronous caching methods are callable from @MainActor context without await")
    @MainActor
    func cachingMethodsCallableOnMainActor() {
        // This test pins that startCachingThumbnails and stopCachingThumbnails —
        // the two synchronous (non-async) protocol requirements — are callable from
        // @MainActor context without await. This is true before W1 (no isolation
        // annotation yet) and must remain true after W1 (@MainActor on the class
        // means these are @MainActor-isolated and callable synchronously from
        // another @MainActor context).
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let ids = [AssetIdentifier("cache-test-0"), AssetIdentifier("cache-test-1")]
        let size = CGSize(width: 100, height: 100)

        #expect(Thread.isMainThread, "caching calls must be on the main thread")
        mock.startCachingThumbnails(ids, targetSize: size)
        mock.stopCachingThumbnails(ids, targetSize: size)
        mock.stopCachingAllThumbnails()

        #expect(mock.startCachingCalls.count == 1)
        #expect(mock.stopCachingCalls.count == 1)
        #expect(mock.stopAllCallCount == 1)
    }

    @Test("MockPhotoLibrary conforms to all three PhotoLibraryProviding sub-protocols")
    @MainActor
    func subProtocolConformances() async {
        // Verifies both that MockPhotoLibrary satisfies each of the three
        // sub-protocols (compile-time) and that runtime dispatch through each
        // upcast reaches the concrete implementation (runtime).
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)

        let asRead: any PhotoLibraryReadProviding = mock
        let asCache: any PhotoLibraryCacheProviding = mock
        let asMutating: any PhotoLibraryMutating = mock
        let asFull: any PhotoLibraryProviding = mock

        let count = await asRead.assetCount()
        #expect(count == 3)

        asCache.stopCachingAllThumbnails()
        #expect(mock.stopAllCallCount == 1)

        let commit = await asMutating.commitDeletions([])
        #expect(commit == .success(affectedCount: 0))

        let fullCount = await asFull.assetCount()
        #expect(fullCount == 3)
    }
}
