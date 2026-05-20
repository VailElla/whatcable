#!/usr/bin/env swift

// Build the bundled SQLite database from vendor and cable sources.
//
// Reads:
//   - Sources/WhatCableCore/Resources/usbif-vendors.tsv (USB-IF vendor list)
//   - https://usb-ids.gowdy.us/usb.ids (community vendor list, fetched live)
//
// Writes:
//   - Sources/WhatCableCore/Resources/whatcable.db (bundled in the app)
//   - docs/whatcable.db (served on the website)
//
// Run from the repo root:
//   swift scripts/build-cable-db.swift
//
// Requires: macOS (uses system SQLite3 via libsqlite3).

import Foundation
import SQLite3

// MARK: - Paths

let repoRoot = FileManager.default.currentDirectoryPath
let vendorTSV = "\(repoRoot)/Sources/WhatCableCore/Resources/usbif-vendors.tsv"
let dbOutput = "\(repoRoot)/Sources/WhatCableCore/Resources/whatcable.db"
let dbWebCopy = "\(repoRoot)/docs/whatcable.db"
let cablesJSON = "\(repoRoot)/docs/cables.json"

// MARK: - SQLite helpers

var db: OpaquePointer?

func openDB() {
    // Remove existing DB so we always start fresh.
    try? FileManager.default.removeItem(atPath: dbOutput)

    let rc = sqlite3_open(dbOutput, &db)
    guard rc == SQLITE_OK else {
        fputs("error: sqlite3_open failed: \(String(cString: sqlite3_errmsg(db)))\n", stderr)
        exit(1)
    }
    // WAL mode and synchronous=OFF for build-time speed (we're writing
    // once and the file is read-only at runtime).
    runSQL("PRAGMA journal_mode = WAL")
    runSQL("PRAGMA synchronous = OFF")
}

func runSQL(_ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &err)
    if rc != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(err)
        fputs("error: SQL failed: \(msg)\n  statement: \(sql)\n", stderr)
        exit(2)
    }
}

func closeDB() {
    // Switch out of WAL mode before shipping. The bundled .db is read-only
    // at runtime; WAL mode requires creating -shm/-wal sidecars, which
    // fails in read-only bundle directories.
    runSQL("PRAGMA journal_mode = DELETE")
    sqlite3_close(db)
    db = nil
    try? FileManager.default.removeItem(atPath: dbOutput + "-shm")
    try? FileManager.default.removeItem(atPath: dbOutput + "-wal")
}

// MARK: - Schema

func createSchema() {
    runSQL("""
        CREATE TABLE vendors (
            vid    INTEGER PRIMARY KEY,
            name   TEXT NOT NULL,
            source TEXT NOT NULL CHECK(source IN ('usbif', 'usbids', 'manual'))
        )
        """)

    runSQL("""
        CREATE TABLE cables (
            vid       INTEGER NOT NULL,
            pid       INTEGER NOT NULL,
            cable_vdo INTEGER NOT NULL DEFAULT 0,
            brand     TEXT NOT NULL,
            speed     TEXT NOT NULL DEFAULT '',
            power     TEXT NOT NULL DEFAULT '',
            type      TEXT NOT NULL DEFAULT 'passive',
            xid       TEXT NOT NULL DEFAULT 'none',
            issue_url TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (vid, pid, cable_vdo)
        )
        """)
}

// MARK: - USB-IF vendor import

func importUSBIFVendors() -> Int {
    guard let text = try? String(contentsOfFile: vendorTSV, encoding: .utf8) else {
        fputs("error: could not read \(vendorTSV)\n", stderr)
        exit(3)
    }

    let insertSQL = "INSERT INTO vendors (vid, name, source) VALUES (?, ?, 'usbif')"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("error: prepare failed for vendor insert\n", stderr)
        exit(4)
    }

    runSQL("BEGIN TRANSACTION")
    var count = 0

    for line in text.components(separatedBy: "\n") {
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 2, let vid = Int(parts[0]) else { continue }
        var name = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        // Strip the " ‐ OBSOLETE" suffix from obsolete vendor entries so
        // users see clean names. The raw suffix is preserved in the TSV.
        let obsoleteSuffix = " \u{2010} OBSOLETE"
        if name.hasSuffix(obsoleteSuffix) {
            name = String(name.dropLast(obsoleteSuffix.count))
        }

        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(vid))
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            fputs("warn: failed to insert VID \(vid): \(String(cString: sqlite3_errmsg(db)))\n", stderr)
        }
        count += 1
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)
    return count
}

