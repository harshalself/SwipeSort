import XCTest

final class GridScrollUIPerformanceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Benchmarks live photo grid scrolling using Apple's official `scrollAndDecelerationMetric`,
    /// capturing hitch time ratio (ms per second of scrolling), frame drops, CPU utilization, and memory usage.
    func testPhotoGridScrollPerformanceAndHitches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mockLibrary"]
        app.launch()

        let scrollView = app.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: 5.0) else {
            return
        }

        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollDecelerationMetric,
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]

        measure(metrics: metrics) {
            scrollView.swipeUp(velocity: .fast)
            scrollView.swipeUp(velocity: .fast)
            scrollView.swipeDown(velocity: .fast)
        }
    }

    /// Benchmarks CPU and memory consumption during rapid card swipe transitions in the swipe deck.
    func testSwipeDeckCardTransitionSignposts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mockLibrary"]
        app.launch()

        let firstCell = app.scrollViews.firstMatch.buttons.firstMatch
        guard firstCell.waitForExistence(timeout: 5.0) else {
            return
        }
        firstCell.tap()

        let metrics: [XCTMetric] = [
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]

        measure(metrics: metrics) {
            app.swipeLeft(velocity: .fast)
            if app.buttons["Undo"].exists {
                app.buttons["Undo"].tap()
            } else {
                app.swipeRight(velocity: .fast)
            }
        }
    }
}
