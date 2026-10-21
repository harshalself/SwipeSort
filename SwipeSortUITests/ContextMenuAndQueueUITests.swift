import XCTest

final class ContextMenuAndQueueUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQueueLifecycleAndBatchDeleteAll() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mockLibrary"]
        app.launch()

        // 1. Open swipe deck from grid
        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.tap()

        // 2. Swipe up to queue for deletion (`Mode 1: Up = Delete`)
        let progressCounter = app.staticTexts["ProgressCounter"]
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 5))
        app.swipeUp(velocity: .fast)

        // 3. Verify pending deletions badge button increments and open it
        let queueButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View pending deletions'")).firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5), "Queue badge button should appear when items are queued")
        queueButton.tap()

        // 4. Verify inside DeletionQueueView navigation bar and empty/grid check
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Pending Deletions'")).firstMatch.waitForExistence(timeout: 5))

        // 5. Tap Delete All button
        let deleteAllButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete All'")).firstMatch
        if deleteAllButton.exists {
            deleteAllButton.tap()
        }
    }
}
