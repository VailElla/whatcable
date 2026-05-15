import XCTest
@testable import WhatCableCore

final class UpdateCheckerTests: XCTestCase {
    func testRemoteIsNewer() {
        XCTAssertTrue(AppInfo.isNewer(remote: "0.4.0", current: "0.3.1"))
        XCTAssertTrue(AppInfo.isNewer(remote: "0.3.2", current: "0.3.1"))
        XCTAssertTrue(AppInfo.isNewer(remote: "1.0.0", current: "0.99.99"))
    }

    func testRemoteIsOlderOrEqual() {
        XCTAssertFalse(AppInfo.isNewer(remote: "0.3.0", current: "0.3.1"))
        XCTAssertFalse(AppInfo.isNewer(remote: "0.3.1", current: "0.3.1"))
        XCTAssertFalse(AppInfo.isNewer(remote: "0.2.9", current: "0.3.0"))
    }

    func testDifferentLengths() {
        XCTAssertFalse(AppInfo.isNewer(remote: "0.4", current: "0.4.0"))
        XCTAssertFalse(AppInfo.isNewer(remote: "0.4.0", current: "0.4"))
        XCTAssertTrue(AppInfo.isNewer(remote: "0.4.1", current: "0.4"))
    }

    func testDevFallback() {
        XCTAssertTrue(AppInfo.isNewer(remote: "0.3.0", current: "dev"))
    }
}