// MARK: - usb.ids community vendor import

let usbidsURL = URL(string: "https://usb-ids.gowdy.us/usb.ids")!

func fetchUSBIDs() -> String? {
    do {
        let data = try Data(contentsOf: usbidsURL)
        // The file is mostly UTF-8 but contains a few invalid bytes.
        // Fall back to Latin-1 (which always succeeds) if strict UTF-8 fails.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    } catch {
        fputs("warn: usb.ids fetch failed: \(error)\n", stderr)
        return nil
    }
}

func importUSBIDsVendors() -> (inserted: Int, skipped: Int) {
    guard let text = fetchUSBIDs() else {
        fputs("warn: skipping usb.ids (fetch failed)\n", stderr)
        return (0, 0)
    }

    // INSERT OR IGNORE: USB-IF entries take priority (already loaded).
    let insertSQL = "INSERT OR IGNORE INTO vendors (vid, name, source) VALUES (?, ?, 'usbids')"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for usb.ids insert\n", stderr)
        return (0, 0)
    }

    runSQL("BEGIN TRANSACTION")
    var inserted = 0
    var skipped = 0

    // Format: lines starting with 4 hex digits + 2 spaces + name are
    // vendor entries. Lines with leading tabs are device/interface
    // entries (ignored). The vendor section ends at "C xx  class_name".
    let re = try! NSRegularExpression(pattern: "^([0-9a-fA-F]{4})  (.+)$")

    for line in text.components(separatedBy: "\n") {
        // Stop at the device class section.
        if line.hasPrefix("C ") { break }
        if line.hasPrefix("#") || line.hasPrefix("\t") || line.isEmpty { continue }

        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, range: range),
              m.numberOfRanges >= 3,
              let vidRange = Range(m.range(at: 1), in: line),
              let nameRange = Range(m.range(at: 2), in: line) else { continue }

        guard let vid = Int(String(line[vidRange]), radix: 16) else { continue }
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }

        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(vid))
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            // sqlite3_changes returns 0 for INSERT OR IGNORE when the
            // row already existed.
            if sqlite3_changes(db) > 0 {
                inserted += 1
            } else {
                skipped += 1
            }
        } else {
            skipped += 1
        }
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)
    return (inserted, skipped)
}

// MARK: - Known cables import (from data/known-cables.md)

let knownCablesMD = "\(repoRoot)/data/known-cables.md"

/// Parsed cable row from the markdown table, before DB insert.
private struct CableRow {
    let vid: Int
    let pid: Int
    let cableVDO: Int
    let brand: String
    let speed: String
    let power: String
    let type: String
    let xid: String
    let issueURL: String
}

private struct CableRowKey: Hashable {
    let vid: Int
    let pid: Int
    let cableVDO: Int
}

