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

/** Every key a settings schema export names (titles, help, summaries, groups, default labels, choices, page layout). */
export function schemaKeys(schemaFile) {
  const schema = readJSON(schemaFile);
  const keys = new Set();
  for (const section of schema.sections ?? []) if (section.title?.key) keys.add(section.title.key);
  for (const category of schema.page?.categories ?? []) {
    if (category.title?.key) keys.add(category.title.key);
    for (const group of category.groups ?? []) if (group.title?.key) keys.add(group.title.key);
  }
  for (const row of schema.rows ?? []) {
    for (const field of ["title", "help", "summary", "group", "default_label"])
      if (row[field]?.key) keys.add(row[field].key);
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
    catalogs: [
      { file: "webviews/src/pages/diff/Localizable.xcstrings" },
      // The changes view's Stage, Commit and Push, which the viewer reuses (cx-ueuc8, diff-viewer/git.ts).
      {
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings",
        keys: (all) =>
          all.filter(
            (key) =>
              key.startsWith("git.") ||
              ["changes.stageFile", "changes.unstageFile", "changes.stageFailed"].includes(key),
          ),
      },
    ],
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
        // A profile's Clear Browsing Data form (cx-d0d.23): the action's title and kinds.
        keys: (all) =>
          all.filter(
            (key) =>
              key.startsWith("argument.browsingData.") ||
              ["action.browserProfile.manageExtensions", "action.browserProfile.clearBrowsingData"].includes(key),
          ),
      },
      {
        // Its time ranges are Clear History's.
        file: `${sources}/CmuxNextActions/HistoryActions.xcstrings`,
        keys: (all) => all.filter((key) => key.startsWith("argument.history.range.")),
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
  // Debug Settings shares the `debugSettings.` keys (and Reset) with the Swift window it replaces.
  "debug-settings": {
    out: "webviews/src/pages/debug-settings/generated/strings.json",
    catalogs: [
      {
        file: `${sources}/CmuxNextSettingsWindow/Localizable.xcstrings`,
        keys: (all) => all.filter((key) => key.startsWith("debugSettings.") || key === "settingsWindow.reset"),
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
  // The Files page (cmux-page://cmux.files/, cx-p4rt); its table lives next to it.
  files: {
    out: "webviews/src/pages/files/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/files/Localizable.xcstrings" }],
  },
  // The Stats page (cmux-page://cmux.stats/, hq#1920); its table lives next to it.
  stats: {
    out: "webviews/src/pages/stats/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/stats/Localizable.xcstrings" }],
  },
  // The CodeRouter page (cmux-page://cmux.coderouter/) has no Swift page; its table lives next to it.
  coderouter: {
    out: "webviews/src/pages/coderouter/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/coderouter/Localizable.xcstrings" }],
  },
  // The channels Home (cmux-page://cmux.home-channels/) has no Swift page; its table lives next to it.
  "home-channels": {
    out: "webviews/src/pages/home-channels/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/home-channels/Localizable.xcstrings" }],
  },
  // The agent pane's rows the channels Home reuses for agent runs (tool calls, shell blocks,
  // diffs, Markdown): only their keys, installed as the pane's table (agent-session/acpmux/i18n.ts).
  "home-channels-pane": {
    out: "webviews/src/pages/home-channels/generated/pane-strings.json",
    catalogs: [
      {
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings",
        keys: (all) =>
          all.filter(
            (key) =>
              /^(tools|shell|code|image|media|markdown|duration|chip)\./.test(key) ||
              [
                "changes.noLineChanges",
                "link.openPath",
                "turn.copy",
                "turn.copied",
                "message.label",
                "message.less",
                "message.more",
                "message.noText",
                "message.self",
                "message.unknown",
              ].includes(key),
          ),
      },
    ],
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

/** CLDR's plural categories. A plural string is `key#<category>` for each, in every locale. */
const PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"];

/**
 * A catalog entry's text in `locale`: its string, or for a plural entry (`variations.plural`, as
 * Xcode writes it) its text per category. A category the locale's rules never pick takes the
 * locale's `other`, so every locale's table has the same keys; one they pick must be translated.
 */
function localized(entry, locale) {
  const localization = entry?.localizations?.[locale];
  const plural = localization?.variations?.plural;
  if (!plural) return localization?.stringUnit?.value;
  const forms = Object.fromEntries(
    Object.entries(plural).map(([category, form]) => [category, form?.stringUnit?.value]),
  );
  const used = new Intl.PluralRules(locale).resolvedOptions().pluralCategories;
  if (used.some((category) => typeof forms[category] !== "string" || forms[category].trim() === "")) return undefined;
  return Object.fromEntries(PLURAL_CATEGORIES.map((category) => [category, forms[category] ?? forms.other]));
}

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
      const value = localized(entry, locale);
      const english = localized(entry, "en");
      const englishTokens = namedTokens(typeof english === "object" ? english.other : (english ?? ""));
      if (value === undefined || (typeof value === "string" && value.trim() === ""))
        errors.push(`${key}: missing ${locale}`);
      else if (typeof value === "string") {
        if (namedTokens(value) !== englishTokens)
          // Named `{tokens}` (the agent pane) are filled by name; a translation must keep each one.
          errors.push(`${key}: ${locale} changes the {placeholders}`);
        else out[locale][key] = value;
      } else if (Object.values(value).some((form) => namedTokens(form) !== englishTokens))
        errors.push(`${key}: ${locale} changes the {placeholders}`);
      else for (const category of PLURAL_CATEGORIES) out[locale][`${key}#${category}`] = value[category];
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
