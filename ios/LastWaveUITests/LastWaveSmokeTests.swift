import XCTest

/// End-to-end smoke test run on the iOS Simulator in CI: search, play,
/// confirm the stream actually advances, then open lyrics and the queue.
/// Screenshots are attached to the result bundle for review.
final class LastWaveSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testSearchPlayLyricsQueue() throws {
        let app = XCUIApplication()
        app.launch()
        snap(app, "01-home")

        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search field missing")
        field.tap()
        field.typeText("Daft Punk Get Lucky\n")

        let firstResult = app.buttons.matching(identifier: "track-row").firstMatch
        let found = firstResult.waitForExistence(timeout: 30)
        snap(app, "02-search-results")
        XCTAssertTrue(found, "No search results")
        guard found else { return }
        firstResult.tap()

        let miniTitle = app.staticTexts["mini-title"]
        XCTAssertTrue(miniTitle.waitForExistence(timeout: 10), "Mini player did not appear")
        sleep(8)
        snap(app, "03-mini-player")
        let miniError = app.staticTexts["mini-error"]
        if miniError.exists { note("mini-error: \(miniError.label)") }

        miniTitle.tap()
        let elapsed = app.staticTexts["elapsed-time"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "Now playing did not open")
        var progressed = false
        for _ in 0..<30 {
            if elapsed.label != "0:00" {
                progressed = true
                break
            }
            sleep(1)
        }
        sleep(2)
        snap(app, "04-now-playing")
        let playerError = app.staticTexts["player-error"]
        note("elapsed=\(elapsed.label) progressed=\(progressed) error=\(playerError.exists ? playerError.label : "none")")
        XCTAssertTrue(progressed, "Playback time never advanced, so the audio stream did not play")

        app.buttons["Lyrics"].tap()
        sleep(6)
        snap(app, "05-lyrics")

        app.buttons["Up next"].tap()
        sleep(3)
        snap(app, "06-queue")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
