// Loads the generated cable dataset for the /cables page.
//
// The list comes from docs/cables.json (written by
// scripts/build-cable-db.swift, which runs before Eleventy in
// scripts/build-site.sh). The "updated" timestamp comes from the
// mtime of data/known-cables.md so the visible date reflects when
// the human-curated source was last edited, not when Eleventy ran.
//
// If either file is missing (e.g. someone runs `bun run site:build`
// standalone on a fresh checkout before the Swift step), we fall
// back to an empty list and today's date so the build still
// succeeds instead of blowing up.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const cablesPath = path.join(repoRoot, "docs", "cables.json");
const sourcePath = path.join(repoRoot, "data", "known-cables.md");

function readList() {
  try {
    return JSON.parse(fs.readFileSync(cablesPath, "utf8"));
  } catch {
    return [];
  }
}

function readUpdated() {
  try {
    return fs.statSync(sourcePath).mtime;
  } catch {
    return new Date();
  }
}

const list = readList();

export default {
  list,
  count: list.length,
  updated: readUpdated(),
};
