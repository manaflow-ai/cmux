#!/usr/bin/env node
// Builds the icon picker's emoji table (webviews/src/icon-picker/generated/emoji-data.json) from
// pinned sources (sources.json, each checked by SHA-256): Unicode emoji-test.txt and the CLDR
// annotation packages (Unicode License v3), and emojibase-data's GitHub shortcodes (MIT). The
// output is committed; the sources are not. Licenses: webviews/src/icon-picker/generated/LICENSES.md.
//
//   node scripts/icon-picker/gen-emoji-data.mjs          # download (cached), write the table
//   node scripts/icon-picker/gen-emoji-data.mjs --check  # fail when the committed table is stale
//
// Row layout (arrays keep the table small; emojiData.ts names the fields):
//   [emoji, group, version, nameEn, keywordsEn, nameJa, keywordsJa, shortcodes, tones?]
// `shortcodes` are "|"-joined, the first is the one shown ("tada"); `group` indexes `groups`; `version` is the Emoji version times 10 (15.1 -> 151); keywords are
// joined with "|" (country flags add their ISO code, "jp"); `tones` lists the five uniform skin-tone forms, light to dark, when they exist.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const webviews = path.resolve(here, "../..");
const out = path.join(webviews, "src/icon-picker/generated/emoji-data.json");
const sources = JSON.parse(fs.readFileSync(path.join(here, "sources.json"), "utf8"));
const cache = path.join(os.tmpdir(), "cmux-icon-picker-sources");
const TONES = ["light", "medium-light", "medium", "medium-dark", "dark"];
const GROUPS = [
  "smileys-emotion",
  "people-body",
  "animals-nature",
  "food-drink",
  "travel-places",
  "activities",
  "objects",
  "symbols",
  "flags",
];

async function fetchPinned(source) {
  fs.mkdirSync(cache, { recursive: true });
  const file = path.join(cache, `${source.sha256}-${path.basename(new URL(source.url).pathname)}`);
  if (!fs.existsSync(file)) {
    const response = await fetch(source.url);
    if (!response.ok) throw new Error(`${source.url}: HTTP ${response.status}`);
    fs.writeFileSync(file, Buffer.from(await response.arrayBuffer()));
  }
  const digest = createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  if (digest !== source.sha256) {
    fs.rmSync(file);
    throw new Error(`${source.url}: SHA-256 ${digest}, expected ${source.sha256}`);
  }
  return file;
}

function untar(file) {
  const dir = `${file}.d`;
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir);
    execFileSync("tar", ["xzf", file, "-C", dir]);
  }
  return path.join(dir, "package");
}

/** `{emoji: {default: [...], tts: [...]}}` for one locale, base and derived merged. */
function annotations(annotationsDir, derivedDir, locale) {
  const base = JSON.parse(
    fs.readFileSync(path.join(annotationsDir, "annotations", locale, "annotations.json"), "utf8"),
  );
  const derived = JSON.parse(
    fs.readFileSync(path.join(derivedDir, "annotationsDerived", locale, "annotations.json"), "utf8"),
  );
  return { ...derived.annotationsDerived.annotations, ...base.annotations.annotations };
}

const stripVS = (text) => text.replace(/️/g, "");

function lookup(table, emoji) {
  return table[emoji] ?? table[stripVS(emoji)];
}

/** A country flag's ISO 3166 code ("jp" for the Japan flag), an alias CLDR does not list. */
function regionCode(emoji) {
  const points = [...emoji].map((ch) => ch.codePointAt(0));
  if (points.length !== 2 || !points.every((p) => p >= 0x1f1e6 && p <= 0x1f1ff)) return null;
  return String.fromCharCode(...points.map((p) => p - 0x1f1e6 + 97));
}

function entryNames(table, emoji, fallbackName) {
  const entry = lookup(table, emoji);
  const name = entry?.tts?.[0] ?? fallbackName;
  const keywords = (entry?.default ?? []).filter((word) => word !== name);
  const region = regionCode(emoji);
  if (region) keywords.push(region);
  return [name, keywords.join("|")];
}

export async function build() {
  const testFile = await fetchPinned(sources.emojiTest);
  const annotationsDir = untar(await fetchPinned(sources.annotations));
  const derivedDir = untar(await fetchPinned(sources.annotationsDerived));
  const en = annotations(annotationsDir, derivedDir, "en");
  const ja = annotations(annotationsDir, derivedDir, "ja");
  const shortcodeTable = JSON.parse(
    fs.readFileSync(path.join(untar(await fetchPinned(sources.shortcodes)), sources.shortcodes.file), "utf8"),
  );
  // emojibase keys: upper-case hex code points joined by "-", without U+FE0F.
  const shortcodes = (emoji) => {
    const key = [...stripVS(emoji)].map((ch) => ch.codePointAt(0).toString(16).toUpperCase()).join("-");
    const value = shortcodeTable[key] ?? [];
    return (Array.isArray(value) ? value : [value]).join("|");
  };

  const rows = [];
  const byName = new Map();
  let group = -1;
  for (const line of fs.readFileSync(testFile, "utf8").split("\n")) {
    const header = line.match(/^# group: (.+)$/);
    if (header) {
      const id = header[1].toLowerCase().replace(/ & /g, "-").replace(/ /g, "-");
      group = GROUPS.indexOf(id);
      continue;
    }
    const match = line.match(/^[0-9A-F ]+; fully-qualified\s+# (\S+) E(\d+\.\d+) (.+)$/);
    if (!match || group < 0) continue;
    const [, emoji, version, name] = match;
    const tone = name.match(/^(.+): (light|medium-light|medium|medium-dark|dark) skin tone$/);
    if (tone) {
      const row = byName.get(tone[1]);
      if (row) {
        row[8] ??= [];
        row[8][TONES.indexOf(tone[2])] = emoji;
      }
      continue;
    }
    if (name.includes("skin tone")) continue; // mixed tones: reached through the uniform form only
    const row = [
      emoji,
      group,
      Math.round(Number(version) * 10),
      ...entryNames(en, emoji, name),
      ...entryNames(ja, emoji, name),
      shortcodes(emoji),
    ];
    rows.push(row);
    byName.set(name, row);
  }
  for (const row of rows) {
    if (row[8] && row[8].filter(Boolean).length !== TONES.length) row.length = 8;
  }
  const table = {
    unicode: {
      emoji: sources.emojiTest.version,
      cldr: sources.annotations.version,
      shortcodes: sources.shortcodes.version,
    },
    groups: GROUPS,
    rows,
  };
  return `${JSON.stringify(table).replace(/\],\[/g, "],\n[")}\n`;
}

const text = await build();
if (process.argv.includes("--check")) {
  const current = fs.existsSync(out) ? fs.readFileSync(out, "utf8") : "";
  if (current !== text) {
    console.error(`error: ${path.relative(webviews, out)} is stale; run scripts/icon-picker/gen-emoji-data.mjs`);
    process.exit(1);
  }
  console.log("emoji table is current");
} else {
  fs.writeFileSync(out, text);
  console.log(`wrote ${path.relative(webviews, out)} (${text.length} chars)`);
}
