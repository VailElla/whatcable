import Foundation

/// Cable/link data from Apple's CIO (Thunderbolt) transport controller.
///
/// These properties come from `IOPortTransportStateCIO`, which appears
/// dynamically when a Thunderbolt link is active. Most fields in
/// `PORT_CS_18` are cable-state values populated per-connection from
/// VDM exchange during link bring-up, not static port capabilities.
///
/// `cableSpeed` is confirmed across TB3, TB4, and TB5 (see
/// `research/cio-value-mappings.md`). `asymmetricModeSupported` is
/// a cable property (Cable Asymmetric Support from PORT_CS_18.CSA).
/// The integer fields (`cableGeneration`, `generation`) are stored
/// raw; their meaning is not yet confirmed.
public struct CIOCableCapability: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    public let portKey: String

    /// Likely cable Gen 4 capability from `PORT_CS_18.CG4` (bit 21),
    /// populated via VDM during link bring-up. Working hypothesis:
    /// 1 = cable is Gen 3 only, 2 = cable supports Gen 4. Consistent
    /// with all 27 data points but not yet confirmed by controlled
    /// cable swap. Do not derive any user-facing label from it yet.
    public let cableGeneration: Int?
    /// Negotiated link generation from `LANE_ADP_CS_1.CURRENT_SPEED`.
    /// Confirmed: 2 = 20 Gbps (TB3), 3 = 40 Gbps (TB4), 4 = 80 Gbps
    /// (TB5). Reflects the lowest common denominator of host, cable,
    /// and downstream device.
    public let cableSpeed: Int?
    /// Raw CIO value of unknown meaning. NOT a USB4 Gen number and
    /// not a legacy-vs-native flag: probe data is mostly 2 across
    /// TB3, TB4, and TB5 (TB5 included), with occasional 3. Do not
    /// derive any label from it.
    public let generation: Int?
    /// Cable asymmetric-mode capability from `PORT_CS_18.CSA` (bit 22).
    /// This is a cable-state field populated per-connection from VDM
    /// exchange during link bring-up, not a static port capability.
    /// Different cables on the same port produce different values.
    /// Surface as "Cable supports asymmetric mode."
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
