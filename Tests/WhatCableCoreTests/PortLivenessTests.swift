import Testing
@testable import WhatCableCore

@Suite("Port Liveness")
struct PortLivenessTests {

    // MARK: - Fixtures

    private func usbCPort(
        connectionActive: Bool = false
    ) -> USBCPort {
        USBCPort(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: nil, portTypeDescription: "USB-C", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func magSafePort(
        connectionActive: Bool = false
    ) -> USBCPort {
        USBCPort(
            id: 1, serviceName: "Port-MagSafe 3@1", className: "AppleHPMInterfaceType11",
            portDescription: nil, portTypeDescription: "MagSafe 3", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func staleUSBPDSource() -> PowerSource {
        PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [],
            winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 1490, maxPowerMW: 29_800)
        )
    }

    private func partnerIdentity() -> USBPDSOP {
        USBPDSOP(
            id: 99, endpoint: .sop,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
    }

    private func usbDevice() -> USBDevice {
        USBDevice(
            id: 42, locationID: 0, vendorID: 0, productID: 0,
            vendorName: nil, productName: nil, serialNumber: nil,
            usbVersion: nil, speedRaw: nil, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    // MARK: - Cases

    @Test("Nothing present is not live")
    func nothingPresentIsNotLive() {
        #expect(!isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    @Test("USB device makes port live")
    func usbDeviceMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [], matchingDevices: [usbDevice()]
        ))
    }

    @Test("USB PD SOP makes port live")
    func usbPDSOPMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [partnerIdentity()], matchingDevices: []
        ))
    }

    @Test("Non-MagSafe connectionActive makes port live")
    func nonMagSafeConnectionActiveMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    // MARK: - Issue #47 regressions

    @Test("Stale power source alone does not make port live")
    func stalePowerSourceAloneDoesNotMakePortLive() {
        // Issue #47: M2 MBA showed disconnected ports as connected because the
        // PowerSourceWatcher held a stale negotiated PDO. The port itself
        // correctly reports connectionActive=false, so the union must not
        // light up purely on the cached source.
        #expect(!isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("Stale power source on disconnected MagSafe is not live")
    func stalePowerSourceOnDisconnectedMagSafeIsNotLive() {
        // The MagSafe port from issue #47's JSON dump: connectionActive=false,
        // but the watcher still exposes a 30W winning PDO from the previous
        // session. Must not be treated as live.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("Power source with active connection is live")
    func powerSourceWithActiveConnectionIsLive() {
        // Charger genuinely plugged in: power source plus an active
        // connection. This is the case we still want to count as live, on
        // both USB-C and MagSafe.
        #expect(isPortLive(
            port: usbCPort(connectionActive: true),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
        #expect(isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("MagSafe connectionActive alone is not live")
    func magSafeConnectionActiveAloneIsNotLive() {
        // The original MagSafe quirk: connectionActive=true lingers for
        // several seconds after unplug. Without any other live signal, we
        // shouldn't trust it.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }
}
