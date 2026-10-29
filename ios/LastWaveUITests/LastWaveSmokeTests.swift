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
        // YouTube answers data-center IPs (like CI runners) with a bot check,
        // so playback can only be asserted when that block isn't in effect.
        var blockedReason: String?
        let miniError = app.staticTexts["mini-error"]
        if miniError.exists {
            note("mini-error: \(miniError.label)")
            if Self.isNetworkBlock(miniError.label) { blockedReason = miniError.label }
        }

        miniTitle.tap()
        let elapsed = app.staticTexts["elapsed-time"]
        let playerError = app.staticTexts["player-error"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "Now playing did not open")
        var progressed = false
        for _ in 0..<30 {
            if elapsed.label != "0:00" {
                progressed = true
                break
            }
            if playerError.exists, Self.isNetworkBlock(playerError.label) {
                blockedReason = playerError.label
            }
            sleep(1)
        }
        sleep(2)
        snap(app, "04-now-playing")
        note("elapsed=\(elapsed.label) progressed=\(progressed) error=\(playerError.exists ? playerError.label : "none")")
        if let blockedReason, !progressed {
            note("Playback not verifiable here, YouTube blocked this machine: \(blockedReason)")
        } else {
            XCTAssertTrue(progressed, "Playback time never advanced, so the audio stream did not play")
        }

        app.buttons["Lyrics"].tap()
        sleep(6)
        snap(app, "05-lyrics")

        app.buttons["Up next"].tap()
        sleep(3)
        snap(app, "06-queue")
    }

    /// Bot checks and refused audio URLs are how YouTube treats data-center
    /// IPs; ci/probe_stream.py confirms the same block outside the app.
    /// AVPlayer errors such as "Cannot Open" are NOT treated as a block.
    private static func isNetworkBlock(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bot") || lower.contains("http 403")
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
