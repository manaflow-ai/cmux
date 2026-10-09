// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { AccountsRow, AccountsState, HostLists } from "./ops";
import { categories, homes } from "./categories";
import { schema } from "./schema";

const button = (id: string, title: string, disabled = false) => ({
  id,
  title,
  disabled,
  help: null,
  destructive: false,
});
const account: AccountsRow = {
  provider: "codex",
  name: "Codex",
  detail: "Sample local account",
  status: "Signed in",
  statusKind: "success",
  busy: false,
  buttons: [button("reauth", "Re-authenticate"), button("connect", "Connect to CodeRouter")],
  linked: [{ id: "sample-account", label: "Sample research account", state: "Healthy", healthy: true, busy: false }],
  note: null,
  outcome: null,
  confirm: null,
  paste: null,
};
const accounts = (patch: Partial<AccountsRow> = {}, state: Partial<AccountsState> = {}): AccountsState => ({
  refresh: "Refresh",
  refreshing: false,
  signIn: null,
  removeTitle: "Remove from CodeRouter",
  groups: [{ id: "sample", title: "Sample providers", rows: [{ ...account, ...patch }] }],
  ...state,
});
const host: Partial<HostLists> = {
  machines: [{ id: "sample-build", title: "Research build machine", subtitle: "Online · local network", active: true }],
  settings_file: "/Users/sample/.config/cmux/cmux.json",
  // Most variants omit artwork; the backdrop variant supplies sample thumbnails.
  backdrops: [],
};
const click = (selector: string): PageFixtureStep => ({ selector, action: "click" });
const input = (selector: string, value: string): PageFixtureStep => ({ selector, action: "input", value });
const wait = (selector: string): PageFixtureStep => ({ selector, action: "wait" });
const row = (key: string) => `[data-row-key="${key}"]`;
const focusComputerUse: PageFixtureStep = {
  selector: '[data-card="computer-use"] [data-action="palette.computerUse.accessibility"]',
  action: "focus",
};
const customValues: Record<string, unknown> = Object.fromEntries(
  schema.rows.map((setting) => {
    let value: unknown = setting.default;
    if (setting.kind === "toggle") value = !setting.default;
    else if (setting.kind === "choice")
      value = setting.choices?.find((choice) => choice.value !== setting.default)?.value ?? setting.default;
    else if (setting.kind === "number") value = setting.range?.placeholder ?? setting.default;
    else if (setting.kind === "color") value = "#A08060";
    else if (setting.kind === "theme") value = "Dracula";
    else if (setting.kind === "font_family") value = "Menlo";
    else if (setting.kind === "sound") value = "Glass";
    else if (setting.kind === "choice_or_number") value = 45;
    else if (setting.kind === "host_list") value = ["docs.example.test", "*.research.example.test"];
    else if (setting.kind === "folder_list")
      // Chat roots take absolute paths only (validate.ts); the other folder lists also take ~/.
      value =
        setting.key === "agents.chats.roots"
          ? ["/Users/sample/Projects/Atlas", "/Users/sample/Projects/Research with a long folder name"]
          : ["~/Projects/Atlas", "~/Projects/Research with a long folder name"];
    else if (setting.kind === "time_range") value = { start: "22:00", end: "07:30" };
    else if (setting.kind === "url")
      value =
        setting.validation === "domain:search_template"
          ? "https://search.example.test/?q=%s"
          : "https://start.example.test/";
    return [setting.key, value];
  }),
);
const variant = (section: string, extra: Omit<SettingsPageVariant, "section"> = {}): SettingsPageVariant => ({
  section,
  host,
  accounts: accounts(),
  ...extra,
});
const variants: Record<string, SettingsPageVariant> = {};
for (const category of categories) {
  const allThemes = category.id === "theme";
  variants[category.id] = variant(category.id, { allThemes });
  variants[`${category.id}-customized`] = variant(category.id, { allThemes, options: { values: customValues } });
  // Every group gets a scroll/focus target, including controls below the initial viewport.
  for (const [index, group] of category.groups.entries())
    variants[`${category.id}-group-${index + 1}`] = variant(category.id, {
      focus: group.rows[0]!.key,
      options: { values: customValues },
      note: `${group.title.text}: customized controls, focused and scrolled into view.`,
    });
}
const longRows = Array.from({ length: 48 }, (_, i) => ({
  id: `sample-${i}`,
  title: `Research environment ${i + 1} with a long descriptive name`,
  subtitle: "Sample project · development environment",
  active: i === 0,
}));
const longProfiles = longRows.map((r, i) => ({
  id: r.id,
  name: r.title,
  color: "green",
  icon: "🌱",
  is_default: i === 0,
  source: "Imported sample browser profile",
}));
Object.assign(variants, {
  backdrops: variant("experimental", {
    options: { values: { "appearance.experimentalControls": true, "appearance.background": "starryNight" } },
    host: {
      ...host,
      backdrops: [{ id: "starryNight", title: "Sample night", attribution: "Gallery sample thumbnail" }],
    },
    backdropImages: {
      starryNight:
        "data:image/svg+xml," +
        encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="#253445"/><circle cx="235" cy="45" r="20" fill="#dfcf91"/><path d="M0 140L80 70L190 150L260 100L320 135V180H0Z" fill="#456253"/></svg>',
        ),
    },
    steps: [
      wait('[data-card="backdrop"]'),
      { selector: '[data-card="backdrop"] button[aria-pressed="true"]', action: "focus" },
    ],
    note: "The real wallpaper picker with a public-safe sample thumbnail.",
  }),
  "terminal-shell-unknown": variant("terminal", {
    host: { ...host, terminal: { ghostty_config: "~/.config/ghostty/config", shell_integration: null } },
  }),
  loading: variant("general", {
    loading: true,
    note: "Before the first settings reply; default controls are disabled.",
  }),
  "read-only": variant("browser", { options: { connected: false } }),
  "permission-error": variant("general", {
    options: { failing: { "cmux.settings.list": "cmux.settings.permission_denied" } },
  }),
  "not-found": variant("general", { options: { failing: { "cmux.settings.snapshot": "cmux.settings.not_found" } } }),
  "managed-controls": variant("browser", { focus: "browser.remoteLocalhost" }),
  "empty-rooms": variant("rooms", { host: { ...host, rooms: [], browser_profiles: [] } }),
  "unsupported-rooms": variant("rooms", { host: { ...host, rooms: null } }),
  "empty-machines": variant("machines", { host: { ...host, machines: [] } }),
  "long-rooms": variant("rooms", { host: { ...host, rooms: longRows, browser_profiles: longProfiles } }),
  "long-profiles": variant("browser", { host: { ...host, rooms: [], browser_profiles: longProfiles } }),
  "long-machines": variant("machines", { host: { ...host, machines: longRows } }),
  "profile-editor": variant("browser", {
    steps: [
      click('[data-profile="p-work"] .host-toggle'),
      wait(".host-form"),
      { selector: ".host-form input", action: "select" },
    ],
  }),
  "search-results": variant("general", { steps: [input("[data-settings-search]", "browser")] }),
  "search-results-font": variant("general", { steps: [input("[data-settings-search]", "font")] }),
  "search-empty": variant("general", { steps: [input("[data-settings-search]", "no-such-setting")] }),
  "reset-confirmation": variant("advanced", { steps: [click("[data-reset-all]"), wait("[data-confirm-reset-all]")] }),
  "theme-picker": variant("theme", {
    allThemes: true,
    steps: [click("[data-theme-picker]"), wait(".theme-popover [data-theme-option]")],
    note: "The theme popover over every bundled theme.",
  }),
  "theme-picker-search": variant("theme", {
    allThemes: true,
    steps: [click("[data-theme-picker]"), input(".theme-popover input", "solarized"), wait("[data-theme-option]")],
  }),
  "theme-picker-empty": variant("theme", {
    allThemes: true,
    steps: [click("[data-theme-picker]"), input(".theme-popover input", "no-such-theme")],
  }),
  "theme-light-dark": variant("theme", {
    allThemes: true,
    options: { values: { "appearance.theme": "light:Catppuccin Latte,dark:Catppuccin Mocha" } },
    note: "Match System Appearance: a light and a dark theme.",
  }),
  "theme-overrides": variant("theme", {
    allThemes: true,
    options: { values: { "appearance.theme": "Nord" } },
    host: {
      ...host,
      theme: {
        levels: ["room", "workspace", "terminal"],
        current: { room: null, workspace: "Tokyo Night", terminal: "Gruvbox Dark" },
      },
    },
    note: "Scope overrides inline on the setting (P4): no space, workspace or terminal tabs.",
  }),
  "theme-app-separate": variant("theme", {
    allThemes: true,
    options: { values: { "appearance.theme": "Gruvbox Dark", "appearance.appTheme": "Rose Pine" } },
    note: "An app theme apart from the terminal theme (appearance.appTheme).",
  }),
  "theme-managed": variant("theme", {
    allThemes: true,
    options: {
      managed: {
        "appearance.theme": {
          value: "GitHub Light Default",
          source: "profile",
          reason: "Set by your organization",
          team: "Acme",
        },
      },
    },
    note: "An MDM lock inline on the setting.",
  }),
  "changed-only": variant("general", {
    options: { values: customValues },
    steps: [click("[data-changed-only]"), wait("[data-search-results]")],
    note: "Show Only Changed lists every changed setting across categories.",
  }),
  "font-picker": variant("appearance", {
    steps: [click(`${row("terminal.fontFamily")} .domain-button`), wait(".domain-panel")],
  }),
  "domains-unavailable": variant("appearance", { options: { domains: null } }),
  "theme-text-fallback": variant("theme", { options: { domains: null } }),
  "invalid-search-template": variant("browser", {
    focus: "browser.customSearchEngine.search",
    options: { values: { "browser.customSearchEngine.search": "https://search.example.test/" } },
  }),
  "invalid-color": variant("appearance", {
    focus: "focusRing.color",
    steps: [
      input(`${row("focusRing.color")} .hex`, "not-a-color"),
      { selector: `${row("focusRing.color")} .hex`, action: "enter" },
      wait(`${row("focusRing.color")} [role="alert"]`),
    ],
  }),
  "invalid-host": variant("browser", {
    focus: "browser.hibernationExclusions",
    steps: [
      input(".token-input", "bad host / path"),
      { selector: ".token-input", action: "enter" },
      wait(".host-list [role=alert]"),
    ],
  }),
  "write-error": variant("privacy", {
    options: { failing: { "cmux.settings.set": "cmux.settings.permission_denied" } },
    steps: [
      click(`${row("history.terminalCommands")} button:not(:disabled)`),
      wait(`${row("history.terminalCommands")} [role=alert]`),
    ],
  }),
  "configuration-errors": variant("advanced", {
    options: {
      diagnostics: [
        { path: "browser.newTabPage", message: "The address must use an allowed scheme." },
        { path: "unknown.option", message: "Unknown configuration option." },
      ],
    },
  }),
  "row-diagnostic": variant("browser", {
    focus: "browser.newTabPage",
    options: { diagnostics: [{ path: "browser.newTabPage", message: "The address must use an allowed scheme." }] },
  }),
  "ghostty-diagnostics": variant("terminal", {
    host: {
      ...host,
      ghostty_diagnostics: [
        {
          kind: "key",
          name: "font-size",
          file: "~/.config/ghostty/config",
          line: 4,
          reason: "superseded",
          replacement: "terminal.fontSize",
        },
        {
          kind: "keybind-action",
          name: "new_window",
          file: "~/.config/ghostty/config",
          line: 8,
          reason: "not-applicable",
          replacement: null,
        },
        { kind: "invalid", name: "unknown setting", file: null, line: null, reason: null, replacement: null },
      ],
    },
  }),
  // Agents > Computer Use Setup (ComputerUseCard): off (grants unknown), every grant given, none.
  // Focusing the card's first button scrolls it into view.
  "computer-use-off": variant("agents", {
    host: { ...host, computer_use: { phase: "off", accessibility: null, screen_recording: null, helper: null } },
    steps: [wait('[data-card="computer-use"]'), focusComputerUse],
    note: "Computer Use off: both grants Unknown, the card says to turn it on.",
  }),
  "computer-use-granted": variant("agents", {
    host: {
      ...host,
      computer_use: { phase: "ready", accessibility: true, screen_recording: true, helper: "cmux Computer Use" },
    },
    steps: [wait('[data-card="computer-use"] [data-granted="true"]'), focusComputerUse],
    note: "Computer Use ready: Accessibility and Screen Recording both allowed.",
  }),
  "computer-use-not-granted": variant("agents", {
    host: {
      ...host,
      computer_use: { phase: "ready", accessibility: false, screen_recording: false, helper: "cmux Computer Use" },
    },
    steps: [wait('[data-card="computer-use"] [data-granted="false"]'), focusComputerUse],
    note: "Computer Use ready but neither grant given: both rows say Not Allowed.",
  }),
  "accounts-empty": variant("accounts", { accounts: accounts({}, { groups: [], signIn: "Sign in to cmux" }) }),
  "accounts-refreshing": variant("accounts", {
    accounts: accounts(
      { busy: true, status: "Refreshing", statusKind: "neutral", buttons: [button("reauth", "Re-authenticate", true)] },
      { refreshing: true },
    ),
  }),
  "accounts-error": variant("accounts", {
    accounts: accounts({
      status: "Connection failed",
      statusKind: "attention",
      note: "Reconnect to try again.",
      outcome: { kind: "danger", text: "The account service is unavailable." },
      linked: [{ id: "sample-account", label: "Sample account", state: "Expired", healthy: false, busy: false }],
    }),
  }),
  "accounts-confirmation": variant("accounts", {
    accounts: accounts({
      confirm: { text: "Connect this sample account to CodeRouter?", confirm: "Connect", cancel: "Cancel" },
    }),
  }),
  "accounts-paste": variant("accounts", {
    accounts: accounts({
      paste: {
        title: "Add a key",
        body: "Paste a key to continue.",
        placeholder: "Paste here",
        buttons: [button("saveKeychain", "Save to Keychain"), button("cancelPaste", "Cancel")],
      },
    }),
    note: "Empty credential form; fixtures never contain credentials.",
  }),
  "accounts-success": variant("accounts", {
    accounts: accounts({ outcome: { kind: "success", text: "Account connected." } }),
  }),
  "accounts-long": variant("accounts", {
    accounts: accounts(
      {},
      {
        groups: [
          {
            id: "many",
            title: "Sample providers",
            rows: Array.from({ length: 30 }, (_, i) => ({
              ...account,
              provider: `sample-${i}`,
              name: `Sample provider ${i + 1} with a long account label`,
            })),
          },
        ],
      },
    ),
  }),
} satisfies Record<string, SettingsPageVariant>);

