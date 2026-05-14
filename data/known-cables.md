# Known cables

A working list of USB-C cables that have been reported to WhatCable via the
in-app "Report this cable" flow. This is a memory aid for future trust-signal
and inventory work, seeded from the closed [`cable-report`](https://github.com/darrylmorley/whatcable/issues?q=label%3Acable-report)
issues on GitHub.

The full reports (with reporter notes, dates, and triage replies) live on the
issue tracker. This file holds a condensed, deduplicated view of the e-marker
fingerprints. Vendor names below come from the bundled USB-IF list (shipped
with WhatCable v0.8.1 onwards), not from whatever name the reporting build
showed at the time.

## Why this file exists

WhatCable's [issue template](../.github/ISSUE_TEMPLATE/cable-report.yml)
states the goal: a public database of known-good and counterfeit USB-C cable
fingerprints. The Cable Trust Signals work (see `planning/cable-trust-signals.md`)
will eventually consume a curated subset of this. For now it is a flat
hand-maintained markdown table; format may change once the consumer exists.

## Table

| Brand / model context | VID | PID | Cable VDO | Vendor (USB-IF) | XID | Speed | Power | Type | Source |
|---|---|---|---|---|---|---|---|---|---|
| UGOURD TB5/USB4 cable, AliExpress (no USB-IF cert) | `0x0138` | `0x0310` | `0x000A2644` | Unregistered | none | USB4 Gen 4 (80 Gbps) | 5 A / 50 V (250 W) | passive | [#71](https://github.com/darrylmorley/whatcable/issues/71) |
| CalDigit TS5 Plus bundled TB5 cable | `0x01B6` | `0x4003` | `0x110A2644` | Unregistered | `0x303C` | USB4 Gen 4 (80 Gbps) | 5 A / 50 V (250 W) | passive | [#89](https://github.com/darrylmorley/whatcable/issues/89) |
| CalDigit TB5 cable, Amazon | `0x01B6` | `0x4003` | `0x110A2644` | Unregistered | `0x303C` | USB4 Gen 4 (80 Gbps) | 5 A / 50 V (250 W) | passive | [#90](https://github.com/darrylmorley/whatcable/issues/90) |
| HP USB-C dock (circa 2019), built-in tethered cable | `0x03F0` | `0x0967` | `0x00402FB2` | HP Inc. | none | USB 3.2 Gen 2 (10 Gbps) | 3 A / 50 V (150 W) | passive | [#112](https://github.com/darrylmorley/whatcable/issues/112) |
| Bundled in UGREEN Revodok Max 213 (U710) dock; housing marked TB4 | `0x0522` | `0x0A06` | `0x11082043` | ACON, Advanced-Connectek, Inc. | `0x939` | USB4 Gen 3 (20 / 40 Gbps) | 5 A / 20 V (100 W) | passive | [#84](https://github.com/darrylmorley/whatcable/issues/84) |
| Anker 333 USB-C 3.3 ft nylon | `0x201C` | `0x0000` | `0x00082040` | Hongkong Freeport Electronics Co., Limited | none | USB 2.0 (480 Mbps) | 5 A / 20 V (100 W) | passive | [#60](https://github.com/darrylmorley/whatcable/issues/60) |
| Monoprice Essentials USB-C 10 Gbps 0.5 m | `0x2095` | `0x004F` |  | CE LINK LIMITED | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#48](https://github.com/darrylmorley/whatcable/issues/48) |
| delock TB3-branded cable | `0x20C2` | `0x0005` |  | Sumitomo Electric Ind., Ltd., Optical Comm. R&D Lab | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#44](https://github.com/darrylmorley/whatcable/issues/44) |
| CalDigit TS4 dock bundled cable (likely) | `0x2B1D` | `0x1512` | `0x11082043` | Lintes Technology Co., Ltd. | none | USB4 Gen 3 (20 / 40 Gbps) | 5 A / 20 V (100 W) | passive | [#62](https://github.com/darrylmorley/whatcable/issues/62) |
| Cable Matters TB5 1M cable | `0x2B1D` | `0x1533` | `0x110A2644` | Lintes Technology Co., Ltd. | `0x5F5` | USB4 Gen 4 (80 Gbps) | 5 A / 50 V (250 W) | passive | [#110](https://github.com/darrylmorley/whatcable/issues/110) |
| Dbilida TB4-branded 240 W cable, Amazon (no USB-IF cert) | `0x2E99` | `0x0000` |  | Hynetek Semiconductor Co., Ltd | none | USB4 Gen 3 (20 / 40 Gbps) | 5 A / 50 V (250 W) | passive | [#49](https://github.com/darrylmorley/whatcable/issues/49) |
| Satechi TB5 1M cable | `0x310E` | `0x4000` | `0x110A2644` | Sariana LLC (dba SATECHI) | `0x5F5` | USB4 Gen 4 (80 Gbps) | 5 A / 50 V (250 W) | passive | [#109](https://github.com/darrylmorley/whatcable/issues/109) |
| acasis cable bundled with TBU405M1 enclosure | `0x315C` | `0x0000` |  | Chengdu Convenientpower Semiconductor Co., LTD | none | USB4 Gen 3 (20 / 40 Gbps) | 5 A / 20 V (100 W) | passive | [#45](https://github.com/darrylmorley/whatcable/issues/45) |
| Silkland 80 Gbps USB4/TB5 cable 3.3 ft, Amazon | `0x3678` | `0x0000` | `0x000A2644` | (Silkland) Shenzhen Guanhai Technology Co., Ltd. | none | USB4 Gen 4 (80 Gbps) | 5 A / 50 V (250 W) | passive | [#98](https://github.com/darrylmorley/whatcable/issues/98) |
| CANDYSIGN MagTie 100 W USB-C, charging-only (USB 2.0) | `0x36E9` | `0x3000` | `0x140A4040` | ifanr Inc. | `0x15141` | USB 2.0 (480 Mbps) | 5 A / 20 V (100 W) | passive | [#113](https://github.com/darrylmorley/whatcable/issues/113) |
| Unknown braided TB-logo cable, possibly Amazon (unregistered VID with valid cert) | `0x6666` | `0x0000` | `0x00084042` | Unregistered | `0x52C` | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#99](https://github.com/darrylmorley/whatcable/issues/99) |
| CUKTECH No.6 140 W (e-marker present but VID/PID/speed all zeroed) | `0x0000` | `0x0000` |  | (zeroed) | none | (none advertised) | (not advertised) | passive | [#61](https://github.com/darrylmorley/whatcable/issues/61) |
| vorodcip generic USB-C cable, Amazon Japan (VID/PID zeroed) | `0x0000` | `0x0000` | `0x000A6642` | (zeroed) | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 50 V (250 W) | passive | [#91](https://github.com/darrylmorley/whatcable/issues/91) |
| Dockcase 100 W 10 Gbps 0.5 m (VID/PID zeroed) | `0x0000` | `0x0000` | `0x00082042` | (zeroed) | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#92](https://github.com/darrylmorley/whatcable/issues/92) |
| Aulumu M07 (VID/PID zeroed) | `0x0000` | `0x0000` | `0x000A4642` | (zeroed) | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 50 V (250 W) | passive | [#108](https://github.com/darrylmorley/whatcable/issues/108) |
| Lindy Anthra Line USB 3.2 Gen 2x2 1 m (36901), e-marker reports Gen 2 not Gen 2x2, VID zeroed | `0x0000` | `0x0000` | `0x00082052` | (zeroed) | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#116](https://github.com/darrylmorley/whatcable/issues/116) |

Sorted by VID. The zeroed-fingerprint entry is parked at the bottom because it
is identity-less.

## Patterns worth flagging for trust-signals work

Three of the nine reports show patterns that the planned Cable Trust Signals
heuristics should pick up:

1. **Marketing claim outpaces e-marker capability.** #49 (Dbilida) is sold as
   "Thunderbolt 4 / 40 Gbps / 240 W" but the e-marker reports passive USB4
   Gen 3 with no USB-IF cert. The cable may carry the advertised data rate,
   but there is no cert backing the claim.
2. **Genuinely unregistered VID with no XID.** #71 (UGOURD AliExpress) reports
   80 Gbps USB4 Gen 4 from an unregistered VID and zero XID. Plausibly real
   silicon, but unverifiable from the e-marker alone.
3. **Zeroed identity fields.** #61 (CUKTECH No.6) has a present e-marker that
   reports `0x0000` for VID, PID, and no speed. Already flagged by trust
   signals today; the report confirms the pattern is real and not a parser
   bug.

The other six reports describe cables whose e-marker matches their marketing.

## Adding new entries

When a new cable-report issue lands and you've triaged + closed it,
the workflow is:

```bash
swift scripts/sync-cable-reports.swift     # pulls rows from gh
swift scripts/render-known-cables.swift    # rebuilds docs/cables.html
```

The sync script reads every closed `cable-report` issue via `gh`, parses
the e-marker fingerprint table, looks up canonical USB-IF vendor names
from the bundled TSV, and rewrites the table block above. Existing rows'
"Brand / model context" cells are preserved by issue number; brand new
rows land with `(needs review)` as a placeholder.

After running the sync:

1. Look at any rows still showing `(needs review)`. Open the source issue,
   read the reporter's "What's the story" notes, and replace the
   placeholder with a one-line phrase covering brand and purchase context.
   Strip Amazon affiliate links, full product titles, and anything that
   reads as personal context.
2. If the report shows a trust-signal pattern (marketing / e-marker
   mismatch, unregistered VID + no cert, zeroed fields, impossible PDOs),
   add a bullet to the Patterns section above.
3. Re-run the renderer if you edited the markdown again.
4. Commit `data/known-cables.md` and `docs/cables.html` together.

If you need to fix a row by hand (say a vendor name TSV entry was wrong
upstream), edit `data/known-cables.md` directly. The sync script will
preserve your edits as long as they live in the "Brand / model context"
column. Other columns get rewritten on next sync, so structural changes
need to land in the script or the underlying issue body.

This file is not bundled into the app. It is a human reference. When the
trust-signals or inventory features need this data at runtime, we'll
formalise it then.
