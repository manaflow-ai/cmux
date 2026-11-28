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
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { catalogFiles, readCatalog } from "./catalog.mjs";

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

/** The pane connect card's own words outside `connect.` (acpmux/ConnectCard.tsx), for pages that draw it. */
const CONNECT_CARD_KEYS = [
  "picker.tryAgain",
  "picker.connectClaude.refused",
  "picker.connectClaude.failed",
  "picker.connectClaude.connected",
  "picker.connectClaude.invalid",
  "picker.setup.cancel",
  "harness.notNow",
  "cloudSetup.steps.progress",
  "cloudSetup.chatgpt",
  "turn.signIn.save",
  "turn.signIn.keyLabel",
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
export const PAGES = {
  // The onboarding tool window (Agents, Import from Browsers, Computer Use): the page's own table,
  // its keys and translations the Swift steps' (CmuxNextOnboarding) it replaces.
  onboarding: {
    out: "webviews/src/pages/onboarding/generated/strings.json",
    catalogs: [
      { file: "webviews/src/pages/onboarding/Localizable.xcstrings" },
      // The provider readiness rows' sign-in (logins done right): the shared sign-in card's keys.
      { file: "webviews/src/pages/shared/signIn/Localizable.xcstrings" },
    ],
  },
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
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
        keys: (all) =>
          all.filter(
            (key) =>
              key.startsWith("git.") ||
              [
                "changes.stageFile",
                "changes.unstageFile",
                "changes.stageFailed",
                "changes.createPullRequest",
                "changes.pullRequestFailed",
              ].includes(key),
          ),
      },
    ],
  },
  // The sentences every page shows for a failure it has no sentence of its own for
  // (pages/shared/userMessage.ts): never the error's own text.
  pageErrors: {
    out: "webviews/src/pages/shared/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/shared/Localizable.xcstrings" }],
  },
  // The device sign-in card and account list (Settings > Accounts, onboarding): their own table.
  connect: {
    out: "webviews/src/pages/shared/connect/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/shared/connect/Localizable.xcstrings" }],
  },
  signIn: {
    out: "webviews/src/pages/shared/signIn/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/shared/signIn/Localizable.xcstrings" }],
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
        file: `${sources}/CmuxNextSettings/Localizable.xcstrings.d`,
        keys: () => schemaKeys("schemas/settings/settings-schema.json"),
      },
      {
        file: `${sources}/CmuxNextSettingsWindow/Localizable.xcstrings.d`,
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
        file: `${sources}/CmuxNextActions/RemoteActions.xcstrings`,
        keys: () => ["action.remote.newGroup"],
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
      // Settings > Accounts' device sign-in and account list (logins done right).
      { file: "webviews/src/pages/shared/signIn/Localizable.xcstrings" },
      {
        // Connect Claude's one click and its progress line, the chat's connect card's own words.
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
        keys: (all) => all.filter((key) => key.startsWith("connect.")),
      },
      // Settings > Integrations > Connections: the shared connect card and All connections.
      { file: "webviews/src/pages/shared/connect/Localizable.xcstrings" },
      {
        // Settings > Accounts' GitHub CLI fallback, for hosts that predate the localized state fields.
        file: `${sources}/CmuxNextAccounts/Resources/GitHubConnection.xcstrings`,
        keys: (all) => all.filter((key) => ["github.cliSignIn", "github.cliSignInDetail"].includes(key)),
      },
    ],
  },
  history: {
    out: "webviews/src/pages/history/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/history/Localizable.xcstrings" }],
  },
  terminalHistory: {
    out: "webviews/src/pages/terminal-history/generated/strings.json",
    catalogs: [
      { file: "webviews/src/pages/terminal-history/Localizable.xcstrings" },
      {
        file: `${sources}/CmuxNextApp/Resources/Localizable.xcstrings`,
        keys: () => ["terminalHistory.tab"],
      },
      {
        file: `${sources}/CmuxNextAgentPane/Resources/Localizable.xcstrings`,
        keys: () => ["terminalHistory.unavailable"],
      },
      {
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
        keys: () => [
          "files.searching",
          "find.next",
          "find.noResults",
          "find.placeholder",
          "find.previous",
          "inbox.earlier",
          "ledger.total.tools",
          "message.more",
          "subagents.empty.title",
          "transcript.agent",
          "transcript.jumpLatest",
          "transcript.loading",
          "transcript.loadingOlder",
          "transcript.you",
        ],
      },
    ],
  },
  stash: {
    out: "webviews/src/pages/stash/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/stash/Localizable.xcstrings" }],
  },
  // The Forum page (the team's hosted agent forum; behind experiments.forum).
  forum: {
    out: "webviews/src/pages/forum/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/forum/Localizable.xcstrings" }],
  },
  // The Feed page (plans/cmux-next/feed-page.md): its table moved next to it when the Swift Feed
  // module was deleted (the same keys and values), with the refusal toast's `toast.dismiss`.
  feed: {
    out: "webviews/src/pages/feed/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/feed/Localizable.xcstrings" }],
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
        file: `${sources}/CmuxNextSettingsWindow/Localizable.xcstrings.d`,
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
  // The Bookmarks page shares its table with the Swift bar, bubble and manager.
  bookmarks: {
    out: "webviews/src/pages/bookmarks/generated/strings.json",
    catalogs: [{ file: `${sources}/CmuxNextBookmarks/Resources/Localizable.xcstrings` }],
  },
  // The sidebar's chat history blocks (CmuxNextSidebar SidebarChatHistoryHost): the sidebar's own keys.
  "sidebar-chats": {
    out: "webviews/src/pages/sidebar-chats/generated/strings.json",
    catalogs: [
      {
        file: `${sources}/CmuxNextSidebar/Resources/Localizable.xcstrings`,
        keys: () => [
          "sidebar.section.pinned",
          "sidebar.chatHistory.earlier",
          "sidebar.chatHistory.showMore",
          "sidebar.chatHistory.loading",
        ],
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
  // The Cloud progress page (cmux-page://cmux.cloud-progress/): a Cloud machine on its way to its terminal.
  // Its table lives next to it; the words are the retired AppKit view's (Cloud.xcstrings `cloud.progress.`).
  "cloud-progress": {
    out: "webviews/src/pages/cloud-progress/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/cloud-progress/Localizable.xcstrings" }],
  },
  // The server page (cmux-page://cmux.server-cards/): the menu bar popover's routes. Every card (Add Server, Pair
  // Another Machine, Add Machine, app health) is native (AddServerDialog, PairInviteDialog, AddMachineDialog).
  "server-cards": {
    out: "webviews/src/pages/server-cards/generated/strings.json",
    catalogs: [
      // The server surfaces' own table (the menu bar panel, Health, pairing); the app's refusals (`refusal.*`) and
      // Add Server's words (`approver.*`) stay native.
      {
        file: `${sources}/CmuxNextServer/Resources/Localizable.xcstrings`,
        keys: (all) => all.filter((key) => !key.startsWith("refusal.") && !key.startsWith("approver.")),
      },
    ],
  },
  // The Artifacts page (cmux-page://cmux.artifacts/); its table lives next to it.
  artifacts: {
    out: "webviews/src/pages/artifacts/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/artifacts/Localizable.xcstrings" }],
  },
  // The Stats page (cmux-page://cmux.stats/, hq#1920); its table lives next to it.
  stats: {
    out: "webviews/src/pages/stats/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/stats/Localizable.xcstrings" }],
  },
  // The GitHub page (cmux-page://cmux.github/); its table lives next to it.
  github: {
    out: "webviews/src/pages/github/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/github/Localizable.xcstrings" }],
  },
  // The Task Manager page (cmux-page://cmux.task-manager/): its own words next to it (the columns,
  // the empty list, the total, moved from the SwiftUI table it replaced), and the tab title and Kill
  // Process, which the Swift kill question says too, from CmuxNextResources' catalog.
  "task-manager": {
    out: "webviews/src/pages/task-manager/generated/strings.json",
    catalogs: [
      { file: "webviews/src/pages/task-manager/Localizable.xcstrings" },
      {
        file: `${sources}/CmuxNextResources/Resources/Localizable.xcstrings`,
        keys: () => ["taskManager.title", "taskManager.kill.button"],
      },
    ],
  },
  // The Tasks page (cmux-page://cmux.tasks/); its table lives next to it (the Swift pane is gone).
  tasks: {
    out: "webviews/src/pages/tasks/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/tasks/Localizable.xcstrings" }],
  },
  // The browser's Page Info windows (site settings, site data, the certificate viewer); their table
  // lives next to their components in webviews/src/browser-chrome/page-info.
  "browser-chrome-page-info": {
    out: "webviews/src/browser-chrome/page-info/generated/strings.json",
    catalogs: [{ file: "webviews/src/browser-chrome/page-info/Localizable.xcstrings" }],
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
  // The channels Home (cmux-page://cmux.home-channels/) has no Swift page; its table lives next to it.
  "home-channels": {
    out: "webviews/src/pages/home-channels/generated/strings.json",
    catalogs: [
      { file: "webviews/src/pages/home-channels/Localizable.xcstrings" },
      { file: "webviews/src/pages/home-channels/transcript/Localizable.xcstrings.d" },
    ],
  },
  // Home's Set Up cmux card (setup-card), with the Swift keys it replaces; its table lives next to it.
  "setup-card": {
    out: "webviews/src/pages/setup-card/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/setup-card/Localizable.xcstrings" }],
  },
  // The agent pane's rows the channels Home reuses for agent runs (tool calls, shell blocks,
  // diffs, Markdown): only their keys, installed as the pane's table (agent-session/acpmux/i18n.ts).
  "home-channels-pane": {
    out: "webviews/src/pages/home-channels/generated/pane-strings.json",
    catalogs: [
      {
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
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
                "message.deliveredShort",
                "message.queued",
                "message.notDelivered",
                "message.notDeliveredStopped",
                "message.notDeliveredNoAgent",
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
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
        keys: (all) =>
          all.filter(
            (key) =>
              /^(prCard|header\.prBadge|header\.prReview)\./.test(key) ||
              [
                "sessionInfo.changes.failingOnBase",
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
  // Settings > Agents > Harnesses draws the agent pane's plan usage card under each account
  // (ProviderAccounts.tsx, acpmux/PlanUsageCard.tsx), which reads the pane's table; the page installs
  // only its `planUsage.` keys (settings/paneStrings.ts). Without them the shipped page showed the
  // raw keys (planUsage.window.session) in every account's usage. Settings > Integrations >
  // Connections draws each app as the pane's connect card (acpmux/ConnectCard.tsx), so the page also
  // installs that card's own words (CONNECT_CARD_KEYS).
  "settings-pane": {
    out: "webviews/src/pages/settings/generated/pane-strings.json",
    catalogs: [
      {
        file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
        keys: (all) =>
          all.filter(
            (key) => key.startsWith("planUsage.") || key.startsWith("connect.") || CONNECT_CARD_KEYS.includes(key),
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
    catalogs: [
      { file: "webviews/src/agent-session/acpmux/Localizable.xcstrings.d" },
      // An app section's failure row (apps/scene/SceneFailure.tsx) says what the native
      // AppFailureNSView says: the app platform's own `apps.failure.` and Reload keys.
      {
        file: `${sources}/CmuxNextApps/Resources/Localizable.xcstrings`,
        keys: (all) =>
          all.filter(
            (key) => key.startsWith("apps.failure.") || key === "apps.mount.reload" || key === "apps.mount.reload.help",
          ),
      },
    ],
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
    const strings = readCatalog(path.join(repo, catalog.file)).strings;
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
    ...page.catalogs.flatMap((c) => catalogFiles(path.join(repo, c.file))),
    ...(page.inputs ?? []).map((f) => path.join(repo, f)),
  ];
}

/** The newest modification time of `page`'s inputs; Infinity when one is missing. */
const newestInput = (page) => Math.max(...inputsOf(page).map((f) => mtime(f) ?? Infinity));

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
 * `ifUnchanged` skips a page whose stamp (stampFile) says its outputs on disk are the ones this
 * script made from these exact inputs, by content, not by time: a restored output cache can leave
 * an old table newer than its inputs, which `ifStale` would keep.
 * Returns the number of failed pages.
 */
export function writeStrings({
  check = false,
  bestEffort = false,
  ifStale = false,
  ifUnchanged = false,
  only = [],
  log = console.error,
} = {}) {
  let failed = 0;
  for (const [name, page] of Object.entries(PAGES)) {
    if (only.length && !only.includes(name)) continue;
    if (ifUnchanged && !check && stampCurrent(name, page)) continue;
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
      if (oldest >= newestInput(page)) continue;
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
    const outputs = outputsOf(page, json);
    for (const [file, content] of outputs) {
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
      } else if ((mtime(file) ?? -Infinity) < newestInput(page)) {
        // Unchanged content older than its inputs: touch it so `ifStale` sees it as current. Never
        // touch a table that is already current: test/preload.ts rewrites the agent pane's table in
        // every `bun test` process, and each touch is a change to the dev servers that watch it,
        // which full-reload every agent pane page open in a browser test running beside it.
        const now = new Date();
        fs.utimesSync(file, now, now);
      }
    }
    if (!check) writeStamp(name, page, outputs);
  }
  return failed;
}

/**
 * Where writeStrings records what a page's outputs were made from: webviews/node_modules/.cache,
 * outside src/ so no dev server watches it. No node_modules (before an install): no stamp, and
 * `ifUnchanged` writes the page as before.
 */
const stampFile = (name) => path.join(webviews, "node_modules", ".cache", "gen-strings", `${name}.json`);

/** sha256 over each file's path and bytes; null when one is missing. */
function digest(files, read = (file) => fs.readFileSync(file)) {
  const hash = crypto.createHash("sha256");
  try {
    for (const file of files)
      hash
        .update(`${path.relative(repo, file)}\0`)
        .update(read(file))
        .update("\0");
  } catch {
    return null;
  }
  return hash.digest("hex");
}

/** Whether `page`'s stamp names these inputs and the outputs now on disk. */
function stampCurrent(name, page) {
  let stamp;
  try {
    stamp = JSON.parse(fs.readFileSync(stampFile(name), "utf8"));
  } catch {
    return false;
  }
  if (!stamp?.inputs || !Array.isArray(stamp.outputs) || stamp.inputs !== digest(inputsOf(page))) return false;
  const outputs = digest(stamp.outputs.map((file) => path.join(repo, file)));
  return outputs !== null && outputs === stamp.digest;
}

/** Records that `outputs` (file -> content, now on disk) are what this script makes from `page`'s inputs. */
function writeStamp(name, page, outputs) {
  if (!fs.existsSync(path.join(webviews, "node_modules"))) return;
  const inputs = digest(inputsOf(page));
  if (!inputs) return;
  const files = [...outputs.keys()];
  const stamp = {
    inputs,
    outputs: files.map((file) => path.relative(repo, file)),
    digest: digest(files, (file) => outputs.get(file)),
  };
  // Written then renamed, as the tables are: test processes run the preload in parallel.
  try {
    const file = stampFile(name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const temp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temp, `${JSON.stringify(stamp)}\n`);
    fs.renameSync(temp, file);
  } catch {}
}

/** Writes the pane and acpmux protocol types; true when a generator failed. */
async function writeProtocols() {
  const scripts = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
  if (process.versions.bun) {
    const { writePaneProtocol } = await import("../pane-protocol-codegen.ts");
    const { writeAcpmuxProtocol } = await import("../acpmux-protocol-codegen.ts");
    writePaneProtocol({ log: () => {} });
    writeAcpmuxProtocol({ log: () => {} });
    return false;
  }
  const { spawnSync } = await import("node:child_process");
  let failed = false;
  for (const script of ["pane-protocol-codegen.ts", "acpmux-protocol-codegen.ts"]) {
    const run = spawnSync("bun", [path.join(scripts, script)], { stdio: ["ignore", "ignore", "inherit"] });
    if (run.error?.code === "ENOENT") return false;
    failed ||= run.status !== 0;
  }
  return failed;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const check = process.argv.includes("--check");
  // The feature tips table is build output beside the strings tables, made by every run that makes
  // them (install, the webview and bundle builds, the gallery; gen-feature-tips.mjs).
  const { writeFeatureTips } = await import("./gen-feature-tips.mjs");
  const tipsFailed = writeFeatureTips({ check });
  // The design scale's Tailwind theme and token list are build output too (gen-design-scale.mjs).
  const { writeDesignScale } = await import("./gen-design-scale.mjs");
  const scaleFailed = writeDesignScale({ check, log: () => {} });
  // The pane and acpmux protocol types are build output too (pane-protocol-codegen.ts,
  // acpmux-protocol-codegen.ts), written only where they changed. Bun imports them; under node
  // (their imports carry no extension) bun runs them, skipped when no bun is installed.
  const protocolFailed = check ? false : await writeProtocols();
  const bestEffort = process.argv.includes("--best-effort") || (!check && process.env.CMUX_STRINGS_BEST_EFFORT === "1");
  const failed = writeStrings({
    check,
    bestEffort,
    ifStale: process.argv.includes("--if-stale"),
    only: process.argv.slice(2).filter((arg) => !arg.startsWith("--")),
  });
  process.exit((failed && !bestEffort) || tipsFailed || scaleFailed || protocolFailed ? 1 : 0);
}
