import CoreGraphics
import XCTest
@testable import LocalFlow

/// The push-to-talk key enum. Keycodes are matched against live flagsChanged
/// events, so a silent change here would break hotkey detection.
final class HotkeyManagerTests: XCTestCase {

    func testKeyCodesAreStable() {
        XCTAssertEqual(HotkeyManager.Key.rightOption.keyCode, 61)
        XCTAssertEqual(HotkeyManager.Key.rightCommand.keyCode, 54)
        XCTAssertEqual(HotkeyManager.Key.fn.keyCode, 63)
    }

    func testRawValuesRoundTrip() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertEqual(HotkeyManager.Key(rawValue: key.rawValue), key)
        }
    }

    func testAllCasesCovered() {
        XCTAssertEqual(HotkeyManager.Key.allCases.count, 3)
    }

    func testLabelsAreNonEmpty() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertFalse(key.label.isEmpty)
        }
    }

    /// Run under `swift test --sanitize=thread` to catch the race. Without the
    /// sanitizer it still checks that every edge reaches the current handler.
    func testTapThreadEventsUseCallbacksTheMainThreadReassigns() throws {
        let manager = HotkeyManager()
        let key = HotkeyManager.Key.rightOption
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: key.keyCode)
        var presses = 0
        let edges = 400
        let finished = expectation(description: "tap thread finished")
        let tapThread = Thread {
            for index in 0..<edges {
                event.flags = index.isMultiple(of: 2) ? key.deviceMask.union(key.genericMask) : []
                _ = manager.handle(type: .flagsChanged, event: event)
            }
            finished.fulfill()
        }
        tapThread.start()
        // The app reassigns callbacks while its tap runs, e.g. when Ollama
        // reachability restarts the command tap.
        let deadline = Date().addingTimeInterval(5)
        while presses < edges / 2, Date() < deadline {
            manager.onPress = { presses += 1 }
            manager.onRelease = {}
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(presses, edges / 2)
    }

    func testDeviceSpecificFlagMeansPressed() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertTrue(HotkeyManager.pressedState(
                flags: key.deviceMask.union(key.genericMask), key: key, wasDown: false
            ))
            XCTAssertTrue(HotkeyManager.pressedState(
                flags: key.deviceMask.union(key.genericMask), key: key, wasDown: true
            ))
        }
    }

    func testMissingGenericFlagMeansReleased() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertFalse(HotkeyManager.pressedState(flags: [], key: key, wasDown: false))
            XCTAssertFalse(HotkeyManager.pressedState(flags: [], key: key, wasDown: true))
        }
    }

    func testGenericOnlyModifierAlternatesForRemappedKeys() {
        for key in [HotkeyManager.Key.rightOption, .rightCommand] {
            XCTAssertTrue(HotkeyManager.pressedState(
                flags: key.genericMask, key: key, wasDown: false
            ))
            XCTAssertFalse(HotkeyManager.pressedState(
                flags: key.genericMask, key: key, wasDown: true
            ))
        }
    }
}
