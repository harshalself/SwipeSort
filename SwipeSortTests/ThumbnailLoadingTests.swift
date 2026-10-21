import Testing
import UIKit
import AVFoundation
import PhotosUI
@testable import SwipeSort

@Suite("ThumbnailLoading")
@MainActor
struct ThumbnailLoadingTests {

    @Test("thumbnail(for:) returns a valid AssetThumbnail from mock")
    func thumbnailReturnsMockImage() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let id = AssetIdentifier("mock-asset-0")
        let result = await mock.thumbnail(for: id, targetSize: CGSize(width: 100, height: 100))
        #expect(result != nil, "MockPhotoLibrary must return a non-nil thumbnail")
        #expect(result?.identifier == id)
        #expect(result?.isDegraded == false)
    }
}
