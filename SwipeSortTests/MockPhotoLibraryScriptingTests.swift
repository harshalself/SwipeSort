import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("MockPhotoLibrary scripting hooks")
struct MockPhotoLibraryScriptingTests {

    @Test("nextRemoveResult overrides success once, then reverts to default")
    func nextRemoveResultConsumedOnce() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        mock.nextRemoveResult = .failed(reason: "smart album")

        let first  = await mock.removeAssetsFromAlbum([AssetIdentifier("x")], albumId: "a")
        let second = await mock.removeAssetsFromAlbum([AssetIdentifier("x")], albumId: "a")

        #expect(first  == .failed(reason: "smart album"))
        #expect(second == .success(affectedCount: 1),
            "second call must revert to default success — hook is consumed-once")
    }

    @Test("nextThumbnailResult .some(nil) makes thumbnail(for:) return nil once")
    func nextThumbnailResultNil() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.nextThumbnailResult = .some(nil)

        let first = await mock.thumbnail(
            for: AssetIdentifier("mock-asset-0"),
            targetSize: CGSize(width: 1, height: 1)
        )
        let second = await mock.thumbnail(
            for: AssetIdentifier("mock-asset-1"),
            targetSize: CGSize(width: 1, height: 1)
        )

        #expect(first == nil)
        #expect(second != nil, "second call must revert to default placeholder")
    }

    @Test("nextThumbnailResult with degraded thumbnail flows through once")
    func nextThumbnailResultDegraded() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let degraded = AssetThumbnail(
            identifier: AssetIdentifier("mock-asset-0"),
            image: img,
            isDegraded: true
        )
        mock.nextThumbnailResult = .some(degraded)

        let result = await mock.thumbnail(
            for: AssetIdentifier("mock-asset-0"),
            targetSize: CGSize(width: 1, height: 1)
        )
        #expect(result?.isDegraded == true)
    }

    @Test("setCurrentAuthorization overwrites the stored authorization")
    func setCurrentAuthorizationOverwrites() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        #expect(await mock.currentAuthorization() == .authorized)

        mock.setCurrentAuthorization(.denied)
        #expect(await mock.currentAuthorization() == .denied)
    }

    @Test("isFavorite defaults to false and round-trips through setFavorite")
    func isFavoriteRoundTrip() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let id = AssetIdentifier("mock-asset-0")

        // Default state: assets are not favourited.
        #expect(await mock.isFavorite(for: id) == false,
                "Fresh assets must default to non-favourite so the context-menu heart icon starts empty")

        _ = await mock.setFavorite(id, isFavorite: true)
        #expect(await mock.isFavorite(for: id) == true,
                "setFavorite(true) must persist so the menu toggle reflects the new state")

        _ = await mock.setFavorite(id, isFavorite: false)
        #expect(await mock.isFavorite(for: id) == false,
                "setFavorite(false) must clear the flag so the toggle can round-trip")
    }

    @Test("setFavorites applies the same flag to every id in the batch")
    func setFavoritesBatchAppliesToAll() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let ids = (0..<3).map { AssetIdentifier("mock-asset-\($0)") }

        _ = await mock.setFavorites(ids, isFavorite: true)
        for id in ids {
            #expect(await mock.isFavorite(for: id) == true,
                    "Every id in the batch must be favourited after setFavorites(true)")
        }

        _ = await mock.setFavorites(ids, isFavorite: false)
        for id in ids {
            #expect(await mock.isFavorite(for: id) == false,
                    "Every id must be unfavourited after setFavorites(false)")
        }
    }

    @Test("setFavorites on empty input is a no-op success")
    func setFavoritesEmptyIsNoOp() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let ok = await mock.setFavorites([], isFavorite: true)
        #expect(ok == true, "Empty batch must succeed — the bar disables when nothing is selected, but the protocol contract still applies")
    }
}
