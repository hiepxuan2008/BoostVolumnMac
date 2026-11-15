import XCTest
@testable import BoostCore

final class BoostMathTests: XCTestCase {
    func testGainAtEndsOfRange() {
        XCTAssertEqual(BoostMath.gain(forPercent: 100), 1.0)
        XCTAssertEqual(BoostMath.gain(forPercent: 250), 2.5)
        XCTAssertEqual(BoostMath.gain(forPercent: 400), 4.0)
    }

    func testOutOfRangeIsClamped() {
        XCTAssertEqual(BoostMath.clampPercent(50), 100)
        XCTAssertEqual(BoostMath.clampPercent(900), 400)
        XCTAssertEqual(BoostMath.gain(forPercent: .nan), 1.0)  // NaN → 100%
    }
}
