import Testing
@testable import WhatCableCore

/// Phase 3 integration: PortSummary should pull TB fabric data through and
/// emit specific link-state bullets when a port has a matching switch graph.
/// Anchored against Joe's M2 Pro + ASUS PA32QCV (USB4) + CalDigit TS3 Plus
/// daisy-chain from issue #52.
@Suite("Port Summary Thunderbolt")
struct PortSummaryThunderboltTests {

    // MARK: - Fixtures

    private func tbPort(socket: String) -> USBCPort {
        USBCPort(
            id: 1,
            serviceName: "Port-USB-C@\(socket)",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@\(socket)",
            portTypeDescription: "USB-C",
            portNumber: Int(socket),
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CIO"],
            transportsProvisioned: ["CC"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    private func lanePort(
        portNumber: Int,
        socketID: String?,
        speed: LinkGeneration?,
        widthRaw: UInt8
    ) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: speed,
            currentWidth: LinkWidth(rawValue: widthRaw),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
    }

    private func sw(
        uid: Int64,
        depth: Int,
        parent: Int64?,
        upstreamPort: Int = 0,
        vendor: String,
        model: String,
        ports: [IOThunderboltPort]
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: uid,
            className: "IOIOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: vendor,
            modelName: model,
            routerID: 0,
            depth: depth,
            routeString: 0,
            upstreamPortNumber: upstreamPort,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 12),
            ports: ports,
            parentSwitchUID: parent
        )
    }

    // MARK: - Single-hop (host + one device)

    @Test("Host USB4 link produces specific bullet")
    func hostUsb4LinkProducesSpecificBullet() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        let device = sw(
            uid: 200, depth: 1, parent: 100, upstreamPort: 1,
            vendor: "ASUS-Display", model: "PA32QCV",
            ports: [lanePort(portNumber: 1, socketID: nil, speed: .usb4Tb4, widthRaw: 0x2)]
        )

        let summary = PortSummary(
            port: port,
            thunderboltSwitches: [host, device]
        )

