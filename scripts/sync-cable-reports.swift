#!/usr/bin/env swift

// Sync data/known-cables.md from closed `cable-report` issues.
//
// Incremental by design: it lists closed `cable-report` issues via `gh`,
// then APPENDS a row only for cables not already in the table. Rows we
// already have are left untouched (no re-parse, no re-render, no rewrite),
// so hand-edited "Brand / model context" cells and ordering are preserved.
//
// A report is skipped when either its issue number is already recorded, or
// its cable fingerprint (VID + PID + Cable VDO, the same key the database
// uses) already appears in the table. The fingerprint check means a cable
// re-reported under a new issue number (a duplicate) is not added again.
//
// New rows are appended at the end with "(needs review)" in the Brand /
// model context column, so you know to fill them in by hand.
//
// Run from the repo root:
//   swift scripts/sync-cable-reports.swift
//
// Then re-run scripts/render-known-cables.swift to update docs/cables.html.
//
// Requires:
//   - `gh` CLI authenticated for the repo
//   - Sources/WhatCableCore/Resources/usbif-vendors.tsv

import Foundation

// MARK: - Paths

let repoRoot = FileManager.default.currentDirectoryPath
let mdURL = URL(fileURLWithPath: "\(repoRoot)/data/known-cables.md")
let vendorTSVURL = URL(fileURLWithPath: "\(repoRoot)/Sources/WhatCableCore/Resources/usbif-vendors.tsv")
let needsReview = "(needs review)"

// MARK: - Vendor TSV

func loadVendors() -> [Int: String] {
    guard let text = try? String(contentsOf: vendorTSVURL, encoding: .utf8) else {
        fputs("error: could not read \(vendorTSVURL.path)\n", stderr)
        exit(2)
    }
    var out: [Int: String] = [:]
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("#") || line.isEmpty { continue }
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 2, let vid = Int(parts[0]) else { continue }
        out[vid] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    return out
}

// MARK: - gh

func runGh() -> [[String: Any]] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [
        "gh", "issue", "list",
        "--repo", "darrylmorley/whatcable",
        "--label", "cable-report",
        "--state", "closed",
        "--json", "number,body,title",
        "--limit", "200",
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr
    do { try proc.run() } catch {
        fputs("error: could not run gh: \(error)\n", Darwin.stderr)
        exit(3)
    }
    // Drain both pipes BEFORE waitUntilExit. gh's JSON output for the full
    // closed-issue list now exceeds the OS pipe buffer (~64KB). If we wait
    // for exit before reading, gh blocks trying to write into a full pipe
    // and never exits, deadlocking the script. readDataToEndOfFile drains
    // the pipe as gh fills it, so gh can finish and close the descriptor.
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let err = String(data: errData, encoding: .utf8) ?? ""
        fputs("error: gh exited \(proc.terminationStatus): \(err)\n", Darwin.stderr)
        exit(4)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        fputs("error: could not parse gh JSON output\n", Darwin.stderr)
        exit(5)
    }
    return json
}

// MARK: - Body parsing

struct Report {
    let issueNumber: Int
    let vid: Int           // 0 for zeroed
    let pid: Int           // 0 for zeroed
    let cableVDO: UInt32   // VDO[3] from Raw VDOs table, 0 if absent
    let xidCol: String     // "none" or formatted hex
    let speed: String      // empty for missing
    let power: String      // empty for missing
    let type: String       // "passive" / "active" / etc; empty for missing
}

/// Find the value cell of a "| <field> | <value> |" row.
func extractField(_ field: String, from body: String) -> String? {
    for raw in body.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|") else { continue }
        var trimmed = line
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        let parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { continue }
        if parts[0] == field { return parts[1] }
    }
    return nil
}

/// Pull `0xABCD` out of a string. Returns the integer value or nil.
func extractHex(_ s: String) -> Int? {
    let re = try! NSRegularExpression(pattern: "0x([0-9A-Fa-f]+)")
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 2 else { return nil }
    guard let r = Range(m.range(at: 1), in: s) else { return nil }
    return Int(String(s[r]), radix: 16)
}

/// Extract VDO[3] (Cable VDO) from the "Raw VDOs" table in the issue body.
/// Returns 0 if the table is missing or index 3 isn't present (older reports).
func extractCableVDO(from body: String) -> UInt32 {
    let lines = body.components(separatedBy: "\n")
    var inVDOTable = false
    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.contains("Raw VDOs") { inVDOTable = true; continue }
        if inVDOTable, line.hasPrefix("|"), !line.contains("---"), !line.contains("Index") {
            let parts = line.dropFirst().dropLast().components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            if let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)), idx == 3 {
                if let val = extractHex(parts[2]) { return UInt32(val) }
            }
        }
        if inVDOTable, line.hasPrefix("###"), !line.contains("Raw VDOs") { break }
    }
    return 0
}

