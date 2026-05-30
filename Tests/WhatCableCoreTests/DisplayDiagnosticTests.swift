import Foundation
import Testing
@testable import WhatCableCore

@Suite("Display Diagnostic")
struct DisplayDiagnosticTests {

    // MARK: - Fixtures

    /// The G34w-10 as parsed by EDIDInfo: preferred 3440x1440@60, ceiling
    /// 100Hz / 600 MHz. 600e6 x 24bpp = 14.4 Gbps usable needed.
    private let g34w = EDIDInfo(
        monitorName: "LEN G34w-10",
        versionMajor: 1, versionMinor: 3,
        preferredWidth: 3440, preferredHeight: 1440, preferredRefreshHz: 60,
        preferredPixelClockHz: 319_890_000,
        maxRefreshHz: 100, maxPixelClockHz: 600_000_000
    )

    private func makeDP(
        active: Bool = true,
        lanes: Int = 4,
        maxLanes: Int = 4,
        rateDesc: String? = "5.4 Gbps (HBR2)",
        tunneled: Bool = false,
        dfpType: String? = nil,
        branchDeviceId: String? = nil,
        edidData: Data? = nil
    ) -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: active,
                laneCount: lanes,
                maxLaneCount: maxLanes,
                linkRate: 3,
                linkRateDescription: rateDesc,
                tunneled: tunneled,
                hpdState: 1
            ),
            monitor: edidData.map {
                MonitorInfo(
                    manufacturerName: nil, productName: nil, productId: nil,
                    yearOfManufacture: nil, edid: $0
                )
            },
            dfpType: dfpType,
            branchDeviceId: branchDeviceId
        )
    }

    /// A cable e-marker (SOP') whose ID header product type marks it active
    /// (4) or passive (3). The cable VDO value itself is irrelevant here; the
    /// active/passive flag comes from the header.
    private func cable(active: Bool) -> USBPDSOP {
        let header: UInt32 = (active ? 4 : 3) << 27
        return USBPDSOP(
            id: 1, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [header, 0, 0, 0],
            specRevision: 0
        )
    }

    // MARK: - Core verdicts

    @Test("4-lane HBR2 carries the G34w-10's 100Hz mode: fine")
    func fourLaneFits() throws {
        // delivered = 4 x 5.4 x 0.8 = 17.28 Gbps usable >= 14.4 needed.
        let diag = try #require(DisplayDiagnostic(dp: makeDP(lanes: 4), edid: g34w))
        #expect(diag.bottleneck == .fine)
        #expect(diag.isWarning == false)
        #expect(diag.facts.deliveredGbps.map { $0 > 17 } == true)
    }

    @Test("2-lane HBR2 falls short of the 100Hz mode: belowMonitorMax")
    func twoLaneShortfall() throws {
        // delivered = 2 x 5.4 x 0.8 = 8.64 Gbps usable < 14.4 needed.
        let diag = try #require(DisplayDiagnostic(dp: makeDP(lanes: 2), edid: g34w))
        #expect(diag.bottleneck == .belowMonitorMax)
        #expect(diag.isWarning == true)
        #expect(diag.facts.lanes == 2)
        #expect(diag.facts.maxLanes == 4)
        // 2 of 4 lanes, not tunneled: we can't exonerate the cable.
        #expect(diag.cableAssessment == .inconclusive)
        // Non-accusatory: never names the cable as the definite culprit.
        #expect(!diag.detail.lowercased().contains("the cable is the limit"))
    }

    // MARK: - Cable attribution

    @Test("Tunneled shortfall exonerates the cable")
    func tunneledExonerates() throws {
        // DP tunneled over TB/USB4: the cable carries far more than DP needs.
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2, tunneled: true), edid: g34w)
        )
        #expect(diag.bottleneck == .belowMonitorMax)
        #expect(diag.cableAssessment == .unlikelyTheCable)
        #expect(diag.detail.lowercased().contains("tunnel"))
        #expect(diag.detail.lowercased().contains("unlikely to be the cable"))
    }

    @Test("All host lanes in use on a passive cable exonerates it")
    func allLanesExonerates() throws {
        // 4 of 4 lanes but a low rate (RBR) leaves the 100Hz mode short.
        // The cable carries every lane, so it isn't lane-limiting.
        let dp = makeDP(lanes: 4, maxLanes: 4, rateDesc: "1.62 Gbps (RBR)")
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: g34w, cable: cable(active: false)))
        #expect(diag.bottleneck == .belowMonitorMax)
        #expect(diag.cableAssessment == .unlikelyTheCable)
        #expect(diag.detail.lowercased().contains("every displayport lane"))
    }

    @Test("Active cable is NOT exonerated on the lane signal (issue #111)")
    func activeCableNotExonerated() throws {
        // Same all-lanes shortfall, but the cable is active. Active cables can
        // misreport, so the lane signal alone must not exonerate them.
        let dp = makeDP(lanes: 4, maxLanes: 4, rateDesc: "1.62 Gbps (RBR)")
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: g34w, cable: cable(active: true)))
        #expect(diag.bottleneck == .belowMonitorMax)
        #expect(diag.cableAssessment == .inconclusive)
    }

    @Test("Unidentified cable (no e-marker) at all lanes stays inconclusive")
    func noEmarkerNotExonerated() throws {
        // All host lanes in use but no e-marker: we can't vouch for an
        // unidentified cable (it could be a cheap passive cable rate-limiting
        // the link), so the lane signal alone must not exonerate it.
        let dp = makeDP(lanes: 4, maxLanes: 4, rateDesc: "1.62 Gbps (RBR)")
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: g34w, cable: nil))
        #expect(diag.cableAssessment == .inconclusive)
    }

    @Test("Tunneled exonerates even an active cable")
    func tunneledBeatsActive() throws {
        // The tunnel itself proves capability, independent of the e-marker.
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2, tunneled: true), edid: g34w, cable: cable(active: true))
        )
        #expect(diag.cableAssessment == .unlikelyTheCable)
    }

    @Test("Shortfall behind an HDMI adapter: adapterLimit, not cable blame")
    func adapterShortfall() throws {
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2, dfpType: "HDMI"), edid: g34w)
        )
        #expect(diag.bottleneck == .adapterLimit)
        #expect(diag.facts.sinkType == "HDMI")
        #expect(diag.summary.contains("HDMI"))
    }

    @Test("An HDMI adapter that still fits is fine, no adapter blame")
    func adapterButFits() throws {
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 4, dfpType: "HDMI"), edid: g34w)
        )
        #expect(diag.bottleneck == .fine)
    }

    @Test("Live link with no readable EDID: unknownMode, blames nothing")
    func noEDID() throws {
        let diag = try #require(DisplayDiagnostic(dp: makeDP(lanes: 2), edid: nil))
        #expect(diag.bottleneck == .unknownMode)
        #expect(diag.isWarning == false)
    }

    @Test("No active DisplayPort link returns nil (port stays silent)")
    func inactiveLinkIsNil() {
        #expect(DisplayDiagnostic(dp: makeDP(active: false), edid: g34w) == nil)
    }

    @Test("Unparseable link rate degrades to unknownMode, no false alarm")
    func unparseableRate() throws {
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2, rateDesc: "No Link"), edid: g34w)
        )
        #expect(diag.bottleneck == .unknownMode)
    }

    // MARK: - Production path (parses EDID from the node's monitor blob)

    @Test("init(dp:) parses the embedded EDID end to end")
    func parsesEmbeddedEDID() throws {
        let edidData = Data(EDIDInfoTests.g34wBaseBlock)
        let diag = try #require(DisplayDiagnostic(dp: makeDP(lanes: 4, edidData: edidData)))
        #expect(diag.bottleneck == .fine)
        #expect(diag.facts.monitorName == "LEN G34w-10")
        #expect(diag.facts.maxRefreshHz == 100)
    }

    // MARK: - Helpers

    @Test("portKey joins the DP node to its owning port (probe 17 values)")
    func portKeyCorrelation() {
        // Probe 17's active display reports ParentPortType 2 (USB-C) and
        // ParentPortNumber 4, which must join to a port whose portKey is
        // "2/4" (the PowerSource / AppleHPMInterface scheme).
        let dp = IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: true, laneCount: 4, maxLaneCount: 4, linkRate: 3,
                linkRateDescription: "5.4 Gbps (HBR2)", tunneled: false, hpdState: 1
            ),
            monitor: nil,
            parentPortType: 2,
            parentPortNumber: 4
        )
        #expect(dp.portKey == "2/4")
    }

    // MARK: - Branch device

    @Test("Names the adapter's reported DisplayPort version in the verdict")
    func adapterNamesBranchDevice() throws {
        // The real G34w case: HDMI adapter reporting "Dp1.2", 2 of 4 lanes.
        let dp = makeDP(lanes: 2, dfpType: "HDMI", branchDeviceId: "Dp1.2")
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: g34w))
        #expect(diag.bottleneck == .adapterLimit)
        #expect(diag.facts.branchDevice == "DisplayPort 1.2")
        #expect(diag.detail.contains("DisplayPort 1.2"))
    }

    @Test("Adapter with no branch device keeps the plain wording")
    func adapterNoBranchDevice() throws {
        let dp = makeDP(lanes: 2, dfpType: "HDMI", branchDeviceId: nil)
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: g34w))
        #expect(diag.bottleneck == .adapterLimit)
        #expect(diag.facts.branchDevice == nil)
        #expect(!diag.detail.contains("reports as"))
    }

    @Test("branchDeviceLabel normalises the Dp version and falls back safely")
    func branchDeviceLabelParse() {
        #expect(DisplayDiagnostic.branchDeviceLabel("Dp1.2") == "DisplayPort 1.2")
        #expect(DisplayDiagnostic.branchDeviceLabel("DP2.1") == "DisplayPort 2.1")
        #expect(DisplayDiagnostic.branchDeviceLabel("  Dp 1.4 ") == "DisplayPort 1.4")
        #expect(DisplayDiagnostic.branchDeviceLabel("CustomHub") == "CustomHub")
        #expect(DisplayDiagnostic.branchDeviceLabel("dp") == "dp")
        #expect(DisplayDiagnostic.branchDeviceLabel("") == nil)
        #expect(DisplayDiagnostic.branchDeviceLabel(nil) == nil)
    }

    @Test("Parses per-lane Gbps from the macOS rate description")
    func parsesRate() {
        #expect(DisplayDiagnostic.perLaneGbps(fromDescription: "5.4 Gbps (HBR2)") == 5.4)
        #expect(DisplayDiagnostic.perLaneGbps(fromDescription: "8.1 Gbps (HBR3)") == 8.1)
        #expect(DisplayDiagnostic.perLaneGbps(fromDescription: "20 Gbps (UHBR20)") == 20)
        #expect(DisplayDiagnostic.perLaneGbps(fromDescription: "No Link") == nil)
        #expect(DisplayDiagnostic.perLaneGbps(fromDescription: nil) == nil)
    }

    // MARK: - Live sample: LG UltraFine 4K over a tunnelled DP link

    @Test("Live LG UltraFine 4K on tunnelled 4-lane HBR2: fine, cable exonerated")
    func liveLGUltraFineTunnelled() throws {
        // Real capture (M3 Max, Test Kit probe 33, 2026-05-30): a native-DP LG
        // UltraFine 4K reached over a Thunderbolt/USB4 tunnel at 4 lanes HBR2.
        // End to end from the real EDID bytes: 600 MHz x 24bpp = 14.4 Gbps
        // needed, 4 x 5.4 x 0.8 = 17.3 delivered, so the link carries the top
        // mode. The first live tunnelled sample, so it also exercises the
        // tunnelled cable-exoneration path that only synthetic tests hit before.
        let edid = Data(EDIDInfoTests.hexBytes(EDIDInfoTests.lgUltraFineHex))
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 4, tunneled: true, edidData: edid))
        )
        #expect(diag.bottleneck == .fine)
        #expect(diag.cableAssessment == .unlikelyTheCable)
        #expect(diag.facts.monitorName == "LG UltraFine")
        #expect(diag.facts.lanes == 4)
    }

    // MARK: - Billboard-device note (gated on a degraded link)

    @Test("Billboard note fires only with a below-best-mode link present")
    func billboardNoteOnShortfall() throws {
        // 2-lane HBR2 falls short of the G34w's 100Hz mode -> belowMonitorMax,
        // and a Billboard device is on the port: the note should appear.
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2), edid: g34w, billboardPresent: true)
        )
        #expect(diag.bottleneck == .belowMonitorMax)
        #expect(diag.billboardNote != nil)
    }

    @Test("Billboard note fires behind a degraded adapter link too")
    func billboardNoteOnAdapterShortfall() throws {
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2, dfpType: "HDMI"), edid: g34w, billboardPresent: true)
        )
        #expect(diag.bottleneck == .adapterLimit)
        #expect(diag.billboardNote != nil)
    }

    @Test("No Billboard note when the link already carries the top mode")
    func noBillboardNoteWhenFine() throws {
        // 4-lane HBR2 carries the full 100Hz mode -> .fine. Even with a
        // Billboard device present, the diagnosis must not fire: a Billboard
        // device on a healthy link is benign.
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 4), edid: g34w, billboardPresent: true)
        )
        #expect(diag.bottleneck == .fine)
        #expect(diag.billboardNote == nil)
    }

    @Test("No Billboard note when the mode can't be compared")
    func noBillboardNoteWhenUnknown() throws {
        // No readable EDID -> .unknownMode: we can't claim "below best mode",
        // so the corroborating signal is absent and the note stays silent.
        let diag = try #require(
            DisplayDiagnostic(dp: makeDP(lanes: 2), edid: nil, billboardPresent: true)
        )
        #expect(diag.bottleneck == .unknownMode)
        #expect(diag.billboardNote == nil)
    }

    @Test("No Billboard note when no Billboard device is present")
    func noBillboardNoteWhenAbsent() throws {
        // Degraded link, but billboardPresent defaults to false: no note. This
        // is also the inline path's behaviour (it never passes the flag).
        let diag = try #require(DisplayDiagnostic(dp: makeDP(lanes: 2), edid: g34w))
        #expect(diag.bottleneck == .belowMonitorMax)
        #expect(diag.billboardNote == nil)
    }
}
