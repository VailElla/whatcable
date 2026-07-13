#!/usr/bin/env python3
"""Mine probes 35 (HPM port UUID), 36 (xHCI port map), and 37 (TB tunnel port
map) from the customer-probe corpus for the port-key-identity question (DAR-
29 / DAR-143): is the HPM controller UUID a safe canonical join key across
subsystems, or does the corpus confirm the plan needs to fall back to
positional keys (@N) in places?

Read-only against research/customer-probes/. Writes nothing there; use --out
to write TSVs to a scratch directory of your choice.

Since PR #394, probes 36 and 37 also emit an "=== HPM UUID map ===" section
(a copy of probe 35's own port/UUID table, captured in the SAME run as the
xHCI/TB data), and probe 36 additionally emits an
"=== XHCI port -> HPM UUID via UsbIOPort (per-record ancestor join) ==="
section that resolves each xHCI port straight to its HPM controller's UUID
with no number-matching at all. No corpus folder has these sections yet (all
submissions on disk predate #394); they will start showing up in future
test-kit submissions. This script parses both the old (pre-#394) and new
(post-#394) formats and reports how many folders have each, so a fresh run
after new submissions land will pick up the richer data automatically.

Usage:
    scripts/extract-portkeys.py                 # markdown findings summary to stdout
    scripts/extract-portkeys.py --json           # full rows + analysis as JSON to stdout
    scripts/extract-portkeys.py --out DIR        # also write TSVs + findings.md into DIR

DIR is not created inside the repo by convention: the TSVs carry full HPM
UUIDs / ConnectionUUIDs / TB switch UIDs, which are internal research join
keys only (see the "Privacy" section of the whatcable-mine-portkeys skill).
Point --out at a scratch directory, not anywhere under research/ that gets
committed.
"""
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS_DIR = os.path.join(REPO, "research", "customer-probes")


def load_corpus_meta():
    meta = {}
    with open(os.path.join(CORPUS_DIR, "corpus.jsonl")) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            meta[d["folder"]] = d
    return meta


def chip_generation(chip):
    if not chip:
        return "unknown"
    if chip.startswith("Intel"):
        return "Intel"
    if "A18" in chip or chip.startswith("Apple A"):
        return "A-series"
    m = re.search(r"Apple M(\d)", chip)
    if m:
        return f"M{m.group(1)}"
    return "unknown"


def read_probe_output(folder, probe_filename):
    path = os.path.join(CORPUS_DIR, folder, probe_filename)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            d = json.load(f)
        return d.get("output", "") or ""
    except Exception:
        return None


# ---------- Probe 35 parser (unchanged since introduction) ----------
# Blocks like:
# [0] Port-USB-C@3        class=AppleHPMDeviceHALType3
#       UUID=17BD562D-D913-3441-0CD9-435CAC6CFA51  RID=2  Address=12
#       ConnectionUUID=1BBA7253-D8C8-47B7-86EA-FE1C1ADC863F
P35_HEADER = re.compile(r"^\[(\d+)\]\s+(.+?)\s+class=(\S+)\s*$")
P35_UUID_LINE = re.compile(r"^\s*UUID=(\S+)\s+RID=(-?\d+)\s+Address=(-?\d+)\s*$")
P35_CONN_LINE = re.compile(r"^\s*ConnectionUUID=(\S+)\s*$")


def parse_probe35(output):
    records = []
    lines = output.splitlines()
    i = 0
    while i < len(lines):
        m = P35_HEADER.match(lines[i])
        if m:
            idx, port_label, cls = m.groups()
            uuid = rid = addr = conn = None
            if i + 1 < len(lines):
                m2 = P35_UUID_LINE.match(lines[i + 1])
                if m2:
                    uuid, rid, addr = m2.groups()
            if i + 2 < len(lines):
                m3 = P35_CONN_LINE.match(lines[i + 2])
                if m3:
                    conn = m3.group(1)
            records.append({
                "idx": int(idx),
                "port_label": port_label,
                "class": cls,
                "uuid": uuid,
                "rid": rid,
                "address": addr,
                "connection_uuid": conn,
            })
            i += 3
        else:
            i += 1
    return records


