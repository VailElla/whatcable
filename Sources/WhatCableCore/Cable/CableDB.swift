import Foundation
import SQLite3

/// Read-only SQLite-backed lookup for vendors and known cables.
///
/// Loaded lazily on first use from the bundled `whatcable.db`. All rows
/// are read into in-memory dictionaries on init, then the database handle
/// is closed. For ~14k vendors and a handful of cables this is a few
/// hundred KB of resident memory, same as the old TSV loader.
///
/// Uses the system SQLite3 C API (a macOS system framework), so there's
/// no SPM dependency to add.
public enum CableDB {
    /// Vendor entry with provenance tracking.
    struct VendorEntry {
        let name: String
        /// "usbif", "usbids", or "manual".
        let source: String
    }

    private static let store: Store = Store.load()

    /// Look up a vendor name by VID. Returns names from any source
    /// (USB-IF, usb.ids, manual). Returns nil for unknown VIDs and
    /// for VID 0 (which is filtered at the presentation layer by
    /// `VendorDB`, not here).
    public static func vendorName(vid: Int) -> String? {
        store.vendors[vid]?.name
    }

    /// True only if the VID is in USB-IF's official published list.
    /// Used by `CableTrustReport` to decide whether to fire the
    /// `vidNotInUSBIFList` flag. A VID present via usb.ids or manual
    /// override returns false here, preserving the trust signal
    /// semantics.
    public static func isUSBIFRegistered(_ vid: Int) -> Bool {
        store.vendors[vid]?.source == "usbif"
    }

    /// Look up known cables by identity: the (VID, PID) pair.
    ///
    /// Identity is the VID + PID only. The Cable VDO is deliberately NOT
    /// part of the key: it encodes capability (speed / power / type), not
    /// identity, and the same VDO is shared by unrelated brands (a generic
    /// "USB 2.0 / 100 W" VDO appears across Anker, iottie, Statik, and many
    /// more). Keying a brand/model match on it mislabels cables. See #239.
    ///
    /// A cable missing either half of its identity cannot be pinned to a
    /// brand, so a zero VID or zero PID returns an empty array. (A non-zero
    /// VID with a zero PID still resolves the silicon vendor via VendorDB,
    /// but never a curated retail brand.) The all-zero case (#161) is
    /// covered by the same guard.
    ///
    /// Multiple entries can still share one (VID, PID) when the same product
    /// was reported more than once; the caller decides how to present them.
    public static func curatedCables(
        vid: Int,
        pid: Int
    ) -> [CuratedCable] {
        guard vid != 0, pid != 0 else { return [] }
        return store.cables[CableKey(vid: vid, pid: pid)] ?? []
    }

    /// USB-IF certification listings for a cable's Cert Stat XID.
    ///
    /// The XID is the 32-bit certification ID the e-marker reports (VDO[1],
    /// `PDVDO.CertStat.xid`). A single XID can return several listings:
    /// rebrands and related models share one certificate.
    ///
    /// This is neutral provenance ("who certified it, is it listed"), never
    /// a fraud verdict. An XID of 0 (or simply absent from the registry) is
    /// normal and returns an empty array. See research/usb-if-registry.md.
    public static func certifications(forXID xid: UInt32) -> [CableCert] {
        guard xid != 0 else { return [] }
        return displayable(store.certs[Int(xid)] ?? [])
    }

    /// Single choke point that drops unusable listings before any surface
    /// (PortSummary text, JSON) sees them. A listing with an empty company is
    /// a build-data defect (a malformed / schema-changed registry row) that
    /// would otherwise render as a bogus "USB-IF certified. Manufacturer:"
    /// line with nothing after it. The build script already refuses to store
    /// such rows; this is the runtime backstop. Exposed for tests.
    static func displayable(_ certs: [CableCert]) -> [CableCert] {
        certs.filter { !$0.company.isEmpty }
    }

    /// Number of vendor entries loaded. Exposed for tests.
    public static var vendorCount: Int { store.vendors.count }

    /// Total number of cable entries loaded (counts every row, not
    /// unique fingerprints). Exposed for tests.
    public static var cableCount: Int {
        store.cables.values.reduce(0) { $0 + $1.count }
    }

    /// Number of distinct (VID, PID, Cable VDO) fingerprints.
    public static var fingerprintCount: Int { store.cables.count }

    /// Number of distinct XIDs with at least one certification listing.
    /// Exposed for tests.
    public static var certXIDCount: Int { store.certs.count }
}

/// A cable identified by user reports and curated into the database.
public struct CuratedCable {
    public let brand: String
    public let speed: String
    public let power: String
    public let type: String
    public let issueURL: String
}

/// One USB-IF certification listing for a cable, compiled offline from the
/// public certified-products registry. Neutral provenance only.
public struct CableCert {
    /// The certifying company. Usually the ODM / silicon maker (e.g.
    /// "Lintes Technology", "ACON"), NOT the retail brand on the box.
    public let company: String
    /// The certified model / part number.
    public let model: String
    /// "Pass" or "Obsolete".
    public let status: String
    /// Certification date as an ISO string. May be empty when unknown.
    public let certDate: String
    /// USB-IF vendor ID for this listing, when known (nil for listings the
    /// per-XID endpoint didn't cover). A match against the cable's own
    /// e-marker VID is a mild CONFIRMING signal; a mismatch is NOT a fraud
    /// signal (ODM rebrands legitimately differ). Never present the inverse.
    public let vendorID: Int?

