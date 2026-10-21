import XCTest

final class FilterAndNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFilterSheetOpenResetAndTabSwitching() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mockLibrary"]
        app.launch()

        // 1. Verify on Recents grid and open FilterSheet
        let filterButton = app.buttons["FilterButton"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5), "Filter button should exist on navigation bar")
        filterButton.tap()

        // 2. Verify inside Filter sheet
        XCTAssertTrue(app.navigationBars["Filter"].waitForExistence(timeout: 3), "FilterSheet navigation title should appear")

        // 3. Tap Reset to make sure defaults are applied
        let resetButton = app.buttons["Reset"]
        if resetButton.exists {
            resetButton.tap()
        }

        // 4. Dismiss sheet by swiping down or tapping close/outside if available
        app.swipeDown(velocity: .fast)

        // 5. Navigate across tabs to confirm state and header persistence
        let albumsTab = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 3))
        albumsTab.tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 3))

        let recentsTab = app.tabBars.buttons["Recents"]
        XCTAssertTrue(recentsTab.waitForExistence(timeout: 3))
        recentsTab.tap()
        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 3))
    }
}
