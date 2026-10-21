import Testing
import Foundation
import UIKit
@testable import SwipeSort

@MainActor
@Suite("Settings integration")
struct SettingsIntegrationTests {

    private func settings(autoplay: Bool = true) -> AppSettings {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let s = AppSettings(defaults: d)
        s.autoplayVideos = autoplay
        return s
    }

    private let ts = CGSize(width: 1, height: 1)

    @Test("Mode 1 (upDeleteDownFavorite) — up deletes, down favorites")
    func mode1UpDown() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: ts)
        await m.start()
        await m.swipe(.up)
        #expect(m.pendingDeletions.count == 1)
        let targetId = m.currentThumbnail?.identifier
        await m.swipe(.down)
        #expect(m.favoritedCount == 1)
        if let targetId {
            #expect(mock.favoriteState[targetId] == true)
        }
    }

    @Test("Mode 1 (upDeleteDownFavorite) — left nexts (advances)")
    func mode1LeftNext() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: ts)
        await m.start()
        await m.swipe(.left)
        #expect(m.pendingDeletions.isEmpty)
        #expect(m.favoritedCount == 0)
        #expect(m.currentIndex == 1)
    }



    @Test("autoplay decision autoplays when the master toggle is on")
    func autoplayOnWhenEnabled() {
        let s = settings(autoplay: true)
        #expect(SwipeCardView.shouldAutoplay(settings: s) == true)
    }

    @Test("autoplay master toggle off disables autoplay")
    func autoplayMasterToggle() {
        let off = settings(autoplay: false)
        #expect(SwipeCardView.shouldAutoplay(settings: off) == false)
    }

    @Test("safe defaults resolve to upDeleteDownFavorite + autoplay on")
    func safeDefaults() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let s = AppSettings(defaults: d)
        #expect(s.autoplayVideos == true)
        #expect(SwipeCardView.shouldAutoplay(settings: s) == true)
    }

    @Test("Mode 1 (upDeleteDownFavorite) — right dispatches to swipePrev")
    func mode1RightPrev() async {
        // Pins the Mode 1 dispatch: SwipeSessionModel.swipe(_:using:) → .right → swipePrev.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: ts)
        await m.start()
        // Advance twice so currentIndex is 2 and swipePrev can measurably decrement.
        await m.swipeNext()
        await m.swipeNext()
        #expect(m.currentIndex == 2)

        // In Mode 1, .right is swipePrev.
        await m.swipe(.right)

        #expect(m.currentIndex == 1,
            "Mode 1 .right must call swipePrev; currentIndex should decrement by 1")
        // No decision was recorded — swipePrev is pure navigation.
        #expect(m.queue.decisions.isEmpty)
    }


}
