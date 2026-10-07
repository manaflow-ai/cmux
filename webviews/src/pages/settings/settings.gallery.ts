// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { AccountsRow, AccountsState, HostLists } from "./ops";
import { groupRows, rowsInSection, schema, sections } from "./schema";

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
      value = ["~/Projects/Atlas", "~/Projects/Research with a long folder name"];
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
for (const section of sections) {
  variants[section.id] = variant(section.id);
  variants[`${section.id}-customized`] = variant(section.id, { options: { values: customValues } });
  // Every group gets a scroll/focus target, including controls below the initial viewport.
  for (const [index, group] of groupRows(rowsInSection(section.id)).entries())
    variants[`${section.id}-group-${index + 1}`] = variant(section.id, {
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
  backdrops: variant("appearance", {
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
  "theme-level-selected": variant("appearance", { steps: [click('input[name="theme-level"][value="workspace"]')] }),
  "theme-custom-spec": variant("appearance", {
    steps: [
      input('[data-card="theme"] input.field', "light:GitHub Light,dark:Dracula"),
      wait("[data-theme-list] .theme-choice:nth-child(2)"),
    ],
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
  "long-profiles": variant("rooms", { host: { ...host, rooms: [], browser_profiles: longProfiles } }),
  "long-machines": variant("machines", { host: { ...host, machines: longRows } }),
  "profile-editor": variant("rooms", {
    steps: [
      click('[data-profile="p-work"] .host-toggle'),
      wait(".host-form"),
      { selector: ".host-form input", action: "select" },
    ],
  }),
  "search-results": variant("general", { steps: [input("[data-settings-search]", "browser")] }),
  "search-empty": variant("general", { steps: [input("[data-settings-search]", "no-such-setting")] }),
  "reset-confirmation": variant("advanced", { steps: [click("[data-reset-all]"), wait("[data-confirm-reset-all]")] }),
  "theme-picker": variant("appearance", {
    steps: [click(`${row("appearance.theme")} .domain-button`), wait(".domain-panel")],
  }),
  "theme-picker-empty": variant("appearance", {
    steps: [click(`${row("appearance.theme")} .domain-button`), input(".domain-panel input", "no-such-theme")],
  }),
  "font-picker": variant("terminal", {
    steps: [click(`${row("terminal.fontFamily")} .domain-button`), wait(".domain-panel")],
  }),
  "domains-unavailable": variant("terminal", { options: { domains: null } }),
  "theme-text-fallback": variant("appearance", { options: { domains: null } }),
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
  "write-error": variant("general", {
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

export default settingsPageEntry({
  id: "pages.settings",
  title: "Settings",
  area: "Settings",
  height: 760,
  // Full-page surface: window mode defaults to `one`; standalone widths include tight panes.
  widths: { narrow: 480, normal: 1000, wide: 1440 },
  covers: [
    "page:cmux.settings",
    "pages/settings/components/AccountsSection.tsx",
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