AT_N_RE = re.compile(r"@(\d+)\s*$")


def extract_at_n(label):
    if not label:
        return None
    m = AT_N_RE.search(label.strip())
    return int(m.group(1)) if m else None


def is_usb_c_label(label):
    return label is not None and label.startswith("Port-USB-C@")


def is_magsafe_label(label):
    return label is not None and "MagSafe" in label


# ---------- Shared "HPM UUID map" section parser (probes 36 + 37, post-#394) ----------
# Appended block, identical printf format in both probes:
#   === HPM UUID map ===
#   ...two lines of description...
#   [0] class=AppleHPMDeviceHALType3     port=Port-USB-C@1        UUID=...
#   ...
# port_label uses a lazy match because "(no port child)" itself contains
# spaces; the anchor is the literal "UUID=" that always follows it.
HPM_UUID_MAP_MARKER = "=== HPM UUID map ==="
P_HPM_MAP_LINE = re.compile(r"^\[(\d+)\]\s+class=(\S+)\s+port=(.*?)\s+UUID=(\S+)\s*$")


def parse_hpm_uuid_map_section(output):
    """Returns (present, records). present is False if the marker is absent
    (pre-#394 probe capture); records is [] in that case, not an error."""
    if HPM_UUID_MAP_MARKER not in output:
        return False, []
    records = []
    for line in output.splitlines():
        m = P_HPM_MAP_LINE.match(line)
        if m:
            idx, cls, port_label, uuid = m.groups()
            records.append({
                "idx": int(idx),
                "class": cls,
                "port_label": port_label,
                "uuid": uuid,
            })
    return True, records


# ---------- Probe 36's per-record UsbIOPort -> HPM UUID join (post-#394) ----------
# === XHCI port -> HPM UUID via UsbIOPort (per-record ancestor join) ===
# AppleUSB30XHCIARMPort (USB3 / SuperSpeed):
#   usb-drd0-port-ss         UsbIOPort=IOService:/.../Port-USB-C@1
#       HPM-class=AppleHPMDeviceHALType3  HPM-UUID=17BD562D-...
#   (AppleUSB30XHCIARMPort: none)          <- when zero ports matched
#
# AppleUSB20XHCIARMPort (USB2):
#   ...
USBIOPORT_JOIN_MARKER = "=== XHCI port -> HPM UUID via UsbIOPort"
P_USBIOPORT_SECTION_HEADER = re.compile(r"^(AppleUSB30XHCIARMPort|AppleUSB20XHCIARMPort) \(.*\):$")
P_USBIOPORT_NONE_LINE = re.compile(r"^\s*\((\S+):\s*none\)\s*$")
P_USBIOPORT_LINE_A = re.compile(r"^\s+(\S+)\s+UsbIOPort=(.+)$")
P_USBIOPORT_LINE_B = re.compile(r"^\s*HPM-class=(\S+)\s+HPM-UUID=(.+)$")


def parse_usbioport_join_section(output):
    """Returns (present, records). present is False pre-#394."""
    if USBIOPORT_JOIN_MARKER not in output:
        return False, []
    lines = output.splitlines()
    start = next(i for i, l in enumerate(lines) if USBIOPORT_JOIN_MARKER in l)
    records = []
    xhci_class = None
    i = start + 1
    while i < len(lines):
        line = lines[i]
        hm = P_USBIOPORT_SECTION_HEADER.match(line)
        if hm:
            xhci_class = hm.group(1)
            i += 1
            continue
        if P_USBIOPORT_NONE_LINE.match(line):
            i += 1
            continue
        ma = P_USBIOPORT_LINE_A.match(line)
        if ma and i + 1 < len(lines):
            mb = P_USBIOPORT_LINE_B.match(lines[i + 1])
            if mb:
                name, usb_io_port = ma.groups()
                hpm_class, hpm_uuid = mb.groups()
                records.append({
                    "xhci_class": xhci_class,
                    "name": name,
                    "usb_io_port": usb_io_port,
                    "hpm_class": hpm_class,
                    "hpm_uuid": hpm_uuid,
                })
                i += 2
                continue
        i += 1
    return True, records