// The two overall looks for the chief's pick (layout.css): each on the Theme section with every
// bundled theme, on General, and on Show Only Changed. Light and dark come from the gallery theme.
for (const look of ["quiet", "dense"] as const) {
  variants[`look-${look}-theme`] = variant("theme", { look, allThemes: true, note: `${look} look: Theme.` });
  variants[`look-${look}-general`] = variant("general", { look, note: `${look} look: General.` });
  variants[`look-${look}-browser`] = variant("browser", {
    look,
    options: { values: customValues },
    note: `${look} look: Browser, customized, with an MDM lock.`,
  });
  variants[`look-${look}-changed`] = variant("general", {
    look,
    options: { values: customValues },
    steps: [click("[data-changed-only]"), wait("[data-search-results]")],
    note: `${look} look: Show Only Changed.`,
  });
}

// The Reset control never moves the row (P1 fix, Lawrence 2026-10-07): for a row of each editor
// kind, start customized and press its Reset; the matrix measures layout shift (strict 0) and the
// anchors (the row's title, the next row's title) on each.
const RESET_SAMPLES: Record<string, string> = {
  toggle: "history.terminalCommands",
  segmented: "navigation.historyScope",
  number: "layout.defaultColumnWidth",
  url: "browser.newTabPage",
  color: "layout.paneBorderColor",
  sound: "notifications.sound",
  "time-range": "notifications.quietHours",
};
for (const [kind, key] of Object.entries(RESET_SAMPLES))
  variants[`play-reset-${kind}`] = variant(homes.get(key)!.category, {
    focus: key,
    options: { values: customValues },
    note: `Reset on a ${kind} row: the control fades out in its reserved slot.`,
    play: async (ctx) => {
      // Input lands at the control's page position: bring the row into view first.
      ctx.find({ selector: row(key) }).scrollIntoView({ block: "center" });
      await ctx.click({ selector: `${row(key)} [data-reset]` });
      await ctx.waitFor(() => !ctx.document.querySelector(`${row(key)} [data-reset]`));
    },
  });
