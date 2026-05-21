import Foundation

/// Cable capability data from Apple's CIO (Thunderbolt) transport controller.
///
/// These properties come from `IOPortTransportStateCIO`, which appears
/// dynamically when a Thunderbolt link is active. They represent the TB
/// controller's own assessment of the cable, independent of the USB-PD
/// e-marker. This matters because some active TB4 cables (e.g. CalDigit
/// 2M) report "passive" in their e-marker while the CIO controller
/// correctly identifies their TB capability.
///
/// `cableSpeed` is the genuine cable-capability signal and is now
/// confirmed across TB3, TB4, and TB5 from real CIO probes (see
/// `research/cio-value-mappings.md` for the data points). The other
/// integer fields (`cableGeneration`, `generation`) do NOT track the
/// Thunderbolt generation: probe data shows them varying per port
/// within a single machine, including across identical TB4 links.
/// Their meaning is unknown. They are stored raw and not used to
/// derive any user-facing label.
public struct CIOCableCapability: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    public let portKey: String

    /// Raw CIO value of unknown meaning. NOT a Thunderbolt generation
    /// counter: one M4 machine reported 1, 2, 2 across three TB4 CIO
    /// entries, and value 1 also appears on TB4 links (M4/M5/M3 Max/
    /// M1 Max), not only TB3. Do not derive any label from it.
    public let cableGeneration: Int?
    /// Cable speed capability from the CIO controller. The one CIO
    /// field that genuinely tracks the cable, not the downstream
    /// device. Confirmed: 2 = TB3 / 20 Gbps, 3 = TB4 / 40 Gbps,
    /// 4 = TB5 / 80 Gbps.
    public let cableSpeed: Int?
    /// Raw CIO value of unknown meaning. NOT a USB4 Gen number and
    /// not a legacy-vs-native flag: probe data is mostly 2 across
    /// TB3, TB4, and TB5 (TB5 included), with occasional 3. Do not
    /// derive any label from it.
    public let generation: Int?
    /// Static port-capability advertisement from `PORT_CS_18.CSA`
    /// (per the Linux thunderbolt driver's `usb4_port_asym_supported`).
    /// It says "this lane adapter type advertises asymmetric capability,"
    /// not "this Mac will actually negotiate asymmetric mode." Apple
    /// Silicon sets the bit across the family, including on Type5
    /// (TB4-only) hosts that cannot run the Gen 4 link speeds asymmetric
    /// mode needs. Surface as "Port advertises asymmetric capability"
    /// rather than "Host supports asymmetric mode."
    public let asymmetricModeSupported: Bool?
    /// Raw CIO flag. Observed `false` on every sampled connection,
    /// including a real TB3 dock (M1 Max + ThinkPad TB3). The earlier
    /// "true for TB3" reading is disproven; the meaning of a `true`
    /// value is unobserved. Do not rely on it.
    public let legacyAdapter: Bool?
    /// Link training mode reported by CIO. Meaning TBD.
    public let linkTrainingMode: Int?

    public init(
        id: UInt64,
        portKey: String,
        cableGeneration: Int?,
        cableSpeed: Int?,
        generation: Int?,
        asymmetricModeSupported: Bool?,
        legacyAdapter: Bool?,
        linkTrainingMode: Int?
    ) {
        self.id = id
        self.portKey = portKey
        self.cableGeneration = cableGeneration
        self.cableSpeed = cableSpeed
        self.generation = generation
        self.asymmetricModeSupported = asymmetricModeSupported
        self.legacyAdapter = legacyAdapter
        self.linkTrainingMode = linkTrainingMode
    }

    /// Human-readable speed label for a confirmed `cableSpeed` value,
    /// or `nil` when the code is unrecognised.
    ///
    /// Maps the CIO `cableSpeed` codes confirmed by real probes
    /// spanning TB3, TB4, and TB5 (2 = 20 Gbps, 3 = 40 Gbps,
    /// 4 = 80 Gbps; see `research/cio-value-mappings.md`). Returns
    /// `nil` for unknown codes so callers can fall back to a generic
    /// bullet rather than leaking raw IOKit numbers into user-facing
    /// text.
    public static func speedLabel(for cableSpeed: Int) -> String? {
        switch cableSpeed {
        case 2: return String(localized: "20 Gbps capable", bundle: _coreLocalizedBundle)
        case 3: return String(localized: "40 Gbps capable", bundle: _coreLocalizedBundle)
        case 4: return String(localized: "80 Gbps capable", bundle: _coreLocalizedBundle)
        default: return nil
        }
    }
}
