#!/usr/bin/env node
// The one string generator for React pages (plans/cmux-next/react-pages.md 1): each page's
// `generated/strings.json` (`{<locale>: {<key>: <value>}}`) comes from xcstrings catalogs, so no
// string lives only in TypeScript. Every locale scripts/cmux-next/check-l10n.sh requires must have
// every key; a missing value fails. Merged with the Settings lead's
// webviews/scripts/settings/generate-strings.mjs (branch feat-cmux-next-settings-react): a page
// lists catalogs and, per catalog, which keys it uses.
//   node scripts/pages/gen-strings.mjs           # write
//   node scripts/pages/gen-strings.mjs --check   # fail when a generated file is stale
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const repo = path.resolve(webviews, "..");
const sources = "Packages/macOS/CmuxNext/Sources";

// The languages scripts/cmux-next/check-l10n.sh requires, in its order.
export const LOCALES = [
  "en",
  "ar",
  "bs",
  "da",
  "de",
  "es",
  "fr",
  "it",
  "ja",
  "km",
  "ko",
  "nb",
  "pl",
  "pt-BR",
  "ru",
  "th",
  "tr",
  "uk",
  "vi",
  "zh-Hans",
  "zh-Hant",
];

const readJSON = (file) => JSON.parse(fs.readFileSync(path.join(repo, file), "utf8"));

/** Every key a settings schema export names (titles, help, groups, default labels, choices). */
export function schemaKeys(schemaFile) {
  const schema = readJSON(schemaFile);
  const keys = new Set();
  for (const section of schema.sections ?? []) if (section.title?.key) keys.add(section.title.key);
  for (const row of schema.rows ?? []) {
    for (const field of ["title", "help", "group", "default_label"]) if (row[field]?.key) keys.add(row[field].key);
    for (const choice of row.choices ?? []) if (choice.title?.key) keys.add(choice.title.key);
  }
  return keys;
}

// Page -> output and catalogs. `keys(catalogKeys)` picks the keys the page uses (all by default).
// The History table moves next to the page when the Swift page is deleted (react-pages.md H4).
// The Settings page adds its entry here (schema keys from CmuxNextSettings + `settingsPage.` keys
// from CmuxNextSettingsWindow).
export const PAGES = {
  history: {
    out: "webviews/src/pages/history/generated/strings.json",
    catalogs: [{ file: `${sources}/CmuxNextHistory/Resources/Localizable.xcstrings` }],
  },
};

export function generate(page) {
  const wanted = [];
  for (const catalog of page.catalogs) {
    const strings = readJSON(catalog.file).strings;
    const keys = catalog.keys ? [...catalog.keys(Object.keys(strings))] : Object.keys(strings);
    for (const key of keys) wanted.push([key, strings[key]]);
  }
  wanted.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const errors = [];
  const out = {};
  for (const locale of LOCALES) {
    out[locale] = {};
    for (const [key, entry] of wanted) {
      const value = entry?.localizations?.[locale]?.stringUnit?.value;
      if (typeof value !== "string" || value.trim() === "") errors.push(`${key}: missing ${locale}`);
      else out[locale][key] = value;
    }
  }
  return { json: `${JSON.stringify(out, null, 2)}\n`, errors };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const check = process.argv.includes("--check");
  let failed = false;
  for (const [name, page] of Object.entries(PAGES)) {
    const { json, errors } = generate(page);
    const target = path.join(repo, page.out);
    if (errors.length) {
      console.error(`${name}: ${errors.length} strings missing\n  ${errors.slice(0, 20).join("\n  ")}`);
      failed = true;
      continue;
    }
    if (check) {
      const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : "";
      if (current !== json) {
        console.error(`stale: ${page.out} (run node webviews/scripts/pages/gen-strings.mjs)`);
        failed = true;
      }
    } else {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, json);
    }
  }
  process.exit(failed ? 1 : 0);
}