variants["play-section-change"] = variant("accounts", {
  note: "Changing category: the column fades in; the sidebar never moves.",
  play: async (ctx) => {
    await ctx.click({ selector: '[data-section-link="advanced"]' });
    await ctx.waitFor(() => ctx.document.querySelector('[data-section="advanced"]'));
  },
});

const resetAnchors = Object.values(RESET_SAMPLES).flatMap((key) => [
  { selector: `${row(key)} .row-title` },
  { selector: `${row(key)} + [data-row-key] .row-title` },
]);

export default settingsPageEntry({
  id: "pages.settings",
  anchors: [{ selector: "[data-settings-search]" }, { selector: '[data-section-link="general"]' }, ...resetAnchors],
  title: "Settings",
  area: "Settings",
  height: 760,
  // Full-page surface: window mode defaults to `one`; standalone widths include tight panes.
  widths: { narrow: 480, normal: 1000, wide: 1440 },
  covers: [
    "page:cmux.settings",
    "pages/settings/components/AccountsSection.tsx",
    "pages/settings/components/ComputerUseCard.tsx",
    "pages/settings/components/ActionRow.tsx",
    "pages/settings/components/GhosttyDiagnostics.tsx",
    "pages/settings/components/GroupList.tsx",
    "pages/settings/components/Highlight.tsx",
    "pages/settings/components/HostCards.tsx",
    "pages/settings/components/HostSections.tsx",
    "pages/settings/components/PlaceholderSection.tsx",
    "pages/settings/components/ReadOnlyBanner.tsx",
    "pages/settings/components/ResetButton.tsx",
    "pages/settings/components/RowNotice.tsx",
    "pages/settings/components/SearchField.tsx",
    "pages/settings/components/SearchResults.tsx",
    "pages/settings/components/SectionActions.tsx",
    "pages/settings/components/SectionList.tsx",
    "pages/settings/components/SectionView.tsx",
    "pages/settings/components/SettingRow.tsx",
    "pages/settings/components/SettingsApp.tsx",
    "pages/settings/components/SettingsPage.tsx",
    "pages/settings/components/ScopeOverrides.tsx",
    "pages/settings/components/ThemePicker.tsx",
    "pages/settings/components/ThemePreview.tsx",
    "pages/settings/components/ThemeStudio.tsx",
    "pages/settings/editors/ChoiceOrNumberEditor.tsx",
    "pages/settings/editors/ColorEditor.tsx",
    "pages/settings/editors/DomainListEditor.tsx",
    "pages/settings/editors/Editor.tsx",
    "pages/settings/editors/FolderListEditor.tsx",
    "pages/settings/editors/HostListEditor.tsx",
    "pages/settings/editors/MenuEditor.tsx",
    "pages/settings/editors/NumberEditor.tsx",
    "pages/settings/editors/NumberField.tsx",
    "pages/settings/editors/SearchTemplateEditor.tsx",
    "pages/settings/editors/SegmentedEditor.tsx",
    "pages/settings/editors/Select.tsx",
    "pages/settings/editors/SoundEditor.tsx",
    "pages/settings/editors/TextEditor.tsx",
    "pages/settings/editors/TimeRangeEditor.tsx",
    "pages/settings/editors/ToggleEditor.tsx",
    "pages/settings/editors/UrlEditor.tsx",
    "pages/settings/icons.tsx",
  ],
  variants,
});
