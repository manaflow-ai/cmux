#!/usr/bin/env node
// Writes each React page's string table from its xcstrings source
// (plans/cmux-next/react-pages.md 1): `src/pages/<page>/generated/strings.json`,
// `{<language>: {<key>: <value>}}` for every language the table has.
//   node scripts/pages/gen-strings.mjs           # write
//   node scripts/pages/gen-strings.mjs --check   # fail when a generated file is stale
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const repo = path.resolve(webviews, "..");

// Page -> its xcstrings table. The History table moves next to the page when the Swift page is
// deleted (react-pages.md slice H4).
const PAGES = {
  history: "Packages/macOS/CmuxNext/Sources/CmuxNextHistory/Resources/Localizable.xcstrings",
};

function table(source) {
  const catalog = JSON.parse(fs.readFileSync(path.join(repo, source), "utf8"));
  const out = {};
  for (const key of Object.keys(catalog.strings).sort()) {
    const localizations = catalog.strings[key].localizations ?? {};
    for (const language of Object.keys(localizations).sort()) {
      const value = localizations[language]?.stringUnit?.value;
      if (typeof value !== "string" || value === "") continue;
      (out[language] ??= {})[key] = value;
    }
  }
  const sorted = {};
  for (const language of Object.keys(out).sort()) sorted[language] = out[language];
  return `${JSON.stringify(sorted, null, 2)}\n`;
}

const check = process.argv.includes("--check");
let stale = 0;
for (const [page, source] of Object.entries(PAGES)) {
  const target = path.join(webviews, "src/pages", page, "generated/strings.json");
  const text = table(source);
  if (check) {
    const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : "";
    if (current !== text) {
      console.error(`stale: ${path.relative(repo, target)} (run node webviews/scripts/pages/gen-strings.mjs)`);
      stale += 1;
    }
  } else {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, text);
  }
}
process.exit(stale ? 1 : 0);
