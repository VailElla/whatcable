import XCTest
@testable import WhatCableCore

/// Unit tests for USBCPinMap model.
///
/// Test fixtures come from real IOKit probe data captured on Apple Silicon.
/// Each pin configuration dict matches an actual `ioreg` dump from the
/// probes/ directory.
final class USBCPinMapTests: XCTestCase {

    // MARK: - Factory: nil for empty input

    func testReturnsNilForEmptyDict() {
        let map = USBCPinMap.from(pinConfiguration: [:])
        XCTAssertNil(map)
    }

    // MARK: - All zeros (MagSafe / nothing connected)

    func testAllZerosHasNoActivity() {
        let pins = allZeros
        let map = USBCPinMap.from(pinConfiguration: pins)!
        XCTAssertFalse(map.hasActivity)
    }

    func testAllZerosSignalSummary() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        XCTAssertEqual(map.signalSummary, "No data signals")
    }

    // MARK: - USB 3 pair A (probe: USB device port)

    func testUSB3PairADetected() {
        // From probe: tx1=1, rx1=2, all others zero.
        let map = USBCPinMap.from(pinConfiguration: usb3PairA)!
        XCTAssertTrue(map.hasActivity)

        // tx1 drives A2/A3
        XCTAssertEqual(map.topRow[1].signal, .usb3PairA)  // A2
        XCTAssertEqual(map.topRow[2].signal, .usb3PairA)  // A3

        // rx1 drives B10/B11
        XCTAssertEqual(map.bottomRow[1].signal, .usb3PairA)  // B11
        XCTAssertEqual(map.bottomRow[2].signal, .usb3PairA)  // B10

        // Everything else on data pins should be inactive
        XCTAssertEqual(map.topRow[9].signal, .inactive)   // A10 (rx2)
        XCTAssertEqual(map.bottomRow[10].signal, .inactive) // B2 (tx2)
    }

    func testUSB3PairASignalSummary() {
        let map = USBCPinMap.from(pinConfiguration: usb3PairA)!
        XCTAssertEqual(map.signalSummary, "USB 3")
    }

    // MARK: - USB 3 pair B (probe: dock port)

    func testUSB3PairBDetected() {
        // From probe: tx2=3, rx2=4, all others zero.
        let map = USBCPinMap.from(pinConfiguration: usb3PairB)!
        XCTAssertTrue(map.hasActivity)

        // tx2 drives B2/B3
        XCTAssertEqual(map.bottomRow[10].signal, .usb3PairB)  // B2
        XCTAssertEqual(map.bottomRow[9].signal, .usb3PairB)   // B3

        // rx2 drives A10/A11
        XCTAssertEqual(map.topRow[9].signal, .usb3PairB)   // A10
        XCTAssertEqual(map.topRow[10].signal, .usb3PairB)  // A11
    }

    // MARK: - 4-lane DisplayPort (probe: monitor port)

    func testFourLaneDPDetected() {
        // From probe: tx1=6, rx1=5, tx2=7, rx2=8, sbu1=2, sbu2=1
        let map = USBCPinMap.from(pinConfiguration: fourLaneDP)!
        XCTAssertTrue(map.hasActivity)

        // tx1 (value 6) = DP Lane 1 on A2/A3
        XCTAssertEqual(map.topRow[1].signal, .dpLane(1))
        XCTAssertEqual(map.topRow[2].signal, .dpLane(1))

        // rx1 (value 5) = DP Lane 0 on B10/B11
        XCTAssertEqual(map.bottomRow[1].signal, .dpLane(0))
        XCTAssertEqual(map.bottomRow[2].signal, .dpLane(0))

        // tx2 (value 7) = DP Lane 2 on B2/B3
        XCTAssertEqual(map.bottomRow[10].signal, .dpLane(2))
        XCTAssertEqual(map.bottomRow[9].signal, .dpLane(2))

        // rx2 (value 8) = DP Lane 3 on A10/A11
        XCTAssertEqual(map.topRow[9].signal, .dpLane(3))
        XCTAssertEqual(map.topRow[10].signal, .dpLane(3))

        // SBU pins carry DP AUX
        XCTAssertEqual(map.topRow[7].signal, .dpAux)     // A8 (sbu1)
        XCTAssertEqual(map.bottomRow[4].signal, .dpAux)   // B8 (sbu2)
    }

    func testFourLaneDPSignalSummary() {
        let map = USBCPinMap.from(pinConfiguration: fourLaneDP)!
        XCTAssertEqual(map.signalSummary, "DP (4 lanes)")
    }

    // MARK: - Static pins always present

    func testStaticPinsAreCorrect() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!

        // Ground pins
        XCTAssertEqual(map.topRow[0].signal, .ground)     // A1
        XCTAssertEqual(map.topRow[11].signal, .ground)    // A12
        XCTAssertEqual(map.bottomRow[0].signal, .ground)  // B12
        XCTAssertEqual(map.bottomRow[11].signal, .ground) // B1

        // VBUS pins
        XCTAssertEqual(map.topRow[3].signal, .vbus)       // A4
        XCTAssertEqual(map.topRow[8].signal, .vbus)       // A9
        XCTAssertEqual(map.bottomRow[3].signal, .vbus)    // B9
        XCTAssertEqual(map.bottomRow[8].signal, .vbus)    // B4

        // CC pins
        XCTAssertEqual(map.topRow[4].signal, .cc)         // A5
        XCTAssertEqual(map.bottomRow[7].signal, .cc)      // B5

        // USB 2.0 pins
        XCTAssertEqual(map.topRow[5].signal, .usb2)       // A6
        XCTAssertEqual(map.topRow[6].signal, .usb2)       // A7
        XCTAssertEqual(map.bottomRow[5].signal, .usb2)    // B7
        XCTAssertEqual(map.bottomRow[6].signal, .usb2)    // B6
    }

    func testStaticPinsAreNotDynamic() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        XCTAssertFalse(USBCPinMap.Signal.ground.isDynamic)
        XCTAssertFalse(USBCPinMap.Signal.vbus.isDynamic)
        XCTAssertFalse(USBCPinMap.Signal.cc.isDynamic)
        XCTAssertFalse(USBCPinMap.Signal.usb2.isDynamic)
        XCTAssertFalse(USBCPinMap.Signal.inactive.isDynamic)
        // Confirm no static pin is flagged as dynamic
        XCTAssertFalse(map.topRow[0].signal.isDynamic)   // GND
        XCTAssertFalse(map.topRow[3].signal.isDynamic)   // VBUS
    }

    // MARK: - Pin IDs and row sizes

    func testRowSizes() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        XCTAssertEqual(map.topRow.count, 12)
        XCTAssertEqual(map.bottomRow.count, 12)
        XCTAssertEqual(map.allPins.count, 24)
    }

    func testTopRowPinIDs() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        let ids = map.topRow.map(\.id)
        XCTAssertEqual(ids, ["A1","A2","A3","A4","A5","A6","A7","A8","A9","A10","A11","A12"])
    }

    func testBottomRowPinIDs() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        let ids = map.bottomRow.map(\.id)
        // Reversed: B12 down to B1 for visual layout
        XCTAssertEqual(ids, ["B12","B11","B10","B9","B8","B7","B6","B5","B4","B3","B2","B1"])
    }

    // MARK: - Orientation

    func testOrientationNormal() {
        let map = USBCPinMap.from(pinConfiguration: allZeros, plugOrientation: 1)!
        XCTAssertEqual(map.orientation, 1)
        XCTAssertEqual(map.orientationLabel, "Normal")
    }

    func testOrientationFlipped() {
        let map = USBCPinMap.from(pinConfiguration: allZeros, plugOrientation: 2)!
        XCTAssertEqual(map.orientation, 2)
        XCTAssertEqual(map.orientationLabel, "Flipped")
    }

    func testOrientationUnknown() {
        let map = USBCPinMap.from(pinConfiguration: allZeros, plugOrientation: nil)!
        XCTAssertEqual(map.orientation, 0)
        XCTAssertEqual(map.orientationLabel, "Unknown")
    }

    // MARK: - Signal labels

    func testSignalLabels() {
        XCTAssertEqual(USBCPinMap.Signal.ground.label, "GND")
        XCTAssertEqual(USBCPinMap.Signal.vbus.label, "VBUS")
        XCTAssertEqual(USBCPinMap.Signal.cc.label, "CC")
        XCTAssertEqual(USBCPinMap.Signal.usb2.label, "USB 2.0")
        XCTAssertEqual(USBCPinMap.Signal.usb3PairA.label, "USB 3")
        XCTAssertEqual(USBCPinMap.Signal.usb3PairB.label, "USB 3")
        XCTAssertEqual(USBCPinMap.Signal.dpLane(2).label, "DP Lane 2")
        XCTAssertEqual(USBCPinMap.Signal.dpAux.label, "DP AUX")
        XCTAssertEqual(USBCPinMap.Signal.inactive.label, "Inactive")
        XCTAssertEqual(USBCPinMap.Signal.unknown(99).label, "Signal 99")
    }

    // MARK: - Unknown values preserved

    func testUnknownDataValue() {
        let pins = ["tx1": "42", "rx1": "0", "tx2": "0", "rx2": "0", "sbu1": "0", "sbu2": "0"]
        let map = USBCPinMap.from(pinConfiguration: pins)!
        XCTAssertEqual(map.topRow[1].signal, .unknown(42))
        XCTAssertTrue(map.topRow[1].signal.isDynamic == false)
    }

    func testUnknownSBUValue() {
        let pins = ["tx1": "0", "rx1": "0", "tx2": "0", "rx2": "0", "sbu1": "7", "sbu2": "0"]
        let map = USBCPinMap.from(pinConfiguration: pins)!
        XCTAssertEqual(map.topRow[7].signal, .unknown(7))
    }

    // MARK: - Mixed signals (hypothetical 2-lane DP + USB3)

    func testTwoLaneDPPlusUSB3Summary() {
        // 2 DP lanes on tx1/rx1, USB3 pair B on tx2/rx2
        let pins = ["tx1": "6", "rx1": "5", "tx2": "3", "rx2": "4", "sbu1": "2", "sbu2": "1"]
        let map = USBCPinMap.from(pinConfiguration: pins)!
        XCTAssertEqual(map.signalSummary, "USB 3 + DP (2 lanes)")
    }

    // MARK: - Hashable / Equatable

    func testEquatable() {
        let a = USBCPinMap.from(pinConfiguration: usb3PairA, plugOrientation: 1)!
        let b = USBCPinMap.from(pinConfiguration: usb3PairA, plugOrientation: 1)!
        XCTAssertEqual(a, b)
    }

    func testNotEqualWhenDifferentConfig() {
        let a = USBCPinMap.from(pinConfiguration: usb3PairA)!
        let b = USBCPinMap.from(pinConfiguration: fourLaneDP)!
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Fixtures from probe data

    /// MagSafe port or port with nothing connected. All data pins inactive.
    private var allZeros: [String: String] {
        ["tx1": "0", "rx1": "0", "tx2": "0", "rx2": "0", "sbu1": "0", "sbu2": "0"]
    }

    /// USB device connected, using SuperSpeed pair A.
    /// From probe: ConnectionCount=35, IOAccessoryUSBConnectType=0.
    private var usb3PairA: [String: String] {
        ["tx1": "1", "rx1": "2", "tx2": "0", "rx2": "0", "sbu1": "0", "sbu2": "0"]
    }

    /// Dock connected, using SuperSpeed pair B.
    /// From probe: ConnectionCount=5, IOAccessoryUSBConnectType=0.
    private var usb3PairB: [String: String] {
        ["tx1": "0", "rx1": "0", "tx2": "3", "rx2": "4", "sbu1": "0", "sbu2": "0"]
    }

    /// Monitor connected with 4-lane DisplayPort alt mode.
    /// From probe: ConnectionCount=75, IOAccessoryUSBConnectType=4,
    /// PlugOrientation=2, TransportsActive=["CC","DisplayPort"].
    private var fourLaneDP: [String: String] {
        ["tx1": "6", "rx1": "5", "tx2": "7", "rx2": "8", "sbu1": "2", "sbu2": "1"]
    }
}
