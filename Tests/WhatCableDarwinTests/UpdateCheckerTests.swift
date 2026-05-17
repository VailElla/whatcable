import Testing
@testable import WhatCableCore

@Suite("Update Checker")
struct UpdateCheckerTests {
    @Test("Remote is newer")
    func remoteIsNewer() {
        #expect(AppInfo.isNewer(remote: "0.4.0", current: "0.3.1"))
        #expect(AppInfo.isNewer(remote: "0.3.2", current: "0.3.1"))
        #expect(AppInfo.isNewer(remote: "1.0.0", current: "0.99.99"))
    }

    @Test("Remote is older or equal")
    func remoteIsOlderOrEqual() {
        #expect(!AppInfo.isNewer(remote: "0.3.0", current: "0.3.1"))
        #expect(!AppInfo.isNewer(remote: "0.3.1", current: "0.3.1"))
        #expect(!AppInfo.isNewer(remote: "0.2.9", current: "0.3.0"))
    }

    @Test("Different lengths")
    func differentLengths() {
        #expect(!AppInfo.isNewer(remote: "0.4", current: "0.4.0"))
        #expect(!AppInfo.isNewer(remote: "0.4.0", current: "0.4"))
        #expect(AppInfo.isNewer(remote: "0.4.1", current: "0.4"))
    }

    @Test("Dev fallback")
    func devFallback() {
        #expect(AppInfo.isNewer(remote: "0.3.0", current: "dev"))
    }
}
