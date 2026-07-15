import XCTest
@testable import WhatCable
import WhatCableDarwinBackend

/// Issue #429: the "Skip deep USB probing" setting must drive
/// `USBWatcher.probeBillboardDescriptors`, the single gate on the only USB bus
/// traffic WhatCable produces. If that wiring breaks, the compatibility switch
/// looks present in the UI but does nothing, and a KVM/hub user stays stuck.
@MainActor
final class USBProbingSettingTests: XCTestCase {
    func testTogglingSkipDeepUSBProbingDrivesTheWatcherGate() {
        let settings = AppSettings.shared
        let originalSetting = settings.skipDeepUSBProbing
        let originalStatic = USBWatcher.probeBillboardDescriptors
        defer {
            settings.skipDeepUSBProbing = originalSetting
            USBWatcher.probeBillboardDescriptors = originalStatic
        }

        // Force a known baseline so the flips below always cross the didSet
        // guard (which no-ops on an unchanged value).
        settings.skipDeepUSBProbing = false

        // Compat switch ON: WhatCable must stop probing.
        settings.skipDeepUSBProbing = true
        XCTAssertFalse(USBWatcher.probeBillboardDescriptors,
                       "Skipping deep USB probing must disable the Billboard descriptor read")

        // Compat switch OFF: probing (the default behaviour) comes back.
        settings.skipDeepUSBProbing = false
        XCTAssertTrue(USBWatcher.probeBillboardDescriptors,
                      "Clearing the compat switch must re-enable probing")
    }
}
