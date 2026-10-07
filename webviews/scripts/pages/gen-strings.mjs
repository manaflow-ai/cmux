#!/usr/bin/env node
// The one string generator for React pages (plans/cmux-next/react-pages.md 1): each page's
// `generated/strings.json` (`{<locale>: {<key>: <value>}}`) comes from xcstrings catalogs, so no
// string lives only in TypeScript. Every locale scripts/cmux-next/check-l10n.sh requires must have
// every key; a missing value fails. Merged with the Settings lead's
// webviews/scripts/settings/generate-strings.mjs (branch feat-cmux-next-settings-react): a page
// lists catalogs and, per catalog, which keys it uses.
//   node scripts/pages/gen-strings.mjs           # write every page
//   node scripts/pages/gen-strings.mjs --check   # fail when a generated file is stale
//   node scripts/pages/gen-strings.mjs settings  # only the named pages
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
export const PAGES = {
  gallery: {
    out: "webviews/src/gallery/generated/strings.json",
    catalogs: [{ file: "webviews/src/gallery/Localizable.xcstrings" }],
  },
  diff: {
    splitLocales: true,
    out: "webviews/src/pages/diff/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/diff/Localizable.xcstrings" }],
  },
  variantPick: {
    out: "webviews/src/ui/variant-pick/generated/strings.json",
    catalogs: [{ file: "webviews/src/ui/variant-pick/Localizable.xcstrings" }],
  },
  // Every key the settings schema names (CmuxNextSettings catalog), every `settingsPage.` and
  // `settingsWindow.` key (CmuxNextSettingsWindow catalog); merged from the Settings lead's generate-strings.mjs with the
  // same output.
  settings: {
    out: "webviews/src/pages/settings/generated/strings.json",
    catalogs: [
      {
        file: `${sources}/CmuxNextSettings/Localizable.xcstrings`,
        keys: () => schemaKeys("schemas/settings/settings-schema.json"),
      },
      {
        file: `${sources}/CmuxNextSettingsWindow/Localizable.xcstrings`,
        // `settingsWindow.` keys too: the page draws the Swift window's cards (R82 commits 2-5).
        keys: (all) => all.filter((key) => key.startsWith("settingsPage.") || key.startsWith("settingsWindow.")),
      },
      {
        file: `${sources}/CmuxNextActions/BrowserProfileActions.xcstrings`,
        keys: () => ["action.browserProfile.manageExtensions"],
      },
      {
        file: `${sources}/CmuxNextActions/ActionCatalog.xcstrings`,
        keys: () => ["action.reloadConfiguration"],
      },
    ],
  },
  history: {
    out: "webviews/src/pages/history/generated/strings.json",
    catalogs: [{ file: `${sources}/CmuxNextHistory/Resources/Localizable.xcstrings` }],
  },
  // The App Store page reads the `store.` keys of the app platform's table until the Swift store
  // is deleted (react-pages.md A3); then the table moves next to the page.
  apps: {
    out: "webviews/src/pages/apps/generated/strings.json",
    catalogs: [
      {
        file: `${sources}/CmuxNextApps/Resources/Localizable.xcstrings`,
        keys: (all) => all.filter((key) => key.startsWith("store.")),
      },
    ],
  },
  // The Keyboard Shortcuts page has its own table in the app's resources.
  keybindings: {
    out: "webviews/src/pages/keybindings/generated/strings.json",
    catalogs: [{ file: `${sources}/CmuxNextApp/Resources/KeybindingsPage.xcstrings` }],
  },
  // The Passwords page shares its table with its Swift provider and sheets (`passwords.page.` keys).
  passwords: {
    out: "webviews/src/pages/passwords/generated/strings.json",
    catalogs: [
      {
        file: `${sources}/CmuxNextApp/Resources/Passwords.xcstrings`,
        keys: (all) => all.filter((key) => key.startsWith("passwords.page.")),
      },
    ],
  },
  // Cloud has no Swift page, so its table lives next to the page.
  cloud: {
    out: "webviews/src/pages/cloud/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/cloud/Localizable.xcstrings" }],
  },
  // The changelog page (cmux-page://cmux.changelog/, R114); its table lives next to it.
  changelog: {
    out: "webviews/src/pages/changelog/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/changelog/Localizable.xcstrings" }],
  },
  // The CodeRouter page (cmux-page://cmux.coderouter/) has no Swift page; its table lives next to it.
  coderouter: {
    out: "webviews/src/pages/coderouter/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/coderouter/Localizable.xcstrings" }],
  },
  // The icon picker (cmux-page://cmux.icon-picker/) has no Swift page; its table lives next to it.
  "icon-picker": {
    out: "webviews/src/pages/icon-picker/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/icon-picker/Localizable.xcstrings" }],
  },
  // The markdown editor (cmux-page://cmux.markdown/) has no Swift page; its table lives next to it.
  markdown: {
    out: "webviews/src/pages/markdown/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/markdown/Localizable.xcstrings" }],
  },
  // The code editor (cmux-page://cmux.editor/) has no Swift page; its table lives next to it.
  editor: {
    out: "webviews/src/pages/editor/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/editor/Localizable.xcstrings" }],
  },
  // The agent pane and its new tab screen (agent-session/acpmux, `newTab.` keys); its table lives
  // next to it. The pane's build splits it into locales/<code>.js (build-agent-pane-web.sh).
  agentPane: {
    out: "webviews/src/agent-session/acpmux/generated/strings.json",
    catalogs: [{ file: "webviews/src/agent-session/acpmux/Localizable.xcstrings" }],
  },
  // The empty states of the diff and markdown pages and their path picker (src/viewer-empty).
  viewerEmpty: {
    out: "webviews/src/viewer-empty/generated/strings.json",
    catalogs: [{ file: "webviews/src/viewer-empty/Localizable.xcstrings" }],
  },
};