    public init(company: String, model: String, status: String, certDate: String, vendorID: Int?) {
        self.company = company
        self.model = model
        self.status = status
        self.certDate = certDate
        self.vendorID = vendorID
    }
}

// MARK: - Internal types

private struct CableKey: Hashable {
    let vid: Int
    let pid: Int
}

private struct Store {
    let vendors: [Int: CableDB.VendorEntry]
    let cables: [CableKey: [CuratedCable]]
    let certs: [Int: [CableCert]]

    static func load() -> Store {
        guard let url = Bundle.module.url(forResource: "whatcable", withExtension: "db")
                ?? findResourceURL(name: "whatcable", ext: "db") else {
            return Store(vendors: [:], cables: [:], certs: [:])
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) } // sqlite3_close(nil) is a documented no-op
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
        ) == SQLITE_OK else {
            return Store(vendors: [:], cables: [:], certs: [:])
        }
        guard let db else {
            return Store(vendors: [:], cables: [:], certs: [:])
        }

        let vendors = loadVendors(db: db)
        let cables = loadCables(db: db)
        let certs = loadCerts(db: db)

        return Store(vendors: vendors, cables: cables, certs: certs)
    }

    private static func loadVendors(db: OpaquePointer) -> [Int: CableDB.VendorEntry] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT vid, name, source FROM vendors", -1, &stmt, nil
        ) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [Int: CableDB.VendorEntry] = [:]
        map.reserveCapacity(15000)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let vid = Int(sqlite3_column_int(stmt, 0))
            guard let namePtr = sqlite3_column_text(stmt, 1),
                  let sourcePtr = sqlite3_column_text(stmt, 2) else { continue }
            let name = String(cString: namePtr)
            let source = String(cString: sourcePtr)
            map[vid] = CableDB.VendorEntry(name: name, source: source)
        }
        return map
    }

    private static func loadCables(db: OpaquePointer) -> [CableKey: [CuratedCable]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, """
            SELECT vid, pid, cable_vdo, brand, speed, power, type, issue_url
            FROM cables
            ORDER BY vid, pid, cable_vdo, brand
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [CableKey: [CuratedCable]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let vid = Int(sqlite3_column_int(stmt, 0))
            let pid = Int(sqlite3_column_int(stmt, 1))
            // Column 2 (cable_vdo) is intentionally not read into the key:
            // identity is (VID, PID) only. The column stays in the DB for the
            // website catalog and reference. See #239.
            guard let brandPtr = sqlite3_column_text(stmt, 3) else { continue }

            let key = CableKey(vid: vid, pid: pid)
            map[key, default: []].append(CuratedCable(
                brand: String(cString: brandPtr),
                speed: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                power: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                type: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
                issueURL: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            ))
        }
        return map
    }

    private static func loadCerts(db: OpaquePointer) -> [Int: [CableCert]] {
        var stmt: OpaquePointer?
        // Fails soft: a `whatcable.db` built before this table existed simply
        // returns no certs rather than erroring.
        guard sqlite3_prepare_v2(
            db, """
            SELECT xid, company, model, status, cert_date, vendor_id
            FROM cable_certs
            ORDER BY xid, company, model
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [Int: [CableCert]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            // XID is a UInt32; read it as 64-bit so a value above Int32.max
            // is neither truncated nor sign-extended into a negative key.
            let xid = Int(sqlite3_column_int64(stmt, 0))
            // vendor_id is nullable; SQLITE_NULL columns read back as a stored
            // NULL, so distinguish it from a real 0.
            let vendorID: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 5))
            map[xid, default: []].append(CableCert(
                company: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                model: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                status: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                certDate: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                vendorID: vendorID
            ))
        }
        return map
    }
}

// MARK: - Resource resolution

/// Find a bundled resource across the contexts WhatCableCore runs in:
/// SwiftPM tests / `swift run`, the .app's GUI binary in Contents/MacOS/,
/// and the CLI binary in Contents/Helpers/. This is the same search
/// strategy the old TSV loader used, extracted so both the vendor TSV
/// (if ever needed) and the SQLite DB can share it.
func findResourceURL(name: String, ext: String) -> URL? {
    let bundleName = "WhatCable_WhatCableCore"
    let fm = FileManager.default

    var roots: [URL] = []

    let env = ProcessInfo.processInfo.environment
    if let override = env["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? env["PACKAGE_RESOURCE_BUNDLE_URL"] {
        roots.append(URL(fileURLWithPath: override))
    }

    if let r = Bundle.main.resourceURL { roots.append(r) }
    if let r = Bundle(for: BundleFinder.self).resourceURL { roots.append(r) }
    roots.append(Bundle.main.bundleURL)
    roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
    roots.append(Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent())

    if let exe = Bundle.main.executableURL {
        let parent = exe.deletingLastPathComponent()
        let contents = parent.deletingLastPathComponent()
        roots.append(contents.appendingPathComponent("Resources"))
    }

    for root in roots {
        let viaBundle = root
            .appendingPathComponent("\(bundleName).bundle")
            .appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: viaBundle.path) { return viaBundle }

        let loose = root.appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: loose.path) { return loose }
    }
    return nil
}

private final class BundleFinder {}
