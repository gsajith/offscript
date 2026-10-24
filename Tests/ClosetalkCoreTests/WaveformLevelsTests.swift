import XCTest
@testable import ClosetalkCore

final class WaveformLevelsTests: XCTestCase {
    func testLevelsFollowADecibelScale() {
        XCTAssertEqual(WaveformLevels.level(rms: 0), 0)
        XCTAssertEqual(WaveformLevels.level(rms: 0.001), 0) // -60 dB, room noise
        XCTAssertEqual(WaveformLevels.level(rms: 0.01), 0.25, accuracy: 0.001) // -40 dB, a quarter of the way up
        XCTAssertEqual(WaveformLevels.level(rms: 0.5), 1) // -6 dB, loud speech
    }

    func testAppendingShiftsTheBarsAlong() {
        var levels = WaveformLevels(count: 3)
        levels.append(rms: 0.5)
        levels.append(rms: 0)
        XCTAssertEqual(levels.values, [0, 1, 0])
    }
}