        #expect(
            summary.bullets.contains("Linked at up to 20 Gb/s × 2"),
            "expected USB4 link label, got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains("Connected to ASUS-Display PA32QCV"),
            "expected single-hop device label, got: \(summary.bullets)"
        )
    }

    @Test("TB3 link produces TB3 bullet")
    func tb3LinkProducesTb3Bullet() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .tb3, widthRaw: 0x2)]
        )

        let summary = PortSummary(port: port, thunderboltSwitches: [host])
        #expect(summary.bullets.contains("Linked at up to 10 Gb/s × 2"))
    }

    // MARK: - Daisy-chain step-down (the headline UX)

    @Test("Daisy chain step-down is surfaced")
    func daisyChainStepDownIsSurfaced() {
        // Joe's topology: USB4 to ASUS, TS3 Plus daisy-chained off the
        // ASUS at TB3 single-lane.
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        let asus = sw(
            uid: 200, depth: 1, parent: 100, upstreamPort: 1,
            vendor: "ASUS-Display", model: "PA32QCV",
            ports: [
                lanePort(portNumber: 1, socketID: nil, speed: .usb4Tb4, widthRaw: 0x2),
                lanePort(portNumber: 4, socketID: nil, speed: .tb3, widthRaw: 0x1)
            ]
        )
        let ts3 = sw(
            uid: 300, depth: 2, parent: 200, upstreamPort: 1,
            vendor: "CalDigit, Inc.", model: "TS3 Plus",
            ports: [lanePort(portNumber: 1, socketID: nil, speed: .tb3, widthRaw: 0x1)]
        )

        let summary = PortSummary(
            port: port,
            thunderboltSwitches: [host, asus, ts3]
        )

        #expect(
            summary.bullets.contains("Linked at up to 20 Gb/s × 2"),
            "host link bullet missing; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains("Connected via 2 hops: ASUS-Display PA32QCV → CalDigit, Inc. TS3 Plus"),
            "daisy-chain device list missing; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains { $0.contains("Last leg drops from up to 20 Gb/s × 2 to up to 10 Gb/s × 1") },
            "step-down bullet missing; got: \(summary.bullets)"
        )
    }

    // MARK: - Single-hop must NOT trigger step-down

    /// Regression: in Steve's TB3 sample, the host port reports
    /// `Current Link Width = 2` while the Samsung's upstream port reports
    /// `Current Link Width = 1` for the same physical cable. That's just
    /// the controller-side view aggregating lanes the device-side view
    /// doesn't; it's not a real step-down. Step-down only fires for
    /// daisy-chains with two or more downstream switches.
    @Test("Single hop does not emit step-down")
    func singleHopDoesNotEmitStepDown() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .tb3, widthRaw: 0x2)]
        )
        // Samsung-style single device: upstream port reports the same
        // link from the device side with a different width value.
        let samsung = sw(
            uid: 200, depth: 1, parent: 100, upstreamPort: 1,
            vendor: "SAMSUNG ELECTRONICS CO.,LTD", model: "C34J79x",
            ports: [lanePort(portNumber: 1, socketID: nil, speed: .tb3, widthRaw: 0x1)]
        )

        let summary = PortSummary(port: port, thunderboltSwitches: [host, samsung])
        #expect(
            summary.bullets.contains { $0.contains("Last leg drops") } == false,
            "single-hop must not emit step-down warning; got: \(summary.bullets)"
        )
        // Sanity: the single-hop bullets we DO want should still be there.
        #expect(
            summary.bullets.contains("Connected to SAMSUNG ELECTRONICS CO.,LTD C34J79x"),
            "device label still required"
        )
    }

    // MARK: - Fallback when no matching switch is found

    @Test("Falls back to generic label when no matching switch")
    func fallsBackToGenericLabelWhenNoMatchingSwitch() {
        let port = tbPort(socket: "1")
        // Switch list is empty: PortSummary should fall back to the
        // pre-Phase-3 generic line so we don't regress on machines without
        // the watcher data.
        let summary = PortSummary(port: port, thunderboltSwitches: [])
        #expect(
            summary.bullets.contains("Thunderbolt / USB4 link active"),
            "expected fallback bullet when no switch data; got: \(summary.bullets)"
        )
    }

    // MARK: - TB5 confirmed (issue #52: M5 Pro + UGreen JHL9580 dock)

    @Test("TB5 link renders with per-lane label")
    func tb5LinkRendersWithPerLaneLabel() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .tb5, widthRaw: 0x2)]
        )
        let summary = PortSummary(port: port, thunderboltSwitches: [host])
        #expect(
            summary.bullets.contains { $0.contains("40 Gb/s") },
            "TB5 should report per-lane 40 Gb/s; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains { $0.contains("Unknown generation") } == false,
            "TB5 should no longer be hedged; got: \(summary.bullets)"
        )
    }

    // MARK: - Passive e-marker + active TB link (issue #111)

    /// TB4 cables from CalDigit/Cable Matters report as passive in USB-PD
    /// because their active components condition the Thunderbolt signal path,
    /// not the USB path. When the TB link is live and the e-marker says
    /// passive, PortSummary should add a clarifying note.
    private func passiveCableIdentity() -> USBPDSOP {
        // ID Header VDO[0]: ufpProductType = 3 (passiveCable), VID = 0x2B1D
        let idHeader: UInt32 = (3 << 27) | 0x2B1D
        // Cable VDO[3]: USB 3.2 Gen 2 (speed=2), 5A current (bits 5..6 = 2),
        // latency = 1 (bits 13..16)
        let cableVDO: UInt32 = 0b010 | (2 << 5) | (1 << 13)
        return USBPDSOP(
            id: 99, endpoint: .sopPrime,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0x2B1D, productID: 0x1901, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 3
        )
    }

    @Test("Passive e-marker with active TB link shows clarification")
    func passiveEmarkerWithActiveTBLinkShowsClarification() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        let cable = passiveCableIdentity()

        let summary = PortSummary(
            port: port,
            identities: [cable],
            thunderboltSwitches: [host]
        )

        #expect(
            summary.bullets.contains { $0.contains("E-marker reports passive") && $0.contains("Thunderbolt") },
            "expected passive-but-TB clarification bullet; got: \(summary.bullets)"
        )
    }

    @Test("Passive e-marker without TB link does not show clarification")
    func passiveEmarkerWithoutTBLinkDoesNotShowClarification() {
        let port = USBCPort(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: true,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["USB3"],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
        let cable = passiveCableIdentity()

        let summary = PortSummary(port: port, identities: [cable])

        #expect(
            summary.bullets.contains { $0.contains("E-marker reports passive") } == false,
            "passive cable on non-TB port should not show TB clarification; got: \(summary.bullets)"
        )
    }

    // MARK: - CIO cable capability (issue #111)

    /// When CIO data is present with a known speed code, PortSummary should
    /// replace the generic passive/TB fallback with a "Controller confirms"
    /// bullet plus an explanation of why the e-marker says passive.
    @Test("CIO confirms TB cable replaces passive bullet")
    func cioConfirmsTBCableReplacesPassiveBullet() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        let cable = passiveCableIdentity()
        let cio = CIOCableCapability(
            id: 1, portKey: "1",
            cableGeneration: 2, cableSpeed: 3, generation: 3,
            asymmetricModeSupported: false, legacyAdapter: false,
            linkTrainingMode: nil
        )

        let summary = PortSummary(
            port: port,
            identities: [cable],
            thunderboltSwitches: [host],
            cioCapability: cio
        )

        #expect(
            summary.bullets.contains { $0.contains("Controller confirms Thunderbolt cable") && $0.contains("40 Gbps") },
            "expected CIO confirmation bullet; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains { $0.contains("E-marker reports passive. This is normal") },
            "expected educational explanation bullet; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains { $0.contains("Thunderbolt is negotiated separately") } == false,
            "old fallback bullet should be gone when CIO confirms; got: \(summary.bullets)"
        )
    }

    /// When CIO data is present but the speed code is unrecognised, fall back
    /// to the existing passive/TB clarification (don't leak raw codes).
    @Test("CIO with unknown speed code falls back to passive bullet")
    func cioWithUnknownSpeedCodeFallsBackToPassiveBullet() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        let cable = passiveCableIdentity()
        // Speed code 99 is not in our confirmed mapping.
        let cio = CIOCableCapability(
            id: 1, portKey: "1",
            cableGeneration: nil, cableSpeed: 99, generation: nil,
            asymmetricModeSupported: nil, legacyAdapter: nil,
            linkTrainingMode: nil
        )

        let summary = PortSummary(
            port: port,
            identities: [cable],
            thunderboltSwitches: [host],
            cioCapability: cio
        )

        #expect(
            summary.bullets.contains { $0.contains("E-marker reports passive") && $0.contains("Thunderbolt is negotiated separately") },
            "unknown CIO speed should fall back to passive/TB clarification; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains { $0.contains("Controller confirms") } == false,
            "should not show CIO confirmation for unknown speed code; got: \(summary.bullets)"
        )
    }

    /// When CIO data exists but has no cableSpeed at all, fall back.
    @Test("CIO with nil speed falls back to passive bullet")
    func cioWithNilSpeedFallsBackToPassiveBullet() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        let cable = passiveCableIdentity()
        let cio = CIOCableCapability(
            id: 1, portKey: "1",
            cableGeneration: nil, cableSpeed: nil, generation: nil,
            asymmetricModeSupported: nil, legacyAdapter: nil,
            linkTrainingMode: nil
        )

        let summary = PortSummary(
            port: port,
            identities: [cable],
            thunderboltSwitches: [host],
            cioCapability: cio
        )

        #expect(
            summary.bullets.contains { $0.contains("Thunderbolt is negotiated separately") },
            "nil CIO speed should fall back; got: \(summary.bullets)"
        )
    }

    @Test("Active cable with TB link does not show passive note")
    func activeCableWithTBLinkDoesNotShowPassiveNote() {
        let port = tbPort(socket: "1")
        let host = sw(
            uid: 100, depth: 0, parent: nil,
            vendor: "Apple Inc.", model: "iOS",
            ports: [lanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)]
        )
        // ID Header VDO[0]: ufpProductType = 4 (activeCable)
        let idHeader: UInt32 = (4 << 27) | 0x05AC
        let cableVDO: UInt32 = 0b011 | (2 << 5) | (1 << 13)
        let cable = USBPDSOP(
            id: 99, endpoint: .sopPrime,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 3
        )

        let summary = PortSummary(
            port: port,
            identities: [cable],
            thunderboltSwitches: [host]
        )

        #expect(
            summary.bullets.contains { $0.contains("E-marker reports passive") } == false,
            "active cable should not show passive note; got: \(summary.bullets)"
        )
        #expect(
            summary.bullets.contains { $0.contains("Active cable") },
            "active cable should show active label; got: \(summary.bullets)"
        )
    }
}
