// Generates webviews/src/pages/settings/generated/strings.json from the xcstrings catalogs, so the
// Settings page has no string that lives only in TypeScript. It keeps only the keys the page
// uses: every key the settings schema names (CmuxNextSettings catalog) and every
// `settingsPage.` key (CmuxNextSettingsWindow catalog), per locale.
//
//   bun scripts/pages/settings/generate-strings.mjs          # write the file
//   bun scripts/pages/settings/generate-strings.mjs --check  # fail when it is stale
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

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

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const sources = "Packages/macOS/CmuxNext/Sources";
const schemaPath = path.join(root, "schemas/settings/settings-schema.json");
const schemaCatalog = path.join(root, sources, "CmuxNextSettings/Localizable.xcstrings");
const pageCatalog = path.join(root, sources, "CmuxNextSettingsWindow/Localizable.xcstrings");
const outPath = path.join(root, "webviews/src/pages/settings/generated/strings.json");

const readJSON = (file) => JSON.parse(readFileSync(file, "utf8"));

function schemaKeys(schema) {
  const keys = new Set();
  for (const section of schema.sections) keys.add(section.title.key);
  for (const row of schema.rows) {
    for (const field of ["title", "help", "group", "default_label"]) if (row[field]?.key) keys.add(row[field].key);
    for (const choice of row.choices ?? []) if (choice.title.key) keys.add(choice.title.key);
  }
  keys.delete(null);
  return keys;
}

export function generate() {
  const schemaStrings = readJSON(schemaCatalog).strings;
  const pageStrings = readJSON(pageCatalog).strings;
  const wanted = [
    ...[...schemaKeys(readJSON(schemaPath))].map((key) => [key, schemaStrings[key]]),
    ...Object.keys(pageStrings)
      .filter((key) => key.startsWith("settingsPage."))
      .map((key) => [key, pageStrings[key]]),
  ].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
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
  return { json: JSON.stringify(out, null, 2) + "\n", errors };
}

if (import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url)) {
  const { json, errors } = generate();
  if (errors.length) {
    console.error(errors.slice(0, 50).join("\n"));
    console.error(`error: ${errors.length} strings missing`);
    process.exit(1);
  }
  if (process.argv.includes("--check")) {
    let current = "";
    try {
      current = readFileSync(outPath, "utf8");
    } catch {
      // A missing file is stale.
    }
    if (current !== json) {
      console.error(
        `error: ${path.relative(root, outPath)} is stale; run bun scripts/pages/settings/generate-strings.mjs`,
      );
      process.exit(1);
    }
    console.log("settings strings are current");
  } else {
    mkdirSync(path.dirname(outPath), { recursive: true });
    writeFileSync(outPath, json);
    console.log(`wrote ${path.relative(root, outPath)}`);
  }
}
