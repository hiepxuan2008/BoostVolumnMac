import XCTest
@testable import BoostCore

final class OutputDeviceTests: XCTestCase {
    let a = OutputDevice(id: 1, uid: "A", name: "MacBook Speakers")
    let b = OutputDevice(id: 2, uid: "B", name: "Headphones")

    func testPreferredDeviceWins() {
        XCTAssertEqual(resolveOutputDevice(preferredUID: "B", available: [a, b], systemDefaultUID: "A"), b)
    }

    func testMissingPreferredFallsBackToSystemDefault() {
        XCTAssertEqual(resolveOutputDevice(preferredUID: "gone", available: [a, b], systemDefaultUID: "A"), a)
    }

    func testNilPreferredUsesSystemDefault() {
        XCTAssertEqual(resolveOutputDevice(preferredUID: nil, available: [a, b], systemDefaultUID: "B"), b)
    }

    func testNoSystemDefaultUsesFirst() {
        XCTAssertEqual(resolveOutputDevice(preferredUID: nil, available: [a, b], systemDefaultUID: nil), a)
    }

    func testNoDevicesReturnsNil() {
        XCTAssertNil(resolveOutputDevice(preferredUID: "A", available: [], systemDefaultUID: "A"))
    }
}