# ---------- Probe 36 parser (pre-existing xHCI/device sections, unchanged) ----------
P36_PORT_LINE = re.compile(
    r"^\s+(\S+)\s+usb-c-port-number=(-?\d+)\s+locationID=(-?\d+) \(0x([0-9a-fA-F]+)\)\s*$"
)
P36_DEVICE_LINE = re.compile(
    r"^\s+locationID=(-?\d+) \(0x([0-9a-fA-F]+)\)\s+(.*)$"
)


def parse_probe36(output):
    records = []
    section = None
    lines = output.splitlines()
    for line in lines:
        if "AppleUSB30XHCIARMPort" in line and "USB3" in line:
            section = "usb3_xhci"
            continue
        if "AppleUSB20XHCIARMPort" in line and "USB2" in line:
            section = "usb2_xhci"
            continue
        if "IOUSBHostDevice" in line and "connected devices" in line:
            section = "device"
            continue
        # Stop the old-format section parser once the appended sections
        # begin, so their lines are never misread as device/port rows.
        if HPM_UUID_MAP_MARKER in line or USBIOPORT_JOIN_MARKER in line:
            section = None
            continue
        if section in ("usb3_xhci", "usb2_xhci"):
            m = P36_PORT_LINE.match(line)
            if m:
                name, portnum, loc_dec, loc_hex = m.groups()
                records.append({
                    "section": section,
                    "name": name,
                    "usb_c_port_number": int(portnum),
                    "location_id": int(loc_dec),
                    "location_hex": loc_hex,
                    "product": None,
                })
        elif section == "device":
            m = P36_DEVICE_LINE.match(line)
            if m:
                loc_dec, loc_hex, product = m.groups()
                records.append({
                    "section": section,
                    "name": None,
                    "usb_c_port_number": None,
                    "location_id": int(loc_dec),
                    "location_hex": loc_hex,
                    "product": product.strip(),
                })
    return records


# ---------- Probe 37 parser (pre-existing TB fabric sections, unchanged) ----------
APCIEC_RE = re.compile(r"apciec(\d+)@")
ACIO_RE = re.compile(r"acio(\d+)@")
P37_PCIEC_LINE = re.compile(r"^\s+(\S+)\s+(IOService:.*)$")
P37_TBSWITCH_LINE = re.compile(r"^\s+(\S+)\s+UID=(-?\d+) \(0x([0-9a-fA-F]+)\)\s*$")
P37_TUNNELDEV_LINE = re.compile(r"^\s+locationID=(-?\d+) \(0x([0-9a-fA-F]+)\)\s+(.*)$")
P37_SUMMARY_LINE = re.compile(r"^\s*\((\d+) of (\d+) connected USB devices are tunnelled\)\s*$")


