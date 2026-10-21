import XCTest

final class SwipeSortUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabNavigationAndGrid() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // 1. Verify landing on Recents grid
        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 5), "Recents navigation bar should exist")
        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5), "First thumbnail cell should be rendered")

        // 2. Navigate to Albums tab
        let albumsTab = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 3))
        albumsTab.tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 3), "Should switch to Albums tab")

        // 3. Navigate to Settings tab
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3), "Should switch to Settings tab")
    }

    @MainActor
    func testOpenSwipeDeckFromGridAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.tap()

        // Verify swipe deck opens with 1 of 6
        let progressCounter = app.staticTexts["ProgressCounter"]
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 5), "Progress counter should exist in deck")
        XCTAssertEqual(progressCounter.label, "1 of 6")

        // Close back to grid
        let closeButton = app.buttons["CloseDeckButton"]
        XCTAssertTrue(closeButton.exists)
        closeButton.tap()

        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 3), "Should return to Recents grid")
    }

    @MainActor
    func testSwipeLeftSkipsCardAndAdvancesDeck() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.tap()

        let progressCounter = app.staticTexts["ProgressCounter"]
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 5))
        XCTAssertEqual(progressCounter.label, "1 of 6")

        // Swipe left across the card or window
        let swipeCard = app.otherElements["SwipeCard"]
        if swipeCard.waitForExistence(timeout: 3) {
            swipeCard.swipeLeft()
        } else {
            app.windows.firstMatch.swipeLeft()
        }

        // Verify deck advances to card 2 of 6
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 3))
        XCTAssertEqual(progressCounter.label, "2 of 6")
    }

    @MainActor
    func testUndoActionRewindsCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.tap()

        let progressCounter = app.staticTexts["ProgressCounter"]
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 5))

        // Swipe up to trigger decision action
        let swipeCard = app.otherElements["SwipeCard"]
        if swipeCard.waitForExistence(timeout: 3) {
            swipeCard.swipeUp()
        } else {
            app.windows.firstMatch.swipeUp()
        }

        XCTAssertEqual(progressCounter.label, "2 of 6")

        // Tap Undo after card animation completes and button is hittable
        let undoButton = app.buttons["UndoButton"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        if !undoButton.isHittable {
            sleep(1)
        }
        undoButton.tap()

        let predicate = NSPredicate(format: "label == '1 of 6'")
        expectation(for: predicate, evaluatedWith: progressCounter, handler: nil)
        waitForExpectations(timeout: 5, handler: nil)

        XCTAssertEqual(progressCounter.label, "1 of 6", "Undo should rewind card index back to 1 of 6")
    }

    @MainActor
    func testEmptyPhotoLibraryDisplaysEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-empty"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 5))
        let emptyText = app.staticTexts["No photos found."]
        XCTAssertTrue(emptyText.waitForExistence(timeout: 5), "Should display empty state text when library has 0 photos")
        XCTAssertTrue(app.staticTexts["Try adjusting the filter, or grant library access first."].exists)

        // F8 extension: verify that with 0 assets, ZERO ThumbnailCell buttons are
        // rendered. If a regression surfaces a cell for an empty library, the swipe
        // deck could be entered against an empty session — a code path this test
        // guards against.
        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertFalse(firstCell.exists,
            "no ThumbnailCell may be present when assetCount == 0 — grid tap must not be reachable")
    }

    @MainActor
    func testSinglePhotoSwipeTransitionsToFinishedSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-single-photo"]
        app.launch()

        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.tap()

        let progressCounter = app.staticTexts["ProgressCounter"]
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 5))
        XCTAssertEqual(progressCounter.label, "1 of 1")

        // Swipe up to finish deck
        let swipeCard = app.otherElements["SwipeCard"]
        if swipeCard.waitForExistence(timeout: 3) {
            swipeCard.swipeUp()
        } else {
            app.windows.firstMatch.swipeUp()
        }

        let finishedHeading = app.staticTexts["Clean Gallery, Clear Mind"]
        XCTAssertTrue(finishedHeading.waitForExistence(timeout: 5), "Should show finished summary after swiping last photo")
    }



    @MainActor
    func testSettingsTabInteractions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))

        // Toggle Haptic feedback switch to verify interactive controls
        let hapticToggle = app.switches["Haptic feedback"]
        XCTAssertTrue(hapticToggle.waitForExistence(timeout: 3))
        hapticToggle.tap()

        // Toggle Autoplay videos switch
        let autoplayToggle = app.switches["Autoplay videos"]
        XCTAssertTrue(autoplayToggle.waitForExistence(timeout: 3))
        autoplayToggle.tap()
    }
}
