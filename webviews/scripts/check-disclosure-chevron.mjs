#!/usr/bin/env node
// No control draws its disclosure chevron as a text "⌄" (design/disclosure-chevron.md): a font's
// glyph sits on the baseline with the fallback font's side bearing, so its room after the label
// changes per font and per machine, and two shipped chips drew it on their last letter (Leo,
// 2026-11-27: "these chevrons are too close dont we have any guidelines for these yet?"). Draw the
// registry chevron: DisclosureFace / DisclosureChevron (agent-session/acpmux/DisclosureFace.tsx).
// Galleries, tests and comments may name the glyph.
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const root = path.join(import.meta.dirname, "..", "src");
const bad = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) {
      if (name !== "gallery") walk(file);
      continue;
    }
    if (!name.endsWith(".tsx") || /\.(gallery|test)\.tsx$/.test(name)) continue;
    readFileSync(file, "utf8")
      .split("\n")
      .forEach((line, index) => {
        const code = line.replace(/\/\/.*$/, "").replace(/\/\*.*?\*\//g, "");
        if (/⌄|\\u2304|\\u\{2304\}/.test(code) && !/^\s*\*/.test(line))
          bad.push(`${path.relative(path.join(root, ".."), file)}:${index + 1}: ${line.trim()}`);
      });
  }
};
walk(root);
if (bad.length > 0) {
  console.error(
    `A text "⌄" draws a disclosure chevron; use DisclosureFace or DisclosureChevron (design/disclosure-chevron.md):\n${bad.join("\n")}`,
  );
  process.exit(1);
}
console.log("check:disclosure-chevron: no text chevrons");
