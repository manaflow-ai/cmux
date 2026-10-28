#!/usr/bin/env node
// The one string generator for React pages (plans/cmux-next/react-pages.md 1): each page's
// `generated/strings.json` (`{<locale>: {<key>: <value>}}`) comes from xcstrings catalogs, so no
// string lives only in TypeScript. Every locale scripts/cmux-next/check-l10n.sh requires must have
// every key; a missing value fails. Merged with the Settings lead's
// webviews/scripts/settings/generate-strings.mjs (branch feat-cmux-next-settings-react): a page
// lists catalogs and, per catalog, which keys it uses.
// The tables are build output, ignored by git (#21946): install, the test preload and every bundle
// build write them from the checkout's catalogs, so two branches never carry competing copies.
//   node scripts/pages/gen-strings.mjs                # write every page; a missing translation fails
//   node scripts/pages/gen-strings.mjs --best-effort  # write anyway, warn (bun install's postinstall)
//   CMUX_STRINGS_BEST_EFFORT=1 node scripts/pages/gen-strings.mjs  # the same for writes, never for --check
//     (the Mac export jobs, whose bundles only host the export tests: a stale schema must not stop the job
//     that regenerates it; and the gallery host, where a missing translation must not fail a preview)
//   node scripts/pages/gen-strings.mjs --if-stale     # only pages whose inputs are newer (test preload)
//   node scripts/pages/gen-strings.mjs --check        # fail when a written table differs
//   node scripts/pages/gen-strings.mjs settings       # only the named pages
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
    // Read for its keys, so a newer schema makes the table stale.
    inputs: ["schemas/settings/settings-schema.json"],
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
      {
        // Agents > Chiefs (u2586) draws the channels Home's Chief editor (ChiefPage.tsx).
        file: "webviews/src/pages/home-channels/Localizable.xcstrings",
        keys: (all) =>
          all.filter(
            (key) =>
              key.startsWith("chief.") ||
              [
                "sheet.newChief.title",
                "sheet.newChief.lead",
                "sheet.editChief.title",
                "sheet.editChief.lead",
                "edit.cancel",
              ].includes(key),
          ),
      },
      {
        // Machines > Add Device… (add-device-DESIGN.md): the palette action's own title, until the host lists arrive.
        file: `${sources}/CmuxNextActions/RemoteActions.xcstrings`,
        keys: () => ["action.device.add"],
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
  // The Mobile Pairing page shares its table with its Swift provider (`mobilePairing.page.` keys).
  "mobile-pairing": {
    out: "webviews/src/pages/mobile-pairing/generated/strings.json",
    catalogs: [
      {
        file: `${sources}/CmuxNextApp/Resources/MobilePairing.xcstrings`,
        keys: (all) => all.filter((key) => key.startsWith("mobilePairing.page.")),
      },
    ],
  },
  // The Stats page (cmux-page://cmux.stats/, hq#1920); its table lives next to it.
  stats: {
    out: "webviews/src/pages/stats/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/stats/Localizable.xcstrings" }],
  },
  // The Chief Usage page (cmux-page://cmux.chief-usage/); its table lives next to it.
  "chief-usage": {
    out: "webviews/src/pages/chief-usage/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/chief-usage/Localizable.xcstrings" }],
  },
  // The Chief view gallery (cmux-page://cmux.chief-views/); its table lives next to it.
  "chief-views": {
    out: "webviews/src/pages/chief-views/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/chief-views/Localizable.xcstrings" }],
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
              /^(tools|shell|code|image|media|markdown|duration|chip|message\.channel|multiplayer)\./.test(key) ||
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
                // A sent message's line and status (MessageCard.tsx), which Channels draws too.
                "message.sentTo",
                "message.sendingTo",
                "message.sending",
                "message.sent",
                "message.delivered",
                // The recipient chip's tooltip, the full id behind its name (MessageCard.tsx).
                "message.recipientId",
              ].includes(key),
          ),
      },
    ],
  },
  // The changelog's pull request chips draw the agent pane's link hover card (chips/LinkHoverCard.tsx,
  // PullRequestCard.tsx, OpenInMenu.tsx), which read the pane's table; the page installs only these.
  "changelog-pane": {
    out: "webviews/src/pages/changelog/generated/pane-strings.json",
    catalogs: [
      {
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings",
        keys: (all) =>
          all.filter(
            (key) =>
              /^(prCard|header\.prBadge|header\.prReview)\./.test(key) ||
              [
                "chatInspector.changes.failingOnBase",
                "header.prConflicts",
                "header.prNoChecks",
                "image.open",
                "preview.cmuxBrowser",
                "preview.copyLink",
                "preview.openIn",
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

/** Every file `generate(page)` writes, with its content. */
function outputsOf(page, json) {
  const target = path.join(repo, page.out);
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
  return outputs;
}

/** What a page's tables are made from: its catalogs, the settings schema when it reads keys from it, and this script. */
function inputsOf(page) {
  return [
    fileURLToPath(import.meta.url),
    ...[...page.catalogs.map((c) => c.file), ...(page.inputs ?? [])].map((f) => path.join(repo, f)),
  ];
}

const mtime = (file) => {
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return undefined;
  }
};

/**
 * Writes (or with `check`, compares) every page's tables. The tables are build output, ignored by
 * git: a checkout, the tests and every bundle build make them from that tree's catalogs, so no
 * branch carries a copy that a merge can make stale. `bestEffort` still writes a page whose
 * catalogs miss translations (install must not fail on a half-translated branch; the tests and the
 * builds run strict). `ifStale` skips a page whose outputs are all newer than its inputs.
 * Returns the number of failed pages.
 */
export function writeStrings({
  check = false,
  bestEffort = false,
  ifStale = false,
  only = [],
  log = console.error,
} = {}) {
  let failed = 0;
  for (const [name, page] of Object.entries(PAGES)) {
    if (only.length && !only.includes(name)) continue;
    if (ifStale && !check) {
      const target = path.join(repo, page.out);
      const outs = page.splitLocales
        ? [
            target,
            path.join(path.dirname(target), "localeLoaders.ts"),
            ...LOCALES.map((l) => path.join(path.dirname(target), "locales", `${l}.json`)),
          ]
        : [target];
      const oldest = Math.min(...outs.map((f) => mtime(f) ?? -Infinity));
      const newest = Math.max(...inputsOf(page).map((f) => mtime(f) ?? Infinity));
      if (oldest >= newest) continue;
    }
    let generated;
    try {
      generated = generate(page);
    } catch (error) {
      // A catalog or the schema is missing (a sparse checkout): best effort skips the page.
      log(`${name}: ${error.message}`);
      failed++;
      if (bestEffort && !check) continue;
      throw error;
    }
    const { json, errors } = generated;
    if (errors.length) {
      log(`${name}: ${errors.length} strings missing\n  ${errors.slice(0, 20).join("\n  ")}`);
      failed++;
      if (!bestEffort || check) continue;
    }
    for (const [file, content] of outputsOf(page, json)) {
      if (check) {
        const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
        if (current !== content) {
          log(`stale: ${path.relative(repo, file)} (run node webviews/scripts/pages/gen-strings.mjs)`);
          failed++;
        }
      } else if (!fs.existsSync(file) || fs.readFileSync(file, "utf8") !== content) {
        // Write then rename: test processes run the preload in parallel, and another one may be
        // importing this table while it is rewritten.
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const temp = `${file}.${process.pid}.tmp`;
        fs.writeFileSync(temp, content);
        fs.renameSync(temp, file);
      } else {
        // Unchanged content: touch it so `ifStale` sees it as current.
        const now = new Date();
        fs.utimesSync(file, now, now);
      }
    }
  }
  return failed;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const check = process.argv.includes("--check");
  const bestEffort = process.argv.includes("--best-effort") || (!check && process.env.CMUX_STRINGS_BEST_EFFORT === "1");
  const failed = writeStrings({
    check,
    bestEffort,
    ifStale: process.argv.includes("--if-stale"),
    only: process.argv.slice(2).filter((arg) => !arg.startsWith("--")),
  });
  process.exit(failed && !bestEffort ? 1 : 0);
}