def parse_probe37(output):
    records = []
    section = None
    lines = output.splitlines()
    i = 0
    tunnelled_summary = None
    while i < len(lines):
        line = lines[i]
        if "PCIe-C host bridges" in line:
            section = "apciec"
            i += 1
            continue
        if "IOThunderboltSwitch" in line and "host switch UID" in line:
            section = "acio"
            i += 1
            continue
        if "AppleUSBXHCITR (tunnelled USB host controllers)" in line:
            section = "xhcitr"
            i += 1
            continue
        if "Tunnelled USB devices" in line:
            section = "tunnelled_device"
            i += 1
            continue
        # New sections start here; stop treating following lines as the old
        # tunnelled-device table.
        if HPM_UUID_MAP_MARKER in line or "HPM ancestor-join investigation" in line:
            section = None
            i += 1
            continue
        if section == "apciec":
            m = P37_PCIEC_LINE.match(line)
            if m:
                name, path = m.groups()
                am = APCIEC_RE.search(path)
                records.append({
                    "section": section, "name": name, "index": int(am.group(1)) if am else None,
                    "uid": None, "location_id": None, "location_hex": None,
                    "path_token": "apciec" + (am.group(1) if am else "?"),
                })
        elif section == "acio":
            m = P37_TBSWITCH_LINE.match(line)
            if m:
                name, uid_dec, uid_hex = m.groups()
                path = lines[i + 1].strip() if i + 1 < len(lines) else ""
                am = ACIO_RE.search(path)
                records.append({
                    "section": section, "name": name, "index": int(am.group(1)) if am else None,
                    "uid": int(uid_dec), "location_id": None, "location_hex": None,
                    "path_token": "acio" + (am.group(1) if am else "?"),
                })
        elif section == "xhcitr":
            pass  # locationID-only lines, not needed for the port-key question
        elif section == "tunnelled_device":
            sm = P37_SUMMARY_LINE.match(line)
            if sm:
                tunnelled_summary = (int(sm.group(1)), int(sm.group(2)))
            else:
                m = P37_TUNNELDEV_LINE.match(line)
                if m:
                    loc_dec, loc_hex, product = m.groups()
                    records.append({
                        "section": section, "name": product.strip(), "index": None,
                        "uid": None, "location_id": int(loc_dec), "location_hex": loc_hex,
                        "path_token": None,
                    })
        i += 1
    return records, tunnelled_summary