func parse(body: String, issueNumber: Int) -> Report? {
    guard let vidCell = extractField("Vendor ID", from: body),
          let vid = extractHex(vidCell) else {
        fputs("warn: issue #\(issueNumber): no Vendor ID, skipping\n", Darwin.stderr)
        return nil
    }
    let pid = extractField("Product ID", from: body).flatMap { extractHex($0) } ?? 0
    let cableVDO = extractCableVDO(from: body)

    // XID: "USB-IF certification ID" cell. May be missing entirely on
    // older reports. May contain "none (XID = 0)" or a hex value.
    let xidCol: String
    if let xidCell = extractField("USB-IF certification ID", from: body) {
        if xidCell.lowercased().contains("none") || xidCell.contains("XID = 0") {
            xidCol = "none"
        } else if let xid = extractHex(xidCell), xid != 0 {
            xidCol = String(format: "`0x%X`", xid)
        } else {
            xidCol = "none"
        }
    } else {
        xidCol = "none"
    }

    // Cable speed / current rating / type are plain text in the template.
    // Strip backticks if present, leave wording verbatim.
    func stripCode(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "")
    }

    let speed = extractField("Cable speed", from: body).map(stripCode) ?? ""
    let power = extractField("Current rating", from: body).map(humanisePower) ?? ""
    let type = extractField("Type", from: body).map(stripCode) ?? ""

    return Report(
        issueNumber: issueNumber,
        vid: vid,
        pid: pid,
        cableVDO: cableVDO,
        xidCol: xidCol,
        speed: speed,
        power: power,
        type: type
    )
}

/// Reformat "5 A at up to 20V (~100W)" as "5 A / 20 V (100 W)" to match
/// the existing table convention. Falls back to the raw string if it
/// doesn't match.
///
/// The wattage is recomputed from amps and volts rather than copied from
/// the issue body, with the voltage clamped to 48 V first. USB-PD never
/// delivers above 48 V (the fixed EPR power levels top out at 48 V and EPR
/// adjustable voltage caps there too), so a 50 V e-marker rating is
/// insulation headroom, not a delivery voltage. Older app versions filed
/// reports that multiplied 50 V x 5 A into 250 W, a figure no cable can
/// carry; clamping here corrects those at the source so a re-sync can't
/// reintroduce them. Mirrors the clamp in PDVDO.decodeCableVDO.
func humanisePower(_ raw: String) -> String {
    let re = try! NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*A\\s+at\\s+up\\s+to\\s+(\\d+(?:\\.\\d+)?)\\s*V\\s*\\(~?(\\d+(?:\\.\\d+)?)\\s*W\\)",
        options: [.caseInsensitive]
    )
    let range = NSRange(raw.startIndex..., in: raw)
    guard let m = re.firstMatch(in: raw, range: range), m.numberOfRanges >= 4,
          let amps = Range(m.range(at: 1), in: raw),
          let volts = Range(m.range(at: 2), in: raw),
          Range(m.range(at: 3), in: raw) != nil,
          let ampsVal = Double(raw[amps]),
          let voltsVal = Double(raw[volts])
    else {
        return raw
    }
    let deliverableVolts = min(voltsVal, 48)
    let watts = Int((deliverableVolts * ampsVal).rounded())
    return "\(raw[amps]) A / \(raw[volts]) V (\(watts) W)"
}

// MARK: - Existing-row extraction

/// Cable identity key: VID + PID + Cable VDO. Mirrors the database's
/// `(vid, pid, cable_vdo)` primary key, so "already in the table" means the
/// same thing here as it does in whatcable.db.
func fingerprintKey(vid: Int, pid: Int, vdo: UInt32) -> String {
    "\(vid):\(pid):\(vdo)"
}

/// Walk the existing data/known-cables.md table once and collect what we
/// already have: the set of issue numbers recorded, and the set of cable
/// fingerprints present. A report matching either is skipped, so a re-sync
/// only appends genuinely new cables and never rewrites existing rows.
func loadExisting() -> (issues: Set<Int>, fingerprints: Set<String>) {
    guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return ([], []) }
    let lines = md.components(separatedBy: "\n")
    var issues: Set<Int> = []
    var fingerprints: Set<String> = []

    var inTable = false
    for line in lines {
        if line.hasPrefix("## Table") { inTable = true; continue }
        if inTable, line.hasPrefix("## ") { break }
        guard inTable, line.hasPrefix("|"), !line.contains("---") else { continue }
        let parts = line.dropFirst().dropLast().components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Data rows have a code span like `0xABCD` in column 1 (the VID).
        // Header row has plain text "VID" there. We use that as the
        // discriminator so we skip the header without a name match.
        // Column count is 10 (context | VID | PID | VDO | vendor | xid |
        // speed | power | type | source) or 9 (legacy rows without the VDO
        // column). On legacy rows column 3 is the vendor name, which has no
        // 0x literal, so the VDO reads as 0, matching renderRow's empty cell.
        guard parts.count >= 9, parts[1].hasPrefix("`0x") else { continue }
        let vid = extractHex(parts[1]) ?? 0
        let pid = extractHex(parts[2]) ?? 0
        let vdo: UInt32 = parts.count >= 10 ? UInt32(extractHex(parts[3]) ?? 0) : 0
        fingerprints.insert(fingerprintKey(vid: vid, pid: pid, vdo: vdo))
        let source = parts[parts.count - 1]
        // Source cell is "[#NN](url)"; pull out NN.
        let re = try! NSRegularExpression(pattern: "#(\\d+)")
        let range = NSRange(source.startIndex..., in: source)
        if let m = re.firstMatch(in: source, range: range),
           m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: source),
           let n = Int(String(source[r])) {
            issues.insert(n)
        }
    }
    return (issues, fingerprints)
}

