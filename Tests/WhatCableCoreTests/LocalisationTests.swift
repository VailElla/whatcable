import Testing
import Foundation
@testable import WhatCableCore

@Suite("Localisation")
struct LocalisationTests {

    @Test("String files have many keys")
    func stringFilesHaveManyKeys() throws {
        let bundle = Bundle.module
        let url = try #require(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"),
            "en.lproj/Localizable.strings not found in bundle"
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        let keyLines = content.components(separatedBy: "\n").filter { $0.contains(" = ") && !$0.hasPrefix("//") }
        #expect(keyLines.count > 50, "en.lproj/Localizable.strings should have more than 50 entries")
    }

    @Test("English source strings resolve to themselves")
    func englishSourceStringsResolveToThemselves() {
        let bundle = Bundle.module
        let sample = String(localized: "Nothing connected", bundle: bundle)
        #expect(sample == "Nothing connected")
    }

    @Test("Interpolated strings resolve")
    func interpolatedStringsResolve() {
        let bundle = Bundle.module
        let result = String(localized: "Cable speed: \("USB 3.2 Gen 2 (10 Gbps)")", bundle: bundle)
        #expect(result == "Cable speed: USB 3.2 Gen 2 (10 Gbps)")
    }
}