def write_tsv(path, rows, fields):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def main():
    args = sys.argv[1:]
    out_dir = None
    if "--out" in args:
        out_dir = args[args.index("--out") + 1]
    want_json = "--json" in args

    meta = load_corpus_meta()
    folders = sorted(meta.keys())

    p35_rows, p36_rows, p37_rows = [], [], []
    hpm_map_rows = []          # combined probe 35 (native) + probe 36/37 (embedded copy)
    usbioport_join_rows = []   # probe 36 only

    per_folder_35 = {}
    per_folder_36 = {}
    per_folder_37 = {}
    per_folder_37_summary = {}

    folders_with_36_new_format = 0
    folders_with_36_old_format_only = 0
    folders_with_36_usbioport_join = 0
    folders_with_37_new_format = 0
    folders_with_37_old_format_only = 0

    for folder in folders:
        m = meta[folder]
        chip = m.get("chip")
        macos = m.get("macos")
        gen = chip_generation(chip)

        out35 = read_probe_output(folder, "35_hpm_port_uuid.json")
        if out35 is not None:
            recs = parse_probe35(out35)
            per_folder_35[folder] = recs
            for r in recs:
                p35_rows.append({"folder": folder, "chip": chip, "gen": gen, "macos": macos, **r})
                hpm_map_rows.append({
                    "folder": folder, "chip": chip, "gen": gen, "macos": macos,
                    "source_probe": 35, "idx": r["idx"], "class": r["class"],
                    "port_label": r["port_label"], "uuid": r["uuid"],
                })

        out36 = read_probe_output(folder, "36_xhci_port_map.json")
        if out36 is not None:
            recs = parse_probe36(out36)
            per_folder_36[folder] = recs
            for r in recs:
                p36_rows.append({"folder": folder, "chip": chip, "gen": gen, "macos": macos, **r})

            has_map, map_recs = parse_hpm_uuid_map_section(out36)
            has_join, join_recs = parse_usbioport_join_section(out36)
            if has_map:
                folders_with_36_new_format += 1
                for r in map_recs:
                    hpm_map_rows.append({
                        "folder": folder, "chip": chip, "gen": gen, "macos": macos,
                        "source_probe": 36, "idx": r["idx"], "class": r["class"],
                        "port_label": r["port_label"], "uuid": r["uuid"],
                    })
            else:
                folders_with_36_old_format_only += 1
            if has_join:
                folders_with_36_usbioport_join += 1
                for r in join_recs:
                    usbioport_join_rows.append({"folder": folder, "chip": chip, "gen": gen, "macos": macos, **r})

        out37 = read_probe_output(folder, "37_tb_tunnel_port_map.json")
        if out37 is not None:
            recs, summary = parse_probe37(out37)
            per_folder_37[folder] = recs
            per_folder_37_summary[folder] = summary
            for r in recs:
                p37_rows.append({"folder": folder, "chip": chip, "gen": gen, "macos": macos, **r})

            has_map, map_recs = parse_hpm_uuid_map_section(out37)
            if has_map:
                folders_with_37_new_format += 1
                for r in map_recs:
                    hpm_map_rows.append({
                        "folder": folder, "chip": chip, "gen": gen, "macos": macos,
                        "source_probe": 37, "idx": r["idx"], "class": r["class"],
                        "port_label": r["port_label"], "uuid": r["uuid"],
                    })
            else:
                folders_with_37_old_format_only += 1

    # ---------------- Analysis ----------------
    counts = {
        "folders_total": len(folders),
        "folders_with_35": len(per_folder_35),
        "folders_with_36": len(per_folder_36),
        "folders_with_37": len(per_folder_37),
        "folders_with_36_new_format": folders_with_36_new_format,
        "folders_with_36_old_format_only": folders_with_36_old_format_only,
        "folders_with_36_usbioport_join": folders_with_36_usbioport_join,
        "folders_with_37_new_format": folders_with_37_new_format,
        "folders_with_37_old_format_only": folders_with_37_old_format_only,
    }

    # (a) UUID coverage per port, grouped by chip generation
    gen_uuid_coverage = defaultdict(lambda: {"folders": 0, "folders_full_uuid": 0,
                                              "folders_no_uuid": 0, "folders_partial_uuid": 0,
                                              "total_ports": 0, "ports_with_uuid": 0})
    for folder, recs in per_folder_35.items():
        gen = chip_generation(meta[folder].get("chip"))
        usb_c_recs = [r for r in recs if r["port_label"] and r["port_label"].startswith("Port-")]
        if not usb_c_recs:
            continue
        g = gen_uuid_coverage[gen]
        g["folders"] += 1
        with_uuid = sum(1 for r in usb_c_recs if r["uuid"] and r["uuid"] != "(none)")
        g["total_ports"] += len(usb_c_recs)
        g["ports_with_uuid"] += with_uuid
        if with_uuid == len(usb_c_recs):
            g["folders_full_uuid"] += 1
        elif with_uuid == 0:
            g["folders_no_uuid"] += 1
        else:
            g["folders_partial_uuid"] += 1

    # (b) UUID uniqueness within a machine
    uuid_collision_folders = []
    for folder, recs in per_folder_35.items():
        uuids = [r["uuid"] for r in recs if r["uuid"] and r["uuid"] != "(none)"]
        dups = {u: n for u, n in Counter(uuids).items() if n > 1}
        if dups:
            uuid_collision_folders.append((folder, dups))

    # (c) cross-probe @N join: 35 (Port-USB-C@N) vs 36 (usb_c_port_number)
    n_set_compared_35_36 = n_set_match_35_36 = 0
    n_set_mismatch_35_36 = []
    for folder in set(per_folder_35) & set(per_folder_36):
        set35 = {extract_at_n(r["port_label"]) for r in per_folder_35[folder] if is_usb_c_label(r["port_label"])}
        set35.discard(None)
        set36 = {r["usb_c_port_number"] for r in per_folder_36[folder]
                  if r["section"] in ("usb3_xhci", "usb2_xhci") and r["usb_c_port_number"] is not None}
        if not set35 or not set36:
            continue
        n_set_compared_35_36 += 1
        if set35 == set36:
            n_set_match_35_36 += 1
        else:
            n_set_mismatch_35_36.append((folder, sorted(set35), sorted(set36)))

    # Base-M4/M5 renumbering signature: HPM skips @3, xHCI has it as port 3
    base_m4_m5_mismatch_folders = []
    for folder, s35, s36 in n_set_mismatch_35_36:
        gen_chip = meta[folder].get("chip", "")
        is_base = bool(re.fullmatch(r"Apple M[45]", gen_chip))
        if is_base and 3 not in s35 and 4 in s35 and 3 in s36:
            base_m4_m5_mismatch_folders.append(folder)

    # 35 vs 37: acioN index + 1 == Port-USB-C@N hypothesis
    n_index_offset_hits = n_index_offset_total = 0
    for folder in set(per_folder_35) & set(per_folder_37):
        set35 = sorted({extract_at_n(r["port_label"]) for r in per_folder_35[folder]
                         if is_usb_c_label(r["port_label"])} - {None})
        acio_idx = sorted({r["index"] for r in per_folder_37[folder]
                            if r["section"] == "acio" and r["index"] is not None})
        if not set35 or not acio_idx:
            continue
        n_index_offset_total += 1
        if sorted(i + 1 for i in acio_idx) == set35:
            n_index_offset_hits += 1

    # MagSafe UUID presence
    magsafe_with_uuid = magsafe_total = 0
    for folder, recs in per_folder_35.items():
        ms = [r for r in recs if is_magsafe_label(r["port_label"])]
        if ms:
            magsafe_total += 1
            if any(r["uuid"] and r["uuid"] != "(none)" for r in ms):
                magsafe_with_uuid += 1

    # Cross-check: where new-format 36/37 data exists, does the embedded UUID
    # agree with probe 35's own reading of the same port on the same folder?
    # (Will be 0/0 until post-#394 submissions arrive; the check is written
    # now so it activates automatically.)
    cross_probe_uuid_agree = cross_probe_uuid_compared = 0
    by_folder_source = defaultdict(list)
    for r in hpm_map_rows:
        by_folder_source[(r["folder"], r["source_probe"])].append(r)
    for folder in per_folder_35:
        native = {(r["idx"], r["port_label"]): r["uuid"] for r in per_folder_35[folder]}
        for source_probe in (36, 37):
            embedded = by_folder_source.get((folder, source_probe))
            if not embedded:
                continue
            for r in embedded:
                key = (r["idx"], r["port_label"])
                if key in native:
                    cross_probe_uuid_compared += 1
                    if native[key] == r["uuid"]:
                        cross_probe_uuid_agree += 1

    analysis = {
        "counts": counts,
        "gen_uuid_coverage": {k: v for k, v in gen_uuid_coverage.items()},
        "uuid_collision_folders": len(uuid_collision_folders),
        "n_set_compared_35_36": n_set_compared_35_36,
        "n_set_match_35_36": n_set_match_35_36,
        "n_set_mismatch_35_36": len(n_set_mismatch_35_36),
        "base_m4_m5_mismatch_folders": sorted(base_m4_m5_mismatch_folders),
        "n_index_offset_hits": n_index_offset_hits,
        "n_index_offset_total": n_index_offset_total,
        "magsafe_with_uuid": magsafe_with_uuid,
        "magsafe_total": magsafe_total,
        "cross_probe_uuid_compared": cross_probe_uuid_compared,
        "cross_probe_uuid_agree": cross_probe_uuid_agree,
    }

    # ---------------- Output ----------------
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        write_tsv(os.path.join(out_dir, "probe35.tsv"), p35_rows,
                  ["folder", "chip", "gen", "macos", "idx", "port_label", "class",
                   "uuid", "rid", "address", "connection_uuid"])
        write_tsv(os.path.join(out_dir, "probe36.tsv"), p36_rows,
                  ["folder", "chip", "gen", "macos", "section", "name",
                   "usb_c_port_number", "location_id", "location_hex", "product"])
        write_tsv(os.path.join(out_dir, "probe37.tsv"), p37_rows,
                  ["folder", "chip", "gen", "macos", "section", "name", "index",
                   "uid", "location_id", "location_hex", "path_token"])
        write_tsv(os.path.join(out_dir, "hpm_uuid_map.tsv"), hpm_map_rows,
                  ["folder", "chip", "gen", "macos", "source_probe", "idx",
                   "class", "port_label", "uuid"])
        write_tsv(os.path.join(out_dir, "usbioport_join.tsv"), usbioport_join_rows,
                  ["folder", "chip", "gen", "macos", "xhci_class", "name",
                   "usb_io_port", "hpm_class", "hpm_uuid"])
        with open(os.path.join(out_dir, "analysis.json"), "w") as f:
            json.dump(analysis, f, indent=2, default=str)
        print(f"wrote TSVs + analysis.json to {out_dir}", file=sys.stderr)

    if want_json:
        print(json.dumps({
            "analysis": analysis,
            "probe35": p35_rows,
            "probe36": p36_rows,
            "probe37": p37_rows,
            "hpm_uuid_map": hpm_map_rows,
            "usbioport_join": usbioport_join_rows,
        }, indent=2, default=str))
        return

    # Default: markdown findings summary to stdout.
    print(f"# Port-key mining pass (probes 35/36/37)\n")
    print(f"Corpus: {counts['folders_total']} folders total.")
    print(f"- Probe 35 present: {counts['folders_with_35']}")
    print(f"- Probe 36 present: {counts['folders_with_36']} "
          f"({counts['folders_with_36_new_format']} new-format with HPM UUID map, "
          f"{counts['folders_with_36_old_format_only']} old-format only, "
          f"{counts['folders_with_36_usbioport_join']} with the per-record UsbIOPort join)")
    print(f"- Probe 37 present: {counts['folders_with_37']} "
          f"({counts['folders_with_37_new_format']} new-format with HPM UUID map, "
          f"{counts['folders_with_37_old_format_only']} old-format only)")
    print()
    print("## UUID coverage by chip generation (probe 35)\n")
    print("| Gen | Folders | Ports | Ports with UUID |")
    print("|---|---|---|---|")
    for gen, g in sorted(gen_uuid_coverage.items()):
        print(f"| {gen} | {g['folders']} | {g['total_ports']} | {g['ports_with_uuid']} |")
    print()
    print(f"UUID collisions within a machine: {len(uuid_collision_folders)} folders.")
    print(f"MagSafe ports with a UUID: {magsafe_with_uuid} / {magsafe_total} folders that have one.")
    print()
    print(f"@N cross-probe join (35 vs 36): {n_set_match_35_36} / {n_set_compared_35_36} matched exactly; "
          f"{len(base_m4_m5_mismatch_folders)} of the mismatches are the confirmed base-M4/M5 "
          f"renumbering signature (HPM @1/@2/@4 vs xHCI 1/2/3).")
    print(f"acioN index + 1 == Port-USB-C@N (35 vs 37): {n_index_offset_hits} / {n_index_offset_total}.")
    print()
    print(f"Cross-probe UUID agreement (probe 35's own reading vs the copy embedded in "
          f"probes 36/37, post-#394 only): {cross_probe_uuid_agree} / {cross_probe_uuid_compared} "
          f"compared. 0/0 is expected until a post-#394 submission lands.")
    print()
    print("Pass --out DIR to also write probe35.tsv, probe36.tsv, probe37.tsv, "
          "hpm_uuid_map.tsv, usbioport_join.tsv, and analysis.json.")


if __name__ == "__main__":
    main()