func importKnownCables() -> Int {
    guard let text = try? String(contentsOfFile: knownCablesMD, encoding: .utf8) else {
        fputs("warn: could not read \(knownCablesMD), skipping cables\n", stderr)
        return 0
    }

    // Pass 1: parse all valid markdown rows into a flat list. We
    // group by (vid, pid, cable_vdo) below before inserting, because
    // INSERT OR REPLACE used to silently drop rows when a fingerprint
    // was shared by multiple reports (see issue #161 secondary finding).
    var parsed: [CableRow] = []
    var inTable = false
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## Table") { inTable = true; continue }
        if inTable, line.hasPrefix("## ") { break }
        guard inTable, line.hasPrefix("|"), !line.contains("---") else { continue }

        let parts = line.dropFirst().dropLast()
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 10 columns: Brand, VID, PID, Cable VDO, Vendor, XID, Speed, Power, Type, Source
        guard parts.count == 10 else { continue }
        // Skip header row
        guard parts[1].hasPrefix("`0x") else { continue }

        let brand = parts[0]
        // Skip "(needs review)" rows
        if brand == "(needs review)" { continue }

        guard let vid = parseHex(parts[1]),
              let pid = parseHex(parts[2]) else { continue }
        let cableVDO = parseHex(parts[3]) ?? 0
        let xid = parts[5].replacingOccurrences(of: "`", with: "")
        let speed = parts[6]
        let power = parts[7]
        let type = parts[8]
        // Source cell is "[#NN](url)"; extract the URL.
        let issueURL: String
        if let urlStart = parts[9].range(of: "("),
           let urlEnd = parts[9].range(of: ")") {
            issueURL = String(parts[9][urlStart.upperBound..<urlEnd.lowerBound])
        } else {
            issueURL = ""
        }

        parsed.append(CableRow(
            vid: vid, pid: pid, cableVDO: cableVDO,
            brand: brand, speed: speed, power: power, type: type,
            xid: xid, issueURL: issueURL
        ))
    }

    // Pass 2: group by fingerprint. Multiple reports of the same
    // (vid, pid, cable_vdo) are merged into one DB row with brand
    // strings joined by "; " and issue URLs joined by ", ". This
    // keeps the markdown one-row-per-issue (so the sync script stays
    // simple) while producing one honest DB row per fingerprint.
    //
    // The all-zero key (0, 0, 0) is dropped entirely: it carries no
    // identifying bits, CableDB.curatedCable refuses it at lookup
    // time, and writing it to the DB only wastes a slot.
    var grouped: [CableRowKey: [CableRow]] = [:]
    var insertOrder: [CableRowKey] = []
    for row in parsed {
        let key = CableRowKey(vid: row.vid, pid: row.pid, cableVDO: row.cableVDO)
        if grouped[key] == nil { insertOrder.append(key) }
        grouped[key, default: []].append(row)
    }

    let insertSQL = """
        INSERT INTO cables (vid, pid, cable_vdo, brand, speed, power, type, xid, issue_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for cable insert\n", stderr)
        return 0
    }

    runSQL("BEGIN TRANSACTION")
    var count = 0
    var mergedGroups = 0
    var skippedAllZero = 0

    for key in insertOrder {
        let rows = grouped[key]!
        if key.vid == 0 && key.pid == 0 && key.cableVDO == 0 {
            skippedAllZero += rows.count
            continue
        }

        let row: CableRow
        if rows.count == 1 {
            row = rows[0]
        } else {
            let mergedBrand = rows.map { $0.brand }.joined(separator: "; ")
            let mergedURLs = rows.map { $0.issueURL }.joined(separator: ", ")
            let first = rows[0]
            row = CableRow(
                vid: key.vid, pid: key.pid, cableVDO: key.cableVDO,
                brand: mergedBrand, speed: first.speed, power: first.power,
                type: first.type, xid: first.xid, issueURL: mergedURLs
            )
            mergedGroups += 1
            let vidStr = String(format: "0x%04X", key.vid)
            let pidStr = String(format: "0x%04X", key.pid)
            let vdoStr = String(format: "0x%08X", key.cableVDO)
            print("note: merged \(rows.count) reports on (\(vidStr), \(pidStr), \(vdoStr)) -> \(mergedBrand)")
        }

        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(row.vid))
        sqlite3_bind_int(stmt, 2, Int32(row.pid))
        sqlite3_bind_int(stmt, 3, Int32(bitPattern: UInt32(row.cableVDO)))
        sqlite3_bind_text(stmt, 4, (row.brand as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (row.speed as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (row.power as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (row.type as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (row.xid as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (row.issueURL as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            fputs("warn: failed to insert cable VID=\(row.vid) PID=\(row.pid): \(String(cString: sqlite3_errmsg(db)))\n", stderr)
        } else {
            count += 1
        }
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)

    if mergedGroups > 0 {
        print("Merged \(mergedGroups) fingerprint group(s) with multiple reports")
    }
    if skippedAllZero > 0 {
        print("Skipped \(skippedAllZero) all-zero-fingerprint markdown row(s) (cannot identify a cable)")
    }
    return count
}

/// Parse "`0xABCD`" or "`0x01234567`" into an integer.
func parseHex(_ s: String) -> Int? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "`", with: "")
    guard trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") else { return nil }
    return Int(trimmed.dropFirst(2), radix: 16)
}

// MARK: - JSON export for website search

func exportCablesJSON() -> Int {
    let query = """
        SELECT c.vid, c.pid, c.cable_vdo, c.brand, c.speed, c.power,
               c.type, c.xid, c.issue_url, COALESCE(v.name, '') as vendor_name,
               COALESCE(v.source, '') as vendor_source
        FROM cables c
        LEFT JOIN vendors v ON c.vid = v.vid
        ORDER BY c.vid, c.pid
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for JSON export\n", stderr)
        return 0
    }
    defer { sqlite3_finalize(stmt) }

    var entries: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let vid = Int(sqlite3_column_int(stmt, 0))
        let pid = Int(sqlite3_column_int(stmt, 1))
        let cableVDO = UInt32(bitPattern: sqlite3_column_int(stmt, 2))
        let brand = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let speed = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let power = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let type = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
        let xid = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "none"
        let issueURL = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
        let vendorName = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
        let vendorSource = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""

        let vendor: String
        if vid == 0 {
            vendor = "(zeroed)"
        } else if vendorName.isEmpty {
            vendor = "Unregistered"
        } else {
            vendor = vendorName
        }

        let vidHex = String(format: "0x%04X", vid)
        let pidHex = String(format: "0x%04X", pid)
        let vdoHex = cableVDO == 0 ? "" : String(format: "0x%08X", cableVDO)

        let issueNum: String
        if let hashIdx = issueURL.lastIndex(of: "/") {
            issueNum = "#" + issueURL[issueURL.index(after: hashIdx)...]
        } else {
            issueNum = ""
        }

        let entry: [String: Any] = [
            "brand": brand,
            "vid": vidHex,
            "pid": pidHex,
            "cableVDO": vdoHex,
            "vendor": vendor,
            "registered": vendorSource == "usbif",
            "xid": xid,
            "speed": speed,
            "power": power,
            "type": type,
            "issueURL": issueURL,
            "issueNum": issueNum,
        ]
        entries.append(entry)
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]
    ) else {
        fputs("warn: JSON serialization failed\n", stderr)
        return 0
    }

    let url = URL(fileURLWithPath: cablesJSON)
    do {
        try data.write(to: url)
    } catch {
        fputs("warn: could not write \(cablesJSON): \(error)\n", stderr)
        return 0
    }

    return entries.count
}

// MARK: - Main

openDB()
createSchema()

let vendorCount = importUSBIFVendors()
print("Imported \(vendorCount) USB-IF vendors")

let usbids = importUSBIDsVendors()
print("usb.ids: \(usbids.inserted) new vendors added, \(usbids.skipped) already in USB-IF list")

let cableCount = importKnownCables()
print("Imported \(cableCount) known cables")

let jsonCount = exportCablesJSON()
print("Exported \(jsonCount) cables to \(cablesJSON)")

// Copy to docs/ for the website.
closeDB()

do {
    let fm = FileManager.default
    if fm.fileExists(atPath: dbWebCopy) {
        try fm.removeItem(atPath: dbWebCopy)
    }
    try fm.copyItem(atPath: dbOutput, toPath: dbWebCopy)
    print("Copied to \(dbWebCopy)")
} catch {
    fputs("warn: could not copy to docs/: \(error)\n", stderr)
}

print("Done: \(dbOutput)")
