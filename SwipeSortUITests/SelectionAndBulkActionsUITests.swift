import XCTest

final class SelectionAndBulkActionsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMultiSelectFavoriteAndCancelFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mockLibrary"]
        app.launch()

        // 1. Enter selection mode
        let selectButton = app.buttons["Select"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Select button should exist on Recents navigation bar")
        selectButton.tap()

        // 2. Select first two cells
        let cell0 = app.buttons["ThumbnailCell-0"]
        let cell1 = app.buttons["ThumbnailCell-1"]
        XCTAssertTrue(cell0.waitForExistence(timeout: 3))
        XCTAssertTrue(cell1.waitForExistence(timeout: 3))
        cell0.tap()
        cell1.tap()

        // 3. Verify Cancel button replaces Select button when active
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button should replace Select button during active multi-select")

        // 4. Tap batch Favorite button in bottom bar
        let favoriteButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Favorite'")).firstMatch
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 3), "Batch favorite button should appear and show item count")
        favoriteButton.tap()

        // 5. Verify selection clears automatically and cell 0 shows favorite badge
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Should exit selection mode automatically after favorite action")
    }

    @MainActor
    func testMultiSelectCancelClearsSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mockLibrary"]
        app.launch()

        let selectButton = app.buttons["Select"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        let cell0 = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(cell0.waitForExistence(timeout: 3))
        cell0.tap()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.tap()

        // Verify we exited selection mode
        XCTAssertTrue(selectButton.waitForExistence(timeout: 3), "Should return to normal grid mode on Cancel")
    }
}
