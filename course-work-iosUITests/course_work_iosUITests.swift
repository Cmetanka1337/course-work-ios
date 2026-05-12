import XCTest

final class course_work_iosUITests: XCTestCase {
    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.staticTexts["Stage 3 weekly personalization"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["section-addWeek"].exists)
        XCTAssertTrue(app.buttons["section-calibration"].exists)
    }
}
