//
//  SwipeSortUITestsLaunchTests.swift
//  SwipeSortUITests
//
//  Created by Harshal Patil on 06/07/26.
//

import XCTest

final class SwipeSortUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // Launch with the standard --ui-testing flag so we're driving the mock
        // library and don't depend on the simulator's real photo permission dialog.
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // F16 fix: wait until the app is running-foreground; without this the test
        // silently passed even when the app crashed at launch.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
            "App must reach runningForeground state within 10s of launch")

        // F16 fix: assert the root nav bar is present — pins the tab-container view
        // as the launch destination. Any refactor that breaks initial view resolution
        // would surface here rather than silently in a downstream test.
        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 10),
            "Recents navigation bar must be present after launch (tab-bar root view intact)")

        // Keep the screenshot for CI artifacts — but now it's a bonus, not the only
        // signal.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
