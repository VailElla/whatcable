import Testing
@testable import WhatCableCore

/// Unit tests for the USB3Transport model and its speedLabel computed property.
@Suite("USB3 Transport")
struct USB3TransportTests {

    // MARK: - speedLabel

    @Test("Gen 1 speed label")
    func gen1SpeedLabel() {
        let t = USB3Transport(id: 1, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        #expect(t.speedLabel == "USB 3.2 Gen 1 (5 Gbps)")
    }

    @Test("Gen 2 speed label")
    func gen2SpeedLabel() {
        let t = USB3Transport(id: 2, portKey: "2/1", signaling: 2, signalingDescription: "Gen 2", dataRole: "host")
        #expect(t.speedLabel == "USB 3.2 Gen 2 (10 Gbps)")
    }

    @Test("Unknown signaling falls back to generic label")
    func unknownSignalingFallsBackToGenericLabel() {
        let t = USB3Transport(id: 3, portKey: "2/1", signaling: 5, signalingDescription: nil, dataRole: nil)
        #expect(t.speedLabel == "USB 3.2 Gen 5")
    }

    @Test("Nil signaling returns nil")
    func nilSignalingReturnsNil() {
        let t = USB3Transport(id: 4, portKey: "2/1", signaling: nil, signalingDescription: nil, dataRole: nil)
        #expect(t.speedLabel == nil)
    }

    // MARK: - Equatable / Hashable

    @Test("Equal transports are equal")
    func equalTransportsAreEqual() {
        let a = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        let b = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        #expect(a == b)
    }

    @Test("Different IDs are not equal")
    func differentIDsAreNotEqual() {
        let a = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        let b = USB3Transport(id: 11, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        #expect(a != b)
    }

    @Test("Hashable usable in Set")
    func hashableUsableInSet() {
        let a = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        let b = USB3Transport(id: 11, portKey: "2/2", signaling: 2, signalingDescription: "Gen 2", dataRole: "device")
        let set: Set<USB3Transport> = [a, b, a]
        #expect(set.count == 2)
    }

    // MARK: - Identifiable

    @Test("Identifiable ID")
    func identifiableID() {
        let t = USB3Transport(id: 42, portKey: "2/3", signaling: 1, signalingDescription: nil, dataRole: nil)
        #expect(t.id == 42)
    }
}
