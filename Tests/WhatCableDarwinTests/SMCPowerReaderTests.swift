import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

/// Pure-logic tests for the desktop SMC power path. The live IOKit reads need
/// hardware, but the FourCC packing, UUID normalisation, channel-to-sample
/// conversion, and the struct-layout guard are all unit-testable.
struct SMCPowerReaderTests {

    @Test("FourCC packs a 4-char SMC key MSB-first")
    func fourCCPacksKey() {
        // 'D'=0x44 '1'=0x31 'J'=0x4A 'V'=0x56
        #expect(SMCPowerReader.fourCC("D1JV") == 0x4431_4A56)
        #expect(SMCPowerReader.fourCC("D4UI") == 0x4434_5549)
    }

    @Test("FourCC rejects keys that are not exactly four ASCII chars")
    func fourCCRejectsBadKeys() {
        #expect(SMCPowerReader.fourCC("D1J") == nil)
        #expect(SMCPowerReader.fourCC("D1JVX") == nil)
        #expect(SMCPowerReader.fourCC("D1J€") == nil)
    }

    @Test("Float decode roundtrips a finite SMC flt payload")
    func decodeFloatFinite() {
        // 5.18 as little-endian IEEE-754 bytes.
        let bytes = withUnsafeBytes(of: Float(5.18).bitPattern.littleEndian) { Array($0) }
        #expect(SMCPowerReader.decodeFloat(bytes) == 5.18)
        #expect(SMCPowerReader.decodeFloat([0, 0, 0, 0]) == 0)
    }

    @Test("Float decode rejects non-finite and short payloads")
    func decodeFloatRejectsGarbage() {
        // An uninitialised channel can carry inf/NaN bit patterns; letting
        // them through would trap in the Int() unit conversions downstream
        // (PowerTelemetryWatcher mV/mA/mW). nil routes them into the same
        // `?? 0` fallback as an absent key.
        func bytes(_ f: Float) -> [UInt8] {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) }
        }
        #expect(SMCPowerReader.decodeFloat(bytes(.infinity)) == nil)
        #expect(SMCPowerReader.decodeFloat(bytes(-.infinity)) == nil)
        #expect(SMCPowerReader.decodeFloat(bytes(.nan)) == nil)
        #expect(SMCPowerReader.decodeFloat([]) == nil)
        #expect(SMCPowerReader.decodeFloat([0x00, 0x00, 0xA6]) == nil)
    }

    @Test("Constructing the reader does not trip the 80-byte struct assertion")
    func structLayoutIsCorrect() {
        // The init() precondition fires (in debug) if SMCParamStruct ever stops
        // being 80 bytes, which the AppleSMC ABI requires.
        _ = SMCPowerReader()
    }

    @Test("HPM UUID normalisation strips dashes and lowercases")
    func uuidNormalisation() {
        #expect(
            HPMPortUUIDMap.normalise("17BD562D-D913-3441-0CD9-435CAC6CFA51")
                == "17bd562dd91334410cd9435cac6cfa51"
        )
        // Already-normalised SMC-style input is unchanged.
        #expect(
            HPMPortUUIDMap.normalise("6230af2dee59552ee28a652ccc0e7b11")
                == "6230af2dee59552ee28a652ccc0e7b11"
        )
    }

    @Test("SMC channel converts to a live per-port sample on the right port")
    func smcChannelToSample() {
        let channel = SMCPortPowerChannel(
            channel: 3,
            present: true,
            volts: 5.18,
            amps: 0.643,
            uuid: "17bd562dd91334410cd9435cac6cfa51"
        )
        // The channel's UUID maps to physical port @4 (the non-positional case).
        let sample = PowerTelemetryWatcher.smcPortSample(channel: channel, portKey: "2/4")

        #expect(sample.portKey == "2/4")
        #expect(sample.portIndex == 4)
        #expect(sample.configuredVoltage == 5180)   // mV
        #expect(sample.current == 643)              // mA
        #expect(sample.watts == 3331)               // mW, 5.18 x 0.643 x 1000
        #expect(sample.isSMCMeasured)
        // It is a live measured reading, not a contracted-max fallback, so the
        // UI shows real volts rather than the "--" placeholder.
        #expect(!sample.isContractedFallback)
        #expect(sample.adapterVoltage == 0)
    }

    @Test("SMC DC-in reading converts to the System Power sample in mV/mA/mW")
    func smcSystemSampleConversion() {
        // Mac mini M4 corpus values: 12.55 V / 1.83 A / 22.91 W DC-in.
        let input = SMCSystemPowerInput(volts: 12.55, amps: 1.83, watts: 22.91)
        let now = Date()
        let sample = PowerTelemetryWatcher.smcSystemSample(input, timestamp: now)

        #expect(sample.systemVoltageIn == 12550)   // mV
        #expect(sample.systemCurrentIn == 1830)    // mA
        #expect(sample.systemPowerIn == 22910)     // mW
        #expect(sample.timestamp == now)
    }

    @Test("MagSafe channel keeps the MagSafe port-type prefix in its key")
    func smcChannelMagSafeKey() {
        let channel = SMCPortPowerChannel(
            channel: 4, present: true, volts: 9.0, amps: 1.0,
            uuid: "7c30af2dcc717d205287c77db8476817"
        )
        let sample = PowerTelemetryWatcher.smcPortSample(channel: channel, portKey: "17/1")
        #expect(sample.portKey == "17/1")
        #expect(sample.portIndex == 1)
        #expect(sample.watts == 9000)
    }
}
