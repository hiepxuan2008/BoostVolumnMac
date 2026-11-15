import XCTest
@testable import BoostCore

final class BoostSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BoostSettingsTests-\(UUID())")!
    }

    func testDefaults() {
        let s = BoostSettings(defaults: freshDefaults())
        XCTAssertEqual(s.boostPercent, 200)
        XCTAssertFalse(s.isEnabled)
        XCTAssertNil(s.outputDeviceUID)
    }

    func testRoundTripAcrossInstances() {
        let d = freshDefaults()
        let a = BoostSettings(defaults: d)
        a.boostPercent = 320
        a.isEnabled = true
        a.outputDeviceUID = "uid-1"
        let b = BoostSettings(defaults: d)
        XCTAssertEqual(b.boostPercent, 320)
        XCTAssertTrue(b.isEnabled)
        XCTAssertEqual(b.outputDeviceUID, "uid-1")
        b.outputDeviceUID = nil
        XCTAssertNil(BoostSettings(defaults: d).outputDeviceUID)
    }

    func testStoredOutOfRangeIsClamped() {
        let d = freshDefaults()
        d.set(1000, forKey: "boostPercent")
        XCTAssertEqual(BoostSettings(defaults: d).boostPercent, 400)
        let s = BoostSettings(defaults: d)
        s.boostPercent = 10
        XCTAssertEqual(s.boostPercent, 100)
    }
}