// MARK: - Row rendering

func renderRow(_ report: Report, context: String, vendors: [Int: String]) -> String {
    let vidCol = String(format: "`0x%04X`", report.vid)
    let pidCol = String(format: "`0x%04X`", report.pid)
    let vdoCol = report.cableVDO != 0 ? String(format: "`0x%08X`", report.cableVDO) : ""
    let vendor: String
    if report.vid == 0 {
        vendor = "(zeroed)"
    } else if let name = vendors[report.vid] {
        vendor = name
    } else {
        vendor = "Unregistered"
    }
    let speed = report.speed.isEmpty ? "(none advertised)" : report.speed
    let power = report.power.isEmpty ? "(not advertised)" : report.power
    let type = report.type.isEmpty ? "passive" : report.type
    let source = "[#\(report.issueNumber)](https://github.com/darrylmorley/whatcable/issues/\(report.issueNumber))"
    return "| \(context) | \(vidCol) | \(pidCol) | \(vdoCol) | \(vendor) | \(report.xidCol) | \(speed) | \(power) | \(type) | \(source) |"
}

// MARK: - Update markdown

/// Append new rows after the last existing data row, leaving every existing
/// row byte-for-byte intact. We never regenerate rows we already have, so
/// hand edits and ordering are preserved. No-op when there is nothing new.
func appendRows(_ rows: [String]) {
    if rows.isEmpty { return }
    guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else {
        fputs("error: could not read \(mdURL.path)\n", Darwin.stderr)
        exit(6)
    }
    let lines = md.components(separatedBy: "\n")

    // Find the header row and the first non-table line after it.
    var headerIdx: Int?
    for (i, line) in lines.enumerated() where line.hasPrefix("## Table") {
        for j in (i + 1) ..< lines.count where lines[j].hasPrefix("|") {
            headerIdx = j
            break
        }
        break
    }
    guard let h = headerIdx, h + 1 < lines.count, lines[h + 1].contains("---") else {
        fputs("error: could not find table header in \(mdURL.path)\n", Darwin.stderr)
        exit(7)
    }

    // Walk forward past the existing data rows to the end of the table block.
    var endIdx = h + 2
    while endIdx < lines.count, lines[endIdx].hasPrefix("|") { endIdx += 1 }

    // Keep header + separator + all existing rows, then insert the new rows.
    var newLines = Array(lines[..<endIdx])
    newLines.append(contentsOf: rows)
    newLines.append(contentsOf: lines[endIdx...])

    do {
        try newLines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    } catch {
        fputs("error: could not write \(mdURL.path): \(error)\n", Darwin.stderr)
        exit(8)
    }
}

// MARK: - Main

let vendors = loadVendors()
let issues = runGh()
let existing = loadExisting()

// Collect only cables we do not already have. Skip a report if its issue is
// already recorded, or if its fingerprint already appears in the table (a
// duplicate cable re-reported under a new issue number). Dedup within this
// batch too, so two new issues for the same cable add one row.
var seenFingerprints = existing.fingerprints
var newReports: [Report] = []
for issue in issues {
    guard let n = issue["number"] as? Int,
          let body = issue["body"] as? String else { continue }
    if existing.issues.contains(n) { continue }
    guard let r = parse(body: body, issueNumber: n) else { continue }
    let key = fingerprintKey(vid: r.vid, pid: r.pid, vdo: r.cableVDO)
    if seenFingerprints.contains(key) {
        fputs("skip: issue #\(n): cable already in the list (same VID/PID/VDO)\n", Darwin.stderr)
        continue
    }
    seenFingerprints.insert(key)
    newReports.append(r)
}

// Sort the new rows: VID ascending, zeroed last, then by issue number.
// Existing rows are never reordered.
newReports.sort { a, b in
    let aZero = a.vid == 0
    let bZero = b.vid == 0
    if aZero != bZero { return !aZero }  // non-zero first
    if a.vid != b.vid { return a.vid < b.vid }
    return a.issueNumber < b.issueNumber
}

let rendered = newReports.map { renderRow($0, context: needsReview, vendors: vendors) }
appendRows(rendered)

if newReports.isEmpty {
    print("nothing new to add; the table is already up to date")
} else {
    let nums = newReports.map { "#\($0.issueNumber)" }.joined(separator: ", ")
    print("appended \(newReports.count) new cable(s): \(nums)")
    print("fill the '\(needsReview)' rows by hand, then run: swift scripts/build-cable-db.swift && swift scripts/render-known-cables.swift")
}