/** The `{name}` placeholders of a value, as a comparable string. @param {string} value */
const namedTokens = (value) =>
  [...value.matchAll(/\{(\w+)\}/g)]
    .map((match) => match[1])
    .sort()
    .join(",");

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
      else if (namedTokens(value) !== namedTokens(entry.localizations.en.stringUnit.value))
        // Named `{tokens}` (the agent pane) are filled by name; a translation must keep each one.
        errors.push(`${key}: ${locale} changes the {placeholders}`);
      else out[locale][key] = value;
    }
  }
  return { json: `${JSON.stringify(out, null, 2)}\n`, errors };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const check = process.argv.includes("--check");
  let failed = false;
  const only = process.argv.slice(2).filter((arg) => !arg.startsWith("--"));
  for (const [name, page] of Object.entries(PAGES)) {
    if (only.length && !only.includes(name)) continue;
    const { json, errors } = generate(page);
    const target = path.join(repo, page.out);
    if (errors.length) {
      console.error(`${name}: ${errors.length} strings missing\n  ${errors.slice(0, 20).join("\n  ")}`);
      failed = true;
      continue;
    }
    const outputs = new Map([[target, json]]);
    if (page.splitLocales) {
      const tables = JSON.parse(json);
      for (const locale of LOCALES)
        outputs.set(
          path.join(path.dirname(target), "locales", `${locale}.json`),
          `${JSON.stringify(tables[locale], null, 2)}\n`,
        );
      // English is the small eager fallback; only the selected translation is fetched.
      const loaders = LOCALES.filter((locale) => locale !== "en")
        .map(
          (locale) =>
            `  ${/^[a-z]+$/.test(locale) ? locale : JSON.stringify(locale)}: () => import("./locales/${locale}.json"),`,
        )
        .join("\n");
      outputs.set(
        path.join(path.dirname(target), "localeLoaders.ts"),
        `// Generated by scripts/pages/gen-strings.mjs; do not edit.\nexport const diffLocaleLoaders = {\n${loaders}\n};\n`,
      );
    }
    for (const [file, content] of outputs) {
      if (check) {
        const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
        if (current !== content) {
          console.error(`stale: ${path.relative(repo, file)} (run node webviews/scripts/pages/gen-strings.mjs)`);
          failed = true;
        }
      } else {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, content);
      }
    }
  }
  process.exit(failed ? 1 : 0);
}
