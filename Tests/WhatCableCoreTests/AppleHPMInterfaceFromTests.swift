import Foundation
import Testing
@testable import WhatCableCore

/// Covers `USBCPort.from(...)` -- the pure factory the watcher uses to turn a
/// raw IOKit property dictionary into a `USBCPort`. Fixture dictionaries are
/// transcribed from real `ioreg -l -w 0 -p IOService` dumps, so the keys and
/// shapes here match what live machines actually report.
///
/// Currently anchored on the M2 MacBook Air dump from #13 (the trigger for
/// #14). Add fixtures from M1, M3, M5, etc. as ioreg dumps from those
/// machines arrive.
@Suite("USBCPort.from factory")
struct USBCPortFromTests {

    // MARK: - M2 MacBook Air fixtures (from #13)

    /// Disconnected `Port-USB-C@1` on an M2 MBA. Class is
    /// `AppleTCControllerType10`, ConnectionActive=No.
    private var m2MBA_USBC_Disconnected: [String: Any] {
        [
            "PortDescription": "Port-USB-C@1",
            "PortTypeDescription": "USB-C",
            "PortNumber": NSNumber(value: 1),
            "PortType": NSNumber(value: 2),
            "ConnectionActive": NSNumber(value: false),
            "ActiveCable": NSNumber(value: false),
            "OpticalCable": NSNumber(value: false),
            "IOAccessoryUSBActive": NSNumber(value: true),
            "IOAccessoryUSBSuperSpeedActive": NSNumber(value: false),
            "IOAccessoryUSBModeType": NSNumber(value: 4),
            "IOAccessoryUSBConnectString": "None",
            "TransportsSupported": ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            "TransportsActive": [String](),
            "TransportsProvisioned": ["CC"],
            "PlugOrientation": NSNumber(value: 0),
            "Plug Event Count": NSNumber(value: 7),
            "ConnectionCount": NSNumber(value: 3),
            "Overcurrent Count": NSNumber(value: 0),
            "Pin Configuration": [
                "sbu1": NSNumber(value: 1),
                "tx1": NSNumber(value: 1),
                "rx2": NSNumber(value: 5),
                "tx2": NSNumber(value: 6),
                "sbu2": NSNumber(value: 2),
                "rx1": NSNumber(value: 2)
            ],
            "IOAccessoryPowerCurrentLimits": [
                NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0),
                NSNumber(value: 0), NSNumber(value: 0)
            ]
        ]
    }

    /// Connected `Port-MagSafe 3@1` on an M2 MBA. Class is
    /// `AppleTCControllerType11`, ConnectionActive=Yes.
    private var m2MBA_MagSafe_Connected: [String: Any] {
        [
            "PortDescription": "Port-MagSafe 3@1",
            "PortTypeDescription": "MagSafe 3",
            "PortNumber": NSNumber(value: 1),
            "PortType": NSNumber(value: 17),
            "ConnectionActive": NSNumber(value: true),
            "ActiveCable": NSNumber(value: false),
            "OpticalCable": NSNumber(value: false),
            "IOAccessoryUSBActive": NSNumber(value: true),
            "IOAccessoryUSBModeType": NSNumber(value: 4),
            "TransportsSupported": [String](),
            "TransportsActive": ["CC"],
            "TransportsProvisioned": ["CC"],
            "PlugOrientation": NSNumber(value: 1),
            "Plug Event Count": NSNumber(value: 1),
            "ConnectionCount": NSNumber(value: 1),
            "Overcurrent Count": NSNumber(value: 0),
            "Pin Configuration": [
                "sbu1": NSNumber(value: 0),
                "tx1": NSNumber(value: 0),
                "rx2": NSNumber(value: 0),
                "tx2": NSNumber(value: 0),
                "sbu2": NSNumber(value: 0),
                "rx1": NSNumber(value: 0)
            ],
            "IOAccessoryPowerCurrentLimits": [
                NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0),
                NSNumber(value: 0), NSNumber(value: 0)
            ]
        ]
    }

    // MARK: - Happy paths

    @Test("M2 MBA USB-C port parses")
    func m2MBA_USBCPort_Parses() throws {
        let port = try #require(USBCPort.from(
            entryID: 0x1000005c4,
            serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10",
            properties: m2MBA_USBC_Disconnected
        ))
        #expect(port.serviceName == "Port-USB-C@1")
        #expect(port.className == "AppleTCControllerType10")
        #expect(port.portTypeDescription == "USB-C")
        #expect(port.portNumber == 1)
        #expect(port.connectionActive == false)
        #expect(port.transportsSupported == ["CC", "USB2", "USB3", "CIO", "DisplayPort"])
        #expect(port.transportsActive.isEmpty)
        #expect(port.pinConfiguration["tx1"] == "1")
        #expect(port.pinConfiguration["rx2"] == "5")
    }

    @Test("M2 MBA MagSafe port parses")
    func m2MBA_MagSafePort_Parses() throws {
        let port = try #require(USBCPort.from(
            entryID: 0x1000005cd,
            serviceName: "Port-MagSafe 3@1",
            className: "AppleTCControllerType11",
            properties: m2MBA_MagSafe_Connected
        ))
        #expect(port.portTypeDescription == "MagSafe 3")
        #expect(port.connectionActive == true)
        #expect(port.transportsActive == ["CC"])
        // Confirms portKey resolves to MagSafe's 17/N (PortType=17 in raw props).
        #expect(port.portKey == "17/1")
    }

    /// Regression for #9: the watcher must not invent a connectionActive
    /// for a disconnected port. The factory should preserve the boolean
    /// verbatim.
    @Test("connectionActive preserved from properties")
    func connectionActivePreservedFromProperties() throws {
        let disconnected = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10",
            properties: m2MBA_USBC_Disconnected
        ))
        #expect(disconnected.connectionActive == false)

        let connected = try #require(USBCPort.from(
            entryID: 2, serviceName: "Port-MagSafe 3@1",
            className: "AppleTCControllerType11",
            properties: m2MBA_MagSafe_Connected
        ))
        #expect(connected.connectionActive == true)
    }

    // MARK: - Filter rejects non-port entries

    @Test("rejects non-port service name")
    func rejectsNonPortServiceName() {
        // A service that has PortTypeDescription but isn't named Port-*
        // (e.g. an internal DRD node) should be filtered out.
        var props = m2MBA_USBC_Disconnected
        props["PortTypeDescription"] = "USB-C"
        let port = USBCPort.from(
            entryID: 1, serviceName: "AppleHPMDevice@38",
            className: "AppleHPMDevice", properties: props
        )
        #expect(port == nil)
    }

    @Test("rejects missing PortTypeDescription")
    func rejectsMissingPortTypeDescription() {
        var props = m2MBA_USBC_Disconnected
        props.removeValue(forKey: "PortTypeDescription")
        let port = USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10", properties: props
        )
        #expect(port == nil)
    }

    @Test("rejects unrecognised port type")
    func rejectsUnrecognisedPortType() {
        // A future class might attach `PortTypeDescription` like "Lightning"
        // -- until we know it's safe, we only accept USB-C and MagSafe*.
        var props = m2MBA_USBC_Disconnected
        props["PortTypeDescription"] = "Lightning"
        let port = USBCPort.from(
            entryID: 1, serviceName: "Port-Lightning@1",
            className: "AppleTCControllerType10", properties: props
        )
        #expect(port == nil)
    }

    @Test("accepts any MagSafe suffix")
    func acceptsAnyMagSafeSuffix() throws {
        // We accept any "MagSafe ..." suffix, not just "MagSafe 3". Future
        // hardware (MagSafe 4?) shouldn't need a code change here.
        var props = m2MBA_MagSafe_Connected
        props["PortTypeDescription"] = "MagSafe 4"
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-MagSafe 4@1",
            className: "AppleTCControllerType11", properties: props
        ))
        #expect(port.portTypeDescription == "MagSafe 4")
    }

    // MARK: - Class-name agnostic

    /// The factory must not filter on className. The watcher's IOKit
    /// match list is what limits which classes get inspected; once a
    /// node makes it to the factory, the className field is just
    /// metadata. Regression guard so adding new class names to the
    /// watcher doesn't accidentally require changes here too.
    @Test("accepts arbitrary className for real port")
    func acceptsArbitraryClassNameForRealPort() throws {
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType99",
            properties: m2MBA_USBC_Disconnected
        ))
        #expect(port.className == "AppleHPMInterfaceType99")
    }

    // MARK: - Property parsing edge cases

    @Test("hex Data fields parse")
    func hexDataFieldsParse() throws {
        var props = m2MBA_USBC_Disconnected
        props["FW Version"] = Data([0x01, 0x02, 0xAB, 0xFF])
        props["Boot Flags"] = Data([0xDE, 0xAD])
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10", properties: props
        ))
        #expect(port.firmwareVersion == "01 02 AB FF")
        #expect(port.bootFlagsHex == "DE AD")
    }

    @Test("hex Data fields nil when missing")
    func hexDataFieldsAreNilWhenMissing() throws {
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10",
            properties: m2MBA_USBC_Disconnected
        ))
        #expect(port.firmwareVersion == nil)
        #expect(port.bootFlagsHex == nil)
    }

    @Test("power current limits parse as ints")
    func powerCurrentLimitsParseAsInts() throws {
        var props = m2MBA_USBC_Disconnected
        props["IOAccessoryPowerCurrentLimits"] = [
            NSNumber(value: 1500), NSNumber(value: 3000),
            NSNumber(value: 4500), NSNumber(value: 0), NSNumber(value: 0)
        ]
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10", properties: props
        ))
        #expect(port.powerCurrentLimits == [1500, 3000, 4500, 0, 0])
    }

    @Test("raw properties capture all keys")
    func rawPropertiesCaptureAllKeys() throws {
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleTCControllerType10",
            properties: m2MBA_USBC_Disconnected
        ))
        // Raw props mirror every key from the input dictionary as a string.
        #expect(port.rawProperties["PortType"] == "2")
        #expect(port.rawProperties["PortNumber"] == "1")
        #expect(port.rawProperties["PortTypeDescription"] == "USB-C")
        #expect(port.rawProperties["ConnectionActive"] == "0")
    }

    @Test("busIndex passed through")
    func busIndexPassedThrough() throws {
        let port = try #require(USBCPort.from(
            entryID: 1, serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            properties: m2MBA_USBC_Disconnected,
            busIndex: 5
        ))
        #expect(port.busIndex == 5)
    }

    // MARK: - portKey disambiguation

    /// USB-C and MagSafe ports sharing the same portNumber must produce
    /// different portKey values. Without this, the diagnostic view can
    /// show data for the wrong port.
    @Test("portKey disambiguates USB-C and MagSafe")
    func portKeyDisambiguatesUSBCAndMagSafe() {
        let usbC = USBCPort(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: ["PortType": "2"]
        )

        let magSafe = USBCPort(
            id: 2,
            serviceName: "Port-MagSafe 3@1",
            className: "AppleHPMInterfaceType11",
            portDescription: "Port-MagSafe 3@1",
            portTypeDescription: "MagSafe 3",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: ["CC"], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: [:]
        )

        // Both have portNumber 1, but portKey must differ.
        #expect(usbC.portNumber == magSafe.portNumber)
        #expect(usbC.portKey != magSafe.portKey,
            "USB-C and MagSafe with same portNumber must have different portKeys")

        // Verify the expected formats: USB-C uses PortType 2, MagSafe uses 0x11 (17).
        #expect(usbC.portKey == "2/1")
        #expect(magSafe.portKey == "17/1")
    }

    /// A port with no portNumber should return nil portKey.
    @Test("portKey nil when no portNumber")
    func portKeyNilWhenNoPortNumber() {
        let port = USBCPort(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: nil,
            connectionActive: nil,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: [:]
        )
        #expect(port.portKey == nil)
    }
}
