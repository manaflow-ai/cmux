// l10n-allow-file: gallery fixtures, not shipped UI.
import { mockAgentKeys } from "./mockAgentKeys";
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type {
  AccountsCmux,
  AccountsRow,
  AccountsState,
  CloudEnvironmentsState,
  HarnessesState,
  HostLists,
  ProviderAccount,
  IntegrationRow,
} from "./ops";
import { pageDensities, pageDensityPlay } from "../../gallery/pageDensityFixtures";
import { minutesAgo, GALLERY_NOW } from "../../gallery/clock";
import { categories, categoryOf, defaultCategory, isCategory } from "./categories";
import { MockTeams } from "./mockTeams";
import { mockThemeColors } from "./mockThemes";
import { schema } from "./schema";
import { mockDevicesState, mockDomains } from "./mockProvider";
import { ACCOUNT_LISTS } from "../shared/signIn/galleryFixtures";
import MARTIN_PANDEMONIUM from "../../gallery/fixtures/art/martin-pandemonium.jpg?inline";
import FRIEDRICH_FOREST_MOONLIGHT from "../../gallery/fixtures/art/friedrich-forest-moonlight.jpg?inline";
import VAN_GOGH_STARRY_NIGHT from "../../gallery/fixtures/art/van-gogh-starry-night.jpg?inline";
import HOKUSAI_GREAT_WAVE from "../../gallery/fixtures/art/hokusai-great-wave.jpg?inline";
import FRIEDRICH_WANDERER from "../../gallery/fixtures/art/friedrich-wanderer.jpg?inline";
import DAHL_DRESDEN_MOONLIGHT from "../../gallery/fixtures/art/dahl-dresden-moonlight.jpg?inline";
import FRIEDRICH_MONK_BY_THE_SEA from "../../gallery/fixtures/art/friedrich-monk-by-the-sea.jpg?inline";
import MONET_IMPRESSION_SUNRISE from "../../gallery/fixtures/art/monet-impression-sunrise.jpg?inline";
import DORE_PARADISE_LOST_BOOK_VI from "../../gallery/fixtures/art/dore-paradise-lost-book-vi.jpg?inline";
import DORE_RAVEN from "../../gallery/fixtures/art/dore-raven.jpg?inline";
import DORE_EMPYREAN from "../../gallery/fixtures/art/dore-empyrean.jpg?inline";

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
const cmuxSignedIn: AccountsCmux = {
  title: "cmux Account",
  detail: "s…@e…",
  status: "Signed in",
  statusKind: "success",
  busy: false,
  buttons: [
    button("cmux.switchAccount", "Switch Account…"),
    { ...button("cmux.signOut", "Sign Out"), destructive: true },
  ],
  note: null,
  error: null,
};
const cmuxSignedOut: AccountsCmux = {
  ...cmuxSignedIn,
  detail: null,
  status: "Signed out",
  statusKind: "attention",
  buttons: [button("cmux.signIn", "Sign In to cmux")],
  signInBackend: "Signs in to Development backend · dev-abc.cmux.dev",
  error: "Sign-in did not finish: Sign-in timed out. Check your connection and try again. (TIMED_OUT)",
};
const cmuxSigningIn: AccountsCmux = {
  ...cmuxSignedIn,
  detail: null,
  status: "Signing in…",
  statusKind: "neutral",
  busy: true,
  buttons: [button("cmux.continueInBrowser", "Open in Browser"), button("cmux.cancelSignIn", "Cancel")],
  note: "Finish signing in in your browser. If no page opened, choose Open in Browser.",
};
const accounts = (patch: Partial<AccountsRow> = {}, state: Partial<AccountsState> = {}): AccountsState => ({
  teams: null,
  refresh: "Refresh",
  refreshing: false,
  cmux: cmuxSignedIn,
  removeTitle: "Remove from CodeRouter",
  groups: [{ id: "sample", title: "Sample providers", rows: [{ ...account, ...patch }] }],
  ...state,
});
/** The Active Team menu and the Teams group over sample teams, after `edit` (a gesture or a flag). */
const activeTeamRow = (teams: MockTeams): NonNullable<AccountsState["teams"]> => ({
  title: "Active Team",
  help: "Cloud machines, CodeRouter and phone access use this team.",
  options: teams.teams.map((team) => ({ id: team.id, name: team.name, active: team.id === teams.active })),
  disabled: false,
  note: null,
  error: null,
});
const withTeams = (edit: (teams: MockTeams) => void = () => {}): AccountsState => {
  const teams = new MockTeams();
  teams.teams = teams.teams.map((team) => ({
    ...team,
    name: team.role === "admin" ? "Sample team" : "Another sample team",
  }));
  edit(teams);
  return accounts({}, { teams: activeTeamRow(teams), teamList: teams.state() });
};
const host: Partial<HostLists> = {
  machines: [
    {
      id: "sample-build",
      title: "Research build machine",
      subtitle: "Online · local network",
      active: true,
      color: "#7F5FA8",
      color_key: "research build machine",
      // A Remote machine's AutoCloud enrollment (_acpmux/autocloud_enroll there), off: opt-in for customers.
      autocloud: { on: false, error: null },
    },
    // A Cloud machine cmux made: its Dedicated agent machine switch (acpmux vmHost), on by default.
    {
      id: "sample-cloud",
      title: "Sample cloud machine",
      subtitle: null,
      active: true,
      color: "#3F7FBF",
      color_key: "sample cloud machine",
      vm_host: { on: true, busy: false, error: null },
    },
  ],
  settings_file: "/Users/sample/.config/cmux/cmux.json",
  // Settings › Server (ServerCard), its only card: the servers the host heard from, sent with every
  // host list since fe482b41. Without it the category draws nothing (serverCard.gallery.ts has its states).
  server: {
    title: "Server",
    empty: "No server has answered yet.",
    socket_title: "Local Socket",
    tailnet_title: "Tailscale Address",
    copy_title: "Copy",
    pair_title: "Pair",
    servers: [
      {
        id: "cmux-tui|local",
        kind: "cmux-tui",
        host: null,
        name: "cmux-tui",
        running: true,
        status: "Running",
        version_line: "Version 0.67.0 · Build 7a3c9e1 · Protocol 12",
        restart: null,
        socket: "/Users/sample/.cmux/sockets/main.sock",
        tailnet: "100.64.0.7:7777",
      },
    ],
  },
  // Most variants omit artwork; the backdrop variant supplies sample thumbnails.
  backdrops: [],
  // Settings › Import: what the host's scan found (ImportSuggestionsCenter.settingsJSON), sent by
  // default since #22710, one card hidden with Not Now.
  import_suggestions: {
    title: "Found on This Mac",
    empty: "Nothing to bring over right now. cmux looks again when you come back to it.",
    cards: [
      {
        id: "browser.chrome",
        kind: "browser",
        title: "Chrome",
        facts: "3 profiles · history, bookmarks and cookies",
        benefit: "Sites you're signed into in Chrome stay signed in here, and your history fills the address bar.",
        state: "ready",
        primary: { action: "start", title: "Import" },
        secondary: [{ action: "dismiss", title: "Not Now" }],
        dismissed: false,
      },
      {
        id: "agents.claudeCode",
        kind: "claudeCode",
        title: "Claude Code",
        facts: "412 sessions",
        benefit: "Your Claude Code history becomes searchable chats. Open one to pick up where you left off.",
        state: "ready",
        primary: { action: "start", title: "Show Chats" },
        secondary: [{ action: "restore", title: "Show Again" }],
        dismissed: true,
      },
    ],
  },
};
const rowShapeMachines: HostLists["machines"] = [
  {
    id: "sample-row-shape",
    title: "Research build machine",
    subtitle: "Online · local network",
    active: true,
    color: "#7F5FA8",
    color_key: "research build machine",
    vm_host: { on: true, busy: false, error: null },
  },
];
/** One Remote machine with its AutoCloud enrollment in `autocloud`, for the autocloud-* variants. */
function autoCloudMachines(autocloud: NonNullable<HostLists["machines"][number]["autocloud"]>): HostLists["machines"] {
  return [
    {
      id: "sample-remote-mac",
      title: "Studio Mac",
      subtitle: "Online · Remote",
      active: true,
      color: "#7F5FA8",
      color_key: "studio mac",
      autocloud,
    },
  ];
}
const macCaps = ["arm64", "macos", "xcode", "ios-simulator", "gpu-metal"];
const autoCloudPlay = async (ctx: Parameters<NonNullable<SettingsPageVariant["play"]>>[0]) => {
  const card = ctx.find({ selector: '[data-card="machines"]' });
  card.setAttribute("data-gallery-capture", "");
  card.scrollIntoView({ block: "center" });
};
const rowShapeEnvironments: CloudEnvironmentsState = {
  available: true,
  loading: false,
  error: null,
  environments: [
    {
      id: "env-row-shape",
      name: "Research environment",
      repo: "manaflow-ai/cmux@feat-cmux-next",
      setup_script: "bun install",
      status: "failed",
      error: "setup exited 3",
      log_tail: "lockfile mismatch",
    },
  ],
};
const click = (selector: string): PageFixtureStep => ({ selector, action: "click" });
const input = (selector: string, value: string): PageFixtureStep => ({ selector, action: "input", value });
const wait = (selector: string): PageFixtureStep => ({ selector, action: "wait" });
const row = (key: string) => `[data-row-key="${key}"]`;
const focusComputerUse: PageFixtureStep = {
  // The mode picker's checked mode: it shows in every phase.
  selector: '[data-card="computer-use"] [data-mode][data-checked] input',
  action: "focus",
};
const focusApprovals: PageFixtureStep = {
  selector: '[data-card="computer-use"] [data-approval] button',
  action: "focus",
};
const focusDenied: PageFixtureStep = {
  selector: '[data-card="computer-use"] [data-denied-input]',
  action: "focus",
};
const computerUseReady = {
  phase: "ready" as const,
  accessibility: true,
  screen_recording: false,
  helper: null,
  engine: "cmux Computer Use 1.0",
  worker: { state: "running" as const, pid: 4242 },
  approvals: [],
  running_apps: [
    { id: "com.apple.Safari", name: "Safari" },
    { id: "com.apple.Notes", name: "Notes" },
    { id: "com.figma.Desktop", name: "Figma" },
  ],
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
    else if (setting.kind === "choice_or_url")
      value = { [setting.url_key ?? "url"]: "http://mini.tail1234.ts.net:7320" };
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
/** A `link-<app>` row of `agent hook status` (cmux-tui agent_hook_links.rs). */
function linkRow(app: string, path: string, state: IntegrationRow["state"]): IntegrationRow {
  return { id: `link-${app}`, path, state, reason: null, detail: null, error: null };
}

const variant = (section: string, extra: Omit<SettingsPageVariant, "section"> = {}): SettingsPageVariant => {
  // A section that is neither a category id nor one of its aliases opens General (categoryOf), so
  // a state's steps wait for a card that is never drawn: say which section is wrong instead.
  if (!isCategory(section) && categoryOf(section) === defaultCategory)
    throw new Error(`settings gallery: ${JSON.stringify(section)} is not a Settings category or alias`);
  return { section, host, accounts: accounts(), ...extra };
};
/** The Endpoint form captured in view (the tab sits below the Agents list), once `ready` shows. */
const showEndpoint =
  (ready = "[data-agents-endpoint]") =>
  async (ctx: Parameters<NonNullable<SettingsPageVariant["play"]>>[0]) => {
    await ctx.waitFor(() => ctx.document.querySelector(ready));
    const form = ctx.find({ selector: "[data-agents-endpoint]" });
    form.setAttribute("data-gallery-capture", "");
    form.scrollIntoView({ block: "center" });
  };
/** States whose fixture steps change the page's height on purpose (the scope switch drops the
 * All Workspaces tiles; a refused name opens its error line), so the rows below them move. They are
 * measured in pages.settings-motion, whose layout shift is recorded, not held at 0 (#41237: on
 * Appearance those rows are in view). */
export const heightChangingVariants: Record<string, SettingsPageVariant> = {
  "backdrops-workspace": variant("appearance", {
    focus: "appearance.background",
    workspace: "ws-1",
    options: {
      values: { "appearance.background": "starryNight" },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: null }],
    },
    host: {
      ...host,
      backdrops: [{ id: "starryNight", title: "Sample night", attribution: "Gallery sample thumbnail" }],
    },
    play: async (ctx) => {
      const selector = ".backdrop-scope label:last-child";
      await ctx.waitFor(() => ctx.document.querySelector(selector));
      await ctx.click({ selector });
      await ctx.waitFor(() => ctx.document.querySelector(`${selector} input:checked`));
    },
    note: "Change Background… on a workspace: This Workspace (Research) picked, following All Workspaces until it has its own.",
  }),
  "theme-file-refused": variant("theme", {
    allThemes: true,
    options: { values: { "appearance.theme": "Dracula" } },
    steps: [
      wait('[data-theme-files-action="save"]:not([disabled])'),
      click('[data-theme-files-action="save"]'),
      input('[data-theme-files-prompt="name"] input', "Dracula"),
      click('[data-theme-files-prompt="name"] button[type="submit"]'),
      wait("[data-theme-files-error]"),
    ],
    note: "A name a shipped theme uses is refused inline; the name prompt stays open.",
  }),
};

const variants: Record<string, SettingsPageVariant> = {
  "model-picker-placement-inherited": variant("chat", {
    focus: "agentPane.display.harnessPlacement",
    host: { ...host, harness_placement: "left" },
    note: "The normal placement row shows the existing left rail preference before a new choice is saved.",
  }),
  "model-picker-placement-symbols": variant("chat", {
    focus: "agentPane.display.harnessPlacement",
    host: { ...host, harness_placement: "left" },
    options: { values: { "agentPane.display.harnessPlacement": "symbols" } },
    note: "An explicit top symbols choice wins over the old left rail and offers Reset.",
  }),
  // Taste Board #15: Beta chips on experimental rows (appearance.settingsBetaChips, off by default).
  "beta-chips-off": variant("experimental", {
    focus: "appearance.settingsBetaChips",
    note: "Beta chips off (the default): the Experimental page and its sidebar entry exactly as today.",
  }),
  "beta-chips-on": variant("experimental", {
    focus: "appearance.settingsBetaChips",
    options: { values: { "appearance.settingsBetaChips": true } },
    note: "Beta chips on: each experimental row's title and the Experimental sidebar entry carry a small Beta chip.",
  }),
  "beta-chips-on-labs": variant("experimental", {
    focus: "labs.previewFeatures",
    options: { values: { "appearance.settingsBetaChips": true } },
    note: "Beta chips on, scrolled to the Labs rows (Preview Features, Voice Room, Live Code).",
  }),
  "beta-chips-on-general": variant("general", {
    options: { values: { "appearance.settingsBetaChips": true } },
    note: "Beta chips on, on an everyday page: no row gets a chip; only the Experimental sidebar entry does.",
  }),
  "agent-tools": variant("agents", {
    focus: "agents.cmuxMcp",
    note: "Give Agents cmux’s Tools (on by default) with its Claude Code and Codex switches, each coding agent on this Mac, and the manual lines for agents started elsewhere.",
  }),
};
for (const category of categories) {
  // The theme studio (every bundled theme) is Appearance's since the Theme page moved there.
  const allThemes = category.id === "appearance";
  // Variant names are lower kebab case: the New Tab category's id is newTab.
  const name = category.id.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
  variants[name] = variant(category.id, { allThemes });
  variants[`${name}-customized`] = variant(category.id, { allThemes, options: { values: customValues } });
  // Every group gets a scroll/focus target, including controls below the initial viewport.
  for (const [index, group] of category.groups.entries())
    variants[`${name}-group-${index + 1}`] = variant(category.id, {
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

/// A window's reset time `minutes` after the stage clock (installGalleryClock, GALLERY_NOW), so the
/// reset labels and even-pace marks read the same in every capture.
const resetsIn = (minutes: number) => GALLERY_NOW / 1000 + minutes * 60;

// Synthetic accounts only (example.com addresses): the CLI logins and one added Codex account.
const providerAccounts: ProviderAccount[] = [
  {
    id: "codex-login",
    family: "codex",
    name: "ChatGPT",
    home: null,
    defaultHome: "~/.codex",
    shadowOf: null,
    signedIn: true,
    plan: "pro",
    email: "alex@example.com",
    enabled: true,
    builtin: true,
    // Read when Settings opened (`_acpmux/account/usage`); reset times on the stage clock, so the
    // capture holds still. Both under even pace (40% and 71% of their windows gone).
    usage: {
      windows: [
        { id: "session", usedPercent: 22, windowMins: 300, resetsAt: resetsIn(180) },
        { id: "weekly", usedPercent: 41, windowMins: 10080, resetsAt: resetsIn(2 * 1440) },
      ],
      plan: "pro",
      credits: { balance: "56766" },
    },
  },
  {
    id: "codex-2",
    family: "codex",
    name: "ChatGPT 2",
    home: "~/.cmux/accounts/codex-2",
    defaultHome: "~/.codex",
    shadowOf: "~/.codex",
    signedIn: true,
    plan: "plus",
    email: "sam@example.com",
    enabled: false,
    builtin: false,
    // Ahead of even pace: 87.5% used with 20% of the 5 hours gone.
    usage: {
      windows: [{ id: "session", usedPercent: 87.5, windowMins: 300, resetsAt: resetsIn(240) }],
      plan: "plus",
    },
  },
  {
    id: "claude-login",
    family: "claude",
    name: "Claude",
    home: null,
    defaultHome: "~/.claude",
    shadowOf: null,
    signedIn: true,
    plan: "max",
    email: "alex@example.com",
    enabled: true,
    builtin: true,
    // Claude's windows carry no length (claude_stdio/usage_limits.rs); the mark reads it by id. The
    // 5-hour window is near its reset (80% gone, 58% used); the week is ahead (29% gone, 70% used).
    usage: {
      windows: [
        { id: "session", usedPercent: 58, resetsAt: resetsIn(60) },
        { id: "weekly", usedPercent: 70, resetsAt: resetsIn(5 * 1440) },
      ],
    },
  },
];

/** The Codex harness row alone, for the account variants. */
const codexHarness: HarnessesState["harnesses"] = [
  {
    id: "codex",
    name: null,
    kind: "acp",
    source: "path",
    problem: null,
    version: "0.164.0",
    checkedAt: minutesAgo(54),
  },
];

Object.assign(variants, {
  "agents-harnesses-registry": variant("agents", {
    note: "Harnesses: found on PATH, a profile file, an installed ACP Registry agent, a terminal-only harness, and acpmux's problem text. Codex and Claude Code say whose login they use and its plan, list every account routing may use with its switch and each signed-in account's 5-hour and weekly usage read at rest, with an even-pace mark on every bar (ChatGPT 2's and Claude's week run ahead of it, in the warning color), and Codex offers Add account.",
    harnesses: {
      loading: false,
      problem: null,
      accounts: providerAccounts,
      harnesses: [
        {
          id: "claude",
          name: null,
          kind: "claude-stdio",
          source: "path",
          problem: null,
          version: "2.0.9",
          checkedAt: minutesAgo(54),
        },
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.164.0",
          checkedAt: minutesAgo(54),
        },
        { id: "cursor", name: null, kind: "acp", source: "path", problem: null },
        { id: "github-copilot-cli", name: "GitHub Copilot", kind: "acp", source: "user-file", problem: null },
        { id: "goose", name: null, kind: "acp", source: "registry", problem: null },
        { id: "grok", name: null, kind: "acp", source: "path", problem: "Authentication required" },
        { id: "aider", name: "Aider", kind: "terminal", source: "user-file", problem: null },
      ],
    },
  }),
  // Settings > Agents > Agent integrations, opened: installed, needs repair, a file cmux did
  // not create in the way (no Install, the command to copy), and not installed.
  "agents-integrations": variant("agents", {
    note: "Agent integrations opened: one row per hook state, a conflict with no Install, and the manual command.",
    focus: "agents.integrations",
  }),
  "agents-integrations-no-cli": variant("agents", {
    note: "Agent integrations in a build without the cmux CLI: it says so and gives the command.",
    focus: "agents.integrations",
    integrations: { loading: false, problem: "unavailable", command: "cmux agent hook install", providers: [] },
  }),
  // "Your other apps": the cmux MCP server in Claude desktop, Claude Code and Codex
  // (`agent hook status` link- rows), above the hooks.
  "agents-integrations-links": variant("agents", {
    note: "Your other apps: Claude desktop connected, Claude Code not yet, Codex linked by another cmux build (Reconnect).",
    focus: "agents.integrations",
    integrations: {
      loading: false,
      problem: null,
      command: "cmux agent hook install",
      providers: [
        linkRow("claude-desktop", "~/Library/Application Support/Claude/claude_desktop_config.json", "installed"),
        linkRow("claude-code", "~/.claude.json", "absent"),
        linkRow("codex", "~/.codex/config.toml", "partial"),
        { id: "claude", path: "~/.claude/settings.json", state: "installed", reason: null, detail: null, error: null },
        { id: "codex", path: "~/.codex/hooks.json", state: "absent", reason: null, detail: null, error: null },
      ],
    },
  }),
  "agents-integrations-links-blocked": variant("agents", {
    note: "Your other apps: Codex already has a server named cmux that cmux did not add (no Connect); Claude desktop's settings file is unreadable.",
    focus: "agents.integrations",
    integrations: {
      loading: false,
      problem: null,
      command: "cmux agent hook install",
      providers: [
        {
          ...linkRow(
            "claude-desktop",
            "~/Library/Application Support/Claude/claude_desktop_config.json",
            "unavailable",
          ),
          reason: "unreadable",
        },
        { ...linkRow("codex", "~/.codex/config.toml", "conflict"), reason: "not_owned" },
      ],
    },
  }),
  "agents-integrations-links-error": variant("agents", {
    note: "Your other apps: Connect on Claude Code failed because its CLI is not on the login PATH; the row says what to run.",
    focus: "agents.integrations",
    integrations: {
      loading: false,
      problem: null,
      command: "cmux agent hook install",
      providers: [
        {
          ...linkRow("claude-code", "~/.claude.json", "absent"),
          error: "link-claude-code: the claude CLI is not on PATH; run: claude mcp add-json --scope user cmux '{…}'",
        },
        linkRow("codex", "~/.codex/config.toml", "installed"),
      ],
    },
  }),
  "agents-harnesses-account-added": variant("agents", {
    note: "Codex right after Add account: ChatGPT 3 has a shadow home of its own, waits for its sign-in, and is on for routing.",
    harnesses: {
      loading: false,
      problem: null,
      accounts: [
        ...providerAccounts,
        {
          id: "codex-3",
          family: "codex",
          name: "ChatGPT 3",
          home: "~/.cmux/accounts/codex-3",
          defaultHome: "~/.codex",
          shadowOf: "~/.codex",
          signedIn: false,
          plan: null,
          email: null,
          enabled: true,
          builtin: false,
        },
      ],
      harnesses: [
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.164.0",
          checkedAt: minutesAgo(2),
        },
      ],
    },
  }),
  // Per-account usage (feature map `usage-per-account`, Leo 2026-11-23: "Per-account 5-hour and weekly
  // limits and the last cache-miss cause"): a Claude account's newest saved windows, and its usage
  // block's hover line naming the last prompt cache miss (the `title`, read by the capture as
  // `data-cache-miss`).
  ...Object.fromEntries(
    (
      [
        ["expired", "the 5-hour cache window lapsed between turns", true],
        ["model", "a model switch started a new cache", true],
        ["compaction", "only a miss is known yet: no windows, the hover line alone", false],
      ] as const
    ).map(([cause, why, windows]) => [
      `agents-harnesses-claude-usage-miss-${cause}`,
      variant("agents", {
        note: `Claude's account row shows the 5-hour and weekly limits its chats last saved; hovering the usage names the last cache miss: ${cause} (${why}).`,
        harnesses: {
          loading: false,
          problem: null,
          accounts: providerAccounts.map((account) =>
            account.id === "claude-login"
              ? {
                  ...account,
                  usage: {
                    windows: windows
                      ? [
                          { id: "session", usedPercent: 34, windowMins: 300 },
                          { id: "weekly", usedPercent: 18, windowMins: 10080 },
                        ]
                      : [],
                    plan: "max",
                    lastCacheMiss: { cause, at: minutesAgo(12) },
                  },
                }
              : account,
          ),
          harnesses: [
            {
              id: "claude",
              name: null,
              kind: "claude-stdio",
              source: "path",
              problem: null,
              version: "2.0.9",
              checkedAt: minutesAgo(54),
            },
          ],
        },
      }),
    ]),
  ),
  // A signed-out account whose usage read before its sign-out is no longer shown.
  "agents-harnesses-account-signed-out": variant("agents", {
    note: "ChatGPT 2 after its sign-out: Sign In comes back and the usage read before it is no longer shown.",
    harnesses: {
      loading: false,
      problem: null,
      accounts: providerAccounts.map((account) =>
        account.id === "codex-2" ? { ...account, signedIn: false, email: null, plan: null } : account,
      ),
      harnesses: codexHarness,
    },
  }),
  // Logins done right (Leo, 2026-11-22: "this is simply logins, done righr."): on a host that signs
  // in in place, the harness row's Sign In shows the code under the row, not a terminal tab.
  "agents-harnesses-sign-in-in-place": variant("agents", {
    note: "Codex's Sign In on a host that signs in in place: the code under the row, waiting for the approval.",
    accounts: accounts({}, { signInAccounts: ACCOUNT_LISTS.signedOut }),
    signInHold: true,
    harnesses: {
      loading: false,
      problem: null,
      accounts: providerAccounts.map((account) =>
        account.id === "codex-login" ? { ...account, signedIn: false, email: null, plan: null } : account,
      ),
      harnesses: codexHarness,
    },
    steps: [
      click('[data-harness="codex"] [data-harness-action="signIn"]'),
      wait('[data-harness-sign-in="codex"] .signin[data-state="waiting"]'),
    ],
  }),
  "agents-harnesses-unreachable": variant("agents", {
    note: "Harnesses when the acpmux daemon did not answer.",
    harnesses: { loading: false, problem: "unreachable", harnesses: [] },
  }),
  "agents-harnesses-checking": variant("agents", {
    note: "Harnesses while the first look has found nothing yet: it says it is checking.",
    harnesses: { loading: true, problem: null, harnesses: [] },
  }),
  // Change Background… (cx-t2x.4): the picker on Appearance, with its Opacity slider.
  backdrops: variant("appearance", {
    focus: "appearance.background",
    options: { values: { "appearance.background": "starryNight", "appearance.backgroundOpacity": 0.6 } },
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
    note: "Change Background…: the art picker and its Opacity slider on Appearance, with a public-safe sample thumbnail.",
  }),
  // David Beyer (Nov 20) could not find a sidebar font size: General opens on one Text Size and density pick.
  "general-text-size": variant("general", {
    note: "General's first card: Text Size (five Aa steps) and density, the pick Set Up cmux offers too.",
  }),
  "general-text-size-larger": variant("general", {
    options: { values: { "appearance.metrics.chromeFontSize": 16, "appearance.density": "comfortable" } },
    note: "Text Size at Larger with Comfortable density: the steps follow the density's own body size.",
  }),
  // One settings area (David Beyer, 2026-11-20): the sidebar's short top level, then More opened.
  "sidebar-more": variant("general", {
    steps: [click(".sidebar-more"), wait('.sidebar-more[aria-expanded="true"]')],
    note: "The sidebar's More opened from General: the pages a person opens less often, below the short top level.",
  }),
  "appearance-background": variant("appearance", {
    focus: "appearance.background",
    workspace: "ws-1",
    options: {
      values: { "appearance.background": "starryNight", "appearance.backgroundOpacity": 0.6 },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: null }],
    },
    host: {
      ...host,
      backdrops: [{ id: "starryNight", title: "Sample night", attribution: "Gallery sample thumbnail" }],
    },
    steps: [wait('[data-card="backdrop"]')],
    note: "Change Background… opens Appearance on its background picker: the art, Material and Opacity, for a workspace.",
  }),
  "appearance-density": variant("appearance", {
    focus: "card.density",
    options: { values: { "appearance.density": "cozy" } },
    note: "Appearance on its density card: the density tiles and Text Size.",
  }),
  // Leo, 10-19: Appearance's floating Undo, Redo and Reset, after a background pick (Undo names it).
  "appearance-undo-bar": variant("appearance", {
    focus: "appearance.background",
    host: {
      ...host,
      derived: { "appearance.backgroundOpacity": 1 },
      backdrops: [{ id: "starryNight", title: "Sample night", attribution: "Gallery sample thumbnail" }],
    },
    steps: [
      wait('[data-card="backdrop"]'),
      click('[data-card="backdrop"] .backdrop-tile[aria-label="Shuffle Paintings"]'),
      wait("[data-appearance-bar] [data-undo]:not([disabled])"),
      { selector: "[data-appearance-bar] [data-undo]", action: "focus" },
    ],
    note: "Appearance's floating bar at the bottom right after picking Shuffle Paintings: Undo names the step, Redo waits, Reset offers Restore How It Was or Reset to Defaults.",
  }),
  // Leo, 11-19: "make sure you can recover and stuff. for all customizations". The Reset menu open on
  // Personalization with a background and an accent set: Reset <card> for each card of the page.
  "appearance-reset-cards": variant("personalization", {
    options: {
      values: {
        "appearance.background": "daily",
        "appearance.backgroundOpacity": 0.6,
        "appearance.accent": "#4F7DF2",
      },
    },
    steps: [wait("[data-appearance-bar]"), click('[data-menu="appearance-reset"]'), wait('[role="menuitem"]')],
    note: "The Reset menu: Restore How It Was, Reset to Defaults, then Reset App Theme, Reset Window Background and Reset Density and Motion; a card with nothing set is dimmed. Each reset only its card's keys, as one Undo step.",
  }),
  // The floating bar's Presets menu open: Solid, Frosted, Glass and Clear, the current one checked.
  "appearance-presets": variant("appearance", {
    options: { values: { "appearance.backgroundOpacity": 0.8, "appearance.backgroundBlur": "frosted" } },
    steps: [wait("[data-appearance-bar]"), click('[data-menu="appearance-presets"]'), wait('[role="menuitemradio"]')],
    note: "Presets at the bottom right beside Undo, Redo and Reset: one pick sets the window's Opacity and Material and every surface's opacity, as one undoable step; Frosted is checked.",
  }),
  // The terminal font list open: recent fonts first under a Recent tag, every family in its own face.
  "font-picker-open": variant("terminal", {
    focus: "terminal.fontFamily",
    options: { values: { "terminal.fontFamily": "JetBrains Mono" } },
    steps: [click(`${row("terminal.fontFamily")} [data-font-picker]`), wait("[data-font-option]")],
    note: "Terminal Font Family's list: the default first, then the fonts picked lately with a Recent tag, then every installed family, each drawn in its own face. Arrow keys preview live; Return picks, Escape reverts.",
  }),
  // Unset surface opacities rest on the window's values, drawn as their own; colors keep their badge.
  "surfaces-inherit-window": variant("appearance", {
    focus: "appearance.surfaces.sidebar.opacity",
    options: { values: { "appearance.backgroundOpacity": 0.8 } },
    host: { ...host, derived: { "appearance.backgroundOpacity": 0.8 } },
    steps: [wait(row("appearance.surfaces.sidebar.opacity"))],
    note: "Surfaces: each unset opacity shows the window's 80% as its value and each unset color the window's color under an Inherits window badge; no row reads a truncated default label.",
  }),
  "backdrops-pending": variant("appearance", {
    focus: "appearance.background",
    options: { values: { "appearance.background": "system:/S/Sonoma.heic" } },
    host: {
      ...host,
      backdrops: [
        {
          id: "system:/S/Sonoma.heic",
          title: "Sonoma",
          attribution: "macOS system wallpaper · Sonoma",
          collection: "apple",
          collection_title: "Apple Wallpapers",
          downloaded: true,
        },
        {
          id: "system:/S/Grid Green.madesktop",
          title: "Grid Green",
          attribution: "macOS system wallpaper · Grid Green",
          collection: "apple",
          collection_title: "Apple Wallpapers",
          downloaded: false,
        },
        {
          id: "system:/aerials/4KSDR240FPS/B2.mov",
          title: "Iceland Dusk",
          attribution: "macOS system wallpaper · Iceland Dusk",
          collection: "video",
          collection_title: "Moving wallpapers",
          video: true,
          downloaded: false,
        },
      ],
    },
    backdropImages: {
      "system:/S/Sonoma.heic":
        "data:image/svg+xml," +
        encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="#8b9aae"/><circle cx="236" cy="58" r="34" fill="#f7e7bd"/><path d="M0 145L90 82L160 139L250 72L320 130V180H0Z" fill="#40526b"/></svg>',
        ),
      "system:/S/Grid Green.madesktop":
        "data:image/svg+xml," +
        encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="#263a32"/><path d="M0 180L108 58L186 180Z" fill="#6fa06c"/><path d="M128 180L233 38L320 180Z" fill="#9bcf8d"/></svg>',
        ),
    },
    steps: [wait('[data-card="backdrop"]'), { selector: '[data-card="backdrop"] .backdrop-pending', action: "focus" }],
    note: "Backgrounds while macOS is still downloading one wallpaper: the selected tile is ready and the pending tile stays visibly dimmed with its download affordance.",
  }),
  "backdrops-empty": variant("appearance", {
    focus: "appearance.background",
    options: { values: { "appearance.background": "none" } },
    host: { ...host, backdrops: [] },
    // With no artwork the picker hides (useBackdropsShown) and the setting draws as its plain row.
    steps: [wait(row("appearance.background"))],
    note: "No artwork returned yet: the picker stays hidden and Background is its plain row, so the setting stays usable while the host list loads or is unavailable.",
  }),
  // Add from a Link (backgrounds plan phase 3): the link form open under the picker, a link typed.
  "backdrops-link": variant("appearance", {
    focus: "appearance.background",
    host: {
      ...host,
      backdrops: [{ id: "starryNight", title: "Sample night", attribution: "Gallery sample thumbnail" }],
    },
    steps: [
      wait('[data-card="backdrop"]'),
      click('[data-card="backdrop"] button[aria-expanded] ~ button[aria-expanded]'),
      input('[data-card="backdrop-link"] input[type="url"]', "https://example.com/harbor.jpg"),
    ],
    note: "Add from a Link: an https image or movie downloads into the backgrounds folder and becomes the background.",
  }),
  // Change Background… on a workspace (cx-t2x.5): This Workspace, following All Workspaces.
  // The curated backdrop art (cx-t2x.7): the real thumbnails of three works from each picker
  // collection, labelled "Title — Artist" with the credit lines the app sends, one picked.
  "curated-art": variant("appearance", {
    focus: "appearance.background",
    options: {
      values: { "appearance.background": "van-gogh-starry-night" },
    },
    host: {
      ...host,
      backdrops: [
        {
          id: "martin-pandemonium",
          title: "Pandemonium — John Martin",
          attribution: "Pandemonium · John Martin · 1841 · Musée du Louvre, Paris · Public domain",
          collection: "darkArt",
          collection_title: "Dark Art",
        },
        {
          id: "friedrich-forest-moonlight",
          title: "Forest Interior by Moonlight — Caspar David Friedrich",
          attribution:
            "Forest Interior by Moonlight · Caspar David Friedrich · c. 1823–1830 · Alte Nationalgalerie, Berlin · Public domain",
          collection: "darkArt",
          collection_title: "Dark Art",
        },
        {
          id: "van-gogh-starry-night",
          title: "The Starry Night — Vincent van Gogh",
          attribution: "The Starry Night · Vincent van Gogh · 1889 · Museum of Modern Art, New York · Public domain",
          collection: "museumIcons",
          collection_title: "Museum Icons",
        },
        {
          id: "hokusai-great-wave",
          title: "The Great Wave off Kanagawa — Katsushika Hokusai",
          attribution:
            "The Great Wave off Kanagawa · Katsushika Hokusai · c. 1830–32 · Metropolitan Museum of Art, New York (JP1847) · Public domain",
          collection: "museumIcons",
          collection_title: "Museum Icons",
        },
        {
          id: "friedrich-wanderer",
          title: "Wanderer above the Sea of Fog — Caspar David Friedrich",
          attribution:
            "Wanderer above the Sea of Fog · Caspar David Friedrich · c. 1818 · Hamburger Kunsthalle · Public domain",
          collection: "museumIcons",
          collection_title: "Museum Icons",
        },
        {
          id: "dahl-dresden-moonlight",
          title: "View of Dresden by Moonlight — Johan Christian Dahl",
          attribution:
            "View of Dresden by Moonlight · Johan Christian Dahl · 1839 · Galerie Neue Meister, Dresden · Public domain",
          collection: "calm",
          collection_title: "Calm",
        },
        {
          id: "friedrich-monk-by-the-sea",
          title: "The Monk by the Sea — Caspar David Friedrich",
          attribution:
            "The Monk by the Sea · Caspar David Friedrich · 1808–1810 · Alte Nationalgalerie, Berlin · Public domain",
          collection: "calm",
          collection_title: "Calm",
        },
        {
          id: "monet-impression-sunrise",
          title: "Impression, Sunrise — Claude Monet",
          attribution: "Impression, Sunrise · Claude Monet · 1872 · Musée Marmottan Monet, Paris · Public domain",
          collection: "calm",
          collection_title: "Calm",
        },
        {
          id: "dore-paradise-lost-book-vi",
          title: "Paradise Lost, Book VI — Gustave Doré",
          attribution:
            "Paradise Lost, Book VI · Gustave Doré · 1866 · Book illustration (wood engraving) · Public domain",
          collection: "dore",
          collection_title: "Doré",
        },
        {
          id: "dore-raven",
          title: "The Raven — Gustave Doré",
          attribution: "The Raven · Gustave Doré · 1884 · Book illustration (engraving) · Public domain",
          collection: "dore",
          collection_title: "Doré",
        },
        {
          id: "dore-empyrean",
          title: "The Empyrean — Gustave Doré",
          attribution: "The Empyrean · Gustave Doré · 1868 · Book illustration (wood engraving) · Public domain",
          collection: "dore",
          collection_title: "Doré",
        },
      ],
    },
    backdropImages: {
      "martin-pandemonium": MARTIN_PANDEMONIUM,
      "friedrich-forest-moonlight": FRIEDRICH_FOREST_MOONLIGHT,
      "van-gogh-starry-night": VAN_GOGH_STARRY_NIGHT,
      "hokusai-great-wave": HOKUSAI_GREAT_WAVE,
      "friedrich-wanderer": FRIEDRICH_WANDERER,
      "dahl-dresden-moonlight": DAHL_DRESDEN_MOONLIGHT,
      "friedrich-monk-by-the-sea": FRIEDRICH_MONK_BY_THE_SEA,
      "monet-impression-sunrise": MONET_IMPRESSION_SUNRISE,
      "dore-paradise-lost-book-vi": DORE_PARADISE_LOST_BOOK_VI,
      "dore-raven": DORE_RAVEN,
      "dore-empyrean": DORE_EMPYREAN,
    },
    steps: [
      wait('[data-card="backdrop"]'),
      { selector: '[data-card="backdrop"] button[aria-pressed="true"]', action: "focus" },
    ],
    note: "The background picker grouped into Dark Art, Museum Icons, Calm and Doré, credited, one picked.",
  }),
  // What's New living-wallpapers (#45080): the Living wallpapers group as the app sends it
  // (BackdropCatalog+Page.swift: id shader:<name>, collection "shaders"), Currents picked. Their
  // thumbnails are stills the app renders with Metal at run time; the gallery has none, so each
  // tile draws its empty framed box.
  "living-wallpapers": variant("personalization", {
    focus: "personalization.background",
    options: { values: { "appearance.background": "shader:currents" } },
    host: {
      ...host,
      backdrops: [
        ["currents", "Currents", "Live · the pointer stirs the ink"],
        ["ripples", "Ripples", "Live · click to drop a ripple"],
        ["aurora", "Aurora", "Live · the light leans toward the pointer"],
        ["field", "Dot Field", "Live · the pointer pushes the dots aside"],
        ["aero", "Aero", "Live · bubbles drift aside from the pointer"],
      ].map(([id, title, attribution]) => ({
        id: `shader:${id}`,
        title: title!,
        attribution: attribution!,
        collection: "shaders",
        collection_title: "Living wallpapers",
      })),
    },
    steps: [
      wait('[data-card="backdrop"] [data-collection="shaders"]'),
      { selector: '[data-card="backdrop"] button[aria-pressed="true"]', action: "focus" },
    ],
    note: "Settings > Personalization > Background with Currents picked under Living wallpapers: Currents, Ripples, Aurora, Dot Field and Aero, each saying what the pointer does.",
  }),
  // Browse More Art (cx-t2x.8): a search across the open museum collections, sample answers.
  "art-browser": variant("appearance", {
    focus: "appearance.background",
    options: {
      values: { "appearance.background": "starryNight" },
      museumArt: [
        {
          key: "aic:1",
          title: "Sample harbor at night",
          artist: "Sample Painter",
          date: "1880",
          source: "Art Institute of Chicago",
          page: "",
        },
        {
          key: "cleveland:2",
          title: "Sample moonlit coast",
          artist: "Sample Etcher",
          date: "c. 1645",
          source: "Cleveland Museum of Art",
          page: "",
        },
        {
          key: "commons:3",
          title: "Sample starry field",
          artist: "",
          date: "1889",
          source: "Wikimedia Commons",
          page: "",
        },
      ],
    },
    host: {
      ...host,
      backdrops: [{ id: "starryNight", title: "Sample night", attribution: "Gallery sample thumbnail" }],
    },
    backdropImages: Object.fromEntries(
      ["starryNight", "museum/aic:1", "museum/cleveland:2", "museum/commons:3"].map((id, index) => [
        id,
        "data:image/svg+xml," +
          encodeURIComponent(
            `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="${["#253445", "#1d2a36", "#2b2336", "#20302a"][index]}"/><circle cx="235" cy="45" r="20" fill="#dfcf91"/></svg>`,
          ),
      ]),
    ),
    play: async (ctx) => {
      await ctx.click({ selector: '[data-card="backdrop"] button[aria-expanded]' });
      await ctx.type("night", { selector: '[data-card="art-browser"] input[type="search"]' });
      await ctx.click({ selector: '[data-card="art-browser"] button[type="submit"]' });
      await ctx.waitFor(() => ctx.document.querySelector('[data-card="art-browser"] .backdrop-grid'));
    },
    note: "Browse More Art: a search answered by three open collections, each work with its source.",
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
  "autocloud-off": variant("machines", {
    host: {
      ...host,
      machines: autoCloudMachines({ on: false, error: null }),
    },
    note: "A Remote machine not in AutoCloud: Off, where to turn it on, the always-on idle note (customers' default).",
    play: autoCloudPlay,
  }),
  "autocloud-accepting": variant("machines", {
    host: {
      ...host,
      machines: autoCloudMachines({
        on: true,
        error: null,
        accepting: true,
        owner_idle: true,
        policy: { teams: [], agents: [], hours: null },
        caps: macCaps,
      }),
    },
    note: "Enrolled and taking work while the owner is away: the owner-only policy and the Mac's capability badges.",
    play: autoCloudPlay,
  }),
  "autocloud-owner-active": variant("machines", {
    host: {
      ...host,
      machines: autoCloudMachines({
        on: true,
        error: null,
        accepting: false,
        owner_idle: false,
        policy: {
          teams: ["Sample team"],
          agents: ["claude", "codex"],
          hours: { from: 22, to: 7 },
        },
        caps: macCaps,
      }),
    },
    note: "Enrolled with a team, agents and overnight hours, waiting because the owner is using it.",
    play: autoCloudPlay,
  }),
  "autocloud-error": variant("machines", {
    host: {
      ...host,
      machines: autoCloudMachines({
        on: false,
        error: "Studio Mac did not answer.",
      }),
    },
    note: "The machine's AutoCloud report could not be read: its error under the idle note.",
    play: autoCloudPlay,
  }),
  "machines-row-shape": variant("accounts", {
    host: { ...host, machines: rowShapeMachines },
    options: { values: { "appearance.machineColors": { "research build machine": "#7F5FA8" } } },
    note: "One machine row with its color control and the Dedicated agent machine line below.",
    play: async (ctx) => {
      const card = ctx.find({ selector: '[data-card="machines"]' });
      card.setAttribute("data-gallery-capture", "");
      card.scrollIntoView({ block: "center" });
    },
  }),
  "cloud-environments-row-shape": variant("cloud", {
    environments: rowShapeEnvironments,
    note: "One failed Cloud Environment row with status, repository, error log and actions.",
    play: async (ctx) => {
      const card = ctx.find({ selector: '[data-card="cloudEnvironments"]' });
      card.setAttribute("data-gallery-capture", "");
      card.scrollIntoView({ block: "center" });
    },
  }),
  "worktree-setup": variant("agents", {
    note: "Settings > Agents > Worktree Setup: the project's scripts and files to copy, what the repository says under each.",
    play: async (ctx) => {
      const card = ctx.find({ selector: '[data-card="worktreeSetup"]' });
      card.setAttribute("data-gallery-capture", "");
      card.scrollIntoView({ block: "center" });
    },
  }),
  "worktree-setup-edited": variant("agents", {
    note: "Edited: a replaced setup script, the run script turned off (empty), with Use Repository's under each, Save lit.",
    steps: [
      wait('[data-worktree-field="setup"] textarea:not([disabled])'),
      input('[data-worktree-field="setup"] textarea', "bun install --frozen-lockfile"),
      input('[data-worktree-field="run"] textarea', "x"),
      input('[data-worktree-field="run"] textarea', ""),
    ],
    play: async (ctx) => {
      const card = ctx.find({ selector: '[data-card="worktreeSetup"]' });
      card.setAttribute("data-gallery-capture", "");
      card.scrollIntoView({ block: "center" });
    },
  }),
  "extensions-edited": variant("extensions", {
    note: "Settings > Extensions: an extension's declared settings (switch, choice, text, number), Compact rows just turned on.",
    steps: [
      wait('[data-extension-setting="compact"] [role="switch"]'),
      click('[data-extension-setting="compact"] [role="switch"]'),
    ],
    play: async (ctx) => {
      const card = ctx.find({ selector: '[data-card="extensions"]' });
      card.setAttribute("data-gallery-capture", "");
      card.scrollIntoView({ block: "center" });
    },
  }),
  "profile-editor": variant("browser", {
    steps: [
      click('[data-profile="p-work"] .host-toggle'),
      wait(".host-form"),
      { selector: ".host-form input", action: "select" },
    ],
  }),
  "clear-refused": variant("browser", {
    options: { failing: { "cmux.app.action.run": "cmux.browser.clear_refused" } },
    note: "Clear Browsing Data refusal, scrolled into view for the captured row.",
    steps: [click('[data-profile="p-work"] .host-toggle'), wait(".host-form"), click("[data-clear]")],
    play: async (ctx) => {
      await ctx.waitFor(() => ctx.document.querySelector("[data-clear-error]"));
      const field = ctx.find({ selector: "[data-clear-browsing-data]" });
      field.setAttribute("data-gallery-capture", "");
      field.scrollIntoView({ block: "center" });
    },
  }),
  // Settings > Updates with the Update Channel menu open: the menu hugs its rows and lines up with
  // its trigger, and Check Every reads in hours (settings-select-menu-browser.test.ts measures it).
  "updates-channel-open": variant("updates", {
    steps: [click(`${row("updates.channel")} .ui-select-button`), wait(".ui-select-popup .ui-menu-item")],
    note: "Settings > Updates, the Update Channel menu open over the Check Every row.",
  }),
  // What's New update-when-idle (#47272): Update When Idle turned on, its idle minutes below it.
  "update-when-idle": variant("updates", {
    focus: "updates.installWhenIdle",
    options: { values: { "updates.installWhenIdle": true, "updates.installWhenIdleMinutes": 15 } },
    note: "Settings > Updates with Update When Idle on: a downloaded update installs after 15 idle minutes.",
  }),
  // What's New needs-you-glow (#46884): Needs You Look set to Glow instead of the default Badge.
  "needs-you-glow": variant("notifications", {
    focus: "notifications.attention.mark",
    options: { values: { "notifications.attention.mark": "glow" } },
    note: "Settings > Notifications with Needs You Look set to Glow: a waiting tab or sidebar row glows in place of its badge.",
  }),
  // What's New custom-notification-sound (https://github.com/manaflow-ai/cmux/issues/55219): a sound
  // of the person's own picked with Custom Sound… (the menu's last item) and a Sound Duration.
  "custom-notification-sound": variant("notifications", {
    focus: "notifications.sounds.maxSeconds",
    options: {
      values: { "notifications.sound": "My Chime", "notifications.sounds.maxSeconds": 3 },
      domains: { ...mockDomains, sounds: [...mockDomains.sounds, "My Chime"] },
    },
    note: "Sound set to a custom file (My Chime) and Sound Duration at 3 s.",
  }),
  // What's New agent-blocked-notification: Agent Blocked delivery set to Banner (default Off).
  "agent-blocked-banner": variant("notifications", {
    focus: "notifications.delivery.blocked",
    options: { values: { "notifications.delivery.blocked": "banner" } },
    note: "Settings > Notifications with Agent Blocked set to Banner: an agent that turns Blocked posts a banner.",
  }),
  "search-results": variant("general", { steps: [input("[data-settings-search]", "browser")] }),
  "search-results-font": variant("general", { steps: [input("[data-settings-search]", "font")] }),
  "search-results-theme": variant("general", {
    allThemes: true,
    steps: [input("[data-settings-search]", "theme")],
    note: "Theme rows in search results use the Theme section's picker and accent popup.",
  }),
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
  "theme-picker-starred": variant("theme", {
    allThemes: true,
    options: {
      values: {
        "appearance.theme": "Rose Pine",
        "appearance.favoriteThemes": ["Rose Pine", "Catppuccin Mocha", "Tokyo Night"],
        "appearance.rotateFavoriteThemes": "daily",
      },
    },
    steps: [click("[data-theme-picker]"), wait(".theme-popover [data-starred-row]")],
    note: "Starred themes first under Starred, then All Themes; each starred row's star is lit. Rotate Starred Themes shows in the card.",
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
    note: "An app theme apart from the terminal theme (appearance.appTheme); the one Match System Appearance switch sets both.",
  }),
  "theme-app-light-dark": variant("theme", {
    allThemes: true,
    options: {
      values: {
        "appearance.theme": "light:Catppuccin Latte,dark:Catppuccin Mocha",
        "appearance.appTheme": "light:Rose Pine Dawn,dark:Rose Pine",
        "appearance.accent": "magenta",
      },
    },
    note: "One Theme card: one Match System Appearance for the terminal and the app theme together, then the accent.",
  }),
  "theme-long-name": variant("theme", {
    allThemes: true,
    options: {
      values: { "appearance.theme": "Builtin Pastel Dark Solarized Tango Long Name", "appearance.accent": "blue" },
    },
    note: "A long theme name ellipsizes; every popup keeps its one width.",
  }),
  "theme-accent": variant("theme", {
    allThemes: true,
    options: { values: { "appearance.theme": "Dracula", "appearance.accent": "theme" } },
    steps: [click("[data-accent-picker]"), wait("[data-accent-option]")],
    note: "The accent swatch popup: each choice's color on the app theme, the check on the right.",
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
  "theme-file-save": variant("theme", {
    allThemes: true,
    options: { values: { "appearance.theme": "Dracula" } },
    steps: [
      wait('[data-theme-files-action="save"]:not([disabled])'),
      click('[data-theme-files-action="save"]'),
      wait('[data-theme-files-prompt="name"]'),
    ],
    note: "Save as Ghostty Theme asks for a name inline, starting from the previewed theme's.",
  }),
  "theme-file-replace": variant("theme", {
    allThemes: true,
    options: {
      values: { "appearance.theme": "Dracula" },
      importable: { ...mockThemeColors[0]!, name: "Dracula Night" },
    },
    steps: [
      wait('[data-theme-files-action="import"]:not([disabled])'),
      click('[data-theme-files-action="import"]'),
      wait('[data-theme-files-action="import"]:not([disabled])'),
      click('[data-theme-files-action="import"]'),
      wait('[data-theme-files-prompt="replace"]'),
    ],
    note: "Importing a file whose theme name is already in the themes folder asks inline before replacing it.",
  }),
  "font-picker": variant("terminal", {
    steps: [click(`${row("terminal.fontFamily")} .domain-button`), wait(".domain-panel")],
  }),
  "domains-unavailable": variant("appearance", { options: { domains: null } }),
  "theme-text-fallback": variant("theme", { options: { domains: null } }),
  "invalid-search-template": variant("browser", {
    focus: "browser.customSearchEngine.search",
    options: { values: { "browser.customSearchEngine.search": "https://search.example.test/" } },
  }),
  "invalid-color": variant("tabs", {
    focus: "focusRing.color",
    steps: [
      input(`${row("focusRing.color")} .hex`, "not-a-color"),
      { selector: `${row("focusRing.color")} .hex`, action: "enter" },
      wait(`${row("focusRing.color")} [role="alert"]`),
    ],
  }),
  "invalid-host": variant("browser", {
    focus: "browser.hibernationExclusions",
    // Scoped to the row: the Browser page has other token fields above it (browser.siteEngines).
    steps: [
      input(`${row("browser.hibernationExclusions")} .token-input`, "bad host / path"),
      { selector: `${row("browser.hibernationExclusions")} .token-input`, action: "enter" },
      wait(`${row("browser.hibernationExclusions")} .host-list [role=alert]`),
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
  // Settings > Computer Use (ComputerUseCard): the default (Full access, one grant missing, the
  // engine's deny list), every grant given with saved approvals, Look only, Off, a failed worker,
  // a policy lock and a short custom deny list. Focusing the mode picker scrolls the card into view.
  "computer-use-default": variant("computerUse", {
    host: { ...host, computer_use: computerUseReady },
    steps: [wait('[data-card="computer-use"] [data-mode]'), focusComputerUse],
    note: "Full access by default: status (engine, Accessibility allowed, Screen Recording with Grant Access, worker running), the five modes, the denied apps.",
  }),
  "computer-use-granted": variant("computerUse", {
    host: {
      ...host,
      computer_use: {
        ...computerUseReady,
        screen_recording: true,
        approvals: [
          { app_id: "com.apple.Safari", name: "Safari", decision: "always" },
          { app_id: "com.figma.Desktop", name: "Figma", decision: "always" },
          { app_id: "com.apple.MobileSMS", name: "Messages", decision: "never" },
        ],
      },
    },
    options: { values: { "computerUse.mode": "approvedApps" } },
    steps: [wait('[data-card="computer-use"] [data-approval]'), focusApprovals],
    note: "Approved apps with every grant given: Saved Approvals lists Always Allow and Never, each with Forget.",
  }),
  "computer-use-look-only": variant("computerUse", {
    host: { ...host, computer_use: { ...computerUseReady, screen_recording: true } },
    options: { values: { "computerUse.mode": "lookOnly" } },
    steps: [wait('[data-card="computer-use"] [data-mode="lookOnly"][data-checked]'), focusComputerUse],
    note: "Look only: screenshots and reading, no clicks or typing.",
  }),
  "computer-use-off": variant("computerUse", {
    host: { ...host, computer_use: { ...computerUseReady, phase: "off", worker: { state: "stopped" } } },
    options: { values: { "computerUse.mode": "off" } },
    steps: [wait('[data-card="computer-use"] [data-mode="off"][data-checked]'), focusComputerUse],
    note: "Off: the status says pick a mode to turn it on; no grant or worker rows.",
  }),
  "computer-use-failed": variant("computerUse", {
    host: { ...host, computer_use: { phase: "failed", accessibility: null, screen_recording: null, helper: null } },
    steps: [
      wait('[data-card="computer-use"]'),
      { selector: '[data-card="computer-use"] [data-action="palette.computerUse.restart"]', action: "focus" },
    ],
    note: "The worker did not respond: Restart is the only status action.",
  }),
  "computer-use-policy-locked": variant("computerUse", {
    host: {
      ...host,
      computer_use: { phase: "disabled_by_policy", accessibility: null, screen_recording: null, helper: null },
    },
    steps: [wait('[data-card="computer-use"][data-phase="disabled_by_policy"]'), focusComputerUse],
    note: "A managed policy turned Computer Use off on this Mac: no Grant or Restart; the rows still show.",
  }),
  "computer-use-custom-deny-list": variant("computerUse", {
    host: { ...host, computer_use: { ...computerUseReady, screen_recording: true } },
    options: { values: { "computerUse.deniedApps": ["com.apple.Terminal", "com.1password.*", "name:Notes"] } },
    steps: [wait('[data-card="computer-use"] [data-denied-app="name:Notes"]'), focusDenied],
    note: "A short custom deny list: Restore Defaults is enabled; Add a Running App offers Safari, Notes and Figma.",
  }),
  // Settings > Agents > Agent Harnesses (BRING-YOUR-OWN-HARNESS).
  "agents-harnesses": variant("agents", {
    steps: [wait("[data-agent-harness]")],
    note: "Every harness acpmux knows: kind, source, a probe problem; Check and Remove on user profiles.",
  }),
  "agents-harness-update-ready": variant("agents", {
    harnesses: {
      loading: false,
      problem: null,
      harnesses: [
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.3.1",
          latest: "0.4.0",
          outdated: true,
          auth: "signedIn",
          update: { command: "npm install -g @openai/codex@latest", elevated: false },
          ownerUpdate: true,
        },
        {
          id: "claude",
          name: null,
          kind: "claude-stdio",
          source: "path",
          problem: null,
          version: "2.0.5",
          latest: "2.0.9",
          outdated: true,
          auth: "signedIn",
          update: { command: "sudo npm install -g @anthropic-ai/claude-code@latest", elevated: true },
          ownerUpdate: false,
        },
        {
          id: "github-copilot-cli",
          name: "GitHub Copilot",
          kind: "acp",
          source: "path",
          problem: null,
          version: "1.4.0",
          latest: "1.4.0",
          outdated: false,
          auth: "signedIn",
          update: null,
        },
      ],
    },
    options: { values: { "labs.previewFeatures": true } },
    steps: [
      wait('[data-harness-update-card="codex"]'),
      { selector: '[data-harness-update-card="codex"] [data-harness-action="updateCard"]', action: "focus" },
    ],
    note: "Harness health with an in-app Codex update and a separate manual command for an elevated Claude Code install.",
  }),
  "agents-harness-sign-in-expired": variant("agents", {
    harnesses: {
      loading: false,
      problem: null,
      harnesses: [
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.4.0",
          latest: "0.4.0",
          outdated: false,
          auth: "expired",
          update: null,
        },
        {
          id: "claude",
          name: null,
          kind: "claude-stdio",
          source: "path",
          problem: null,
          version: "2.0.9",
          latest: "2.0.9",
          outdated: false,
          auth: "signedIn",
          update: null,
        },
      ],
    },
    steps: [
      wait('[data-harness="codex"]'),
      // Scrolls the Codex row into view; the control exists before and after the change.
      { selector: '[data-harness="codex"] [data-harness-action="check"]', action: "focus" },
    ],
    note: "Codex's sign-in expired: Agents gets its badge and the row says Signed out, as for a signed-out harness.",
  }),
  "agents-harness-update-manual": variant("agents", {
    harnesses: {
      loading: false,
      problem: null,
      harnesses: [
        {
          id: "claude",
          name: null,
          kind: "claude-stdio",
          source: "path",
          problem: null,
          version: "2.0.5",
          latest: "2.0.9",
          outdated: true,
          auth: "signedIn",
          update: { command: "sudo npm install -g @anthropic-ai/claude-code@latest", elevated: true },
          ownerUpdate: false,
        },
      ],
    },
    options: { values: { "labs.previewFeatures": true } },
    steps: [
      wait('[data-harness-update-card="claude"]'),
      { selector: "[data-harness-update-command]", action: "focus" },
    ],
    note: "An outdated harness whose installer needs admin rights: the card gives the exact manual command and no unsafe one-click action.",
  }),
  "agents-harness-update-failed": variant("agents", {
    harnesses: {
      loading: false,
      problem: null,
      harnesses: [
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.3.1",
          latest: "0.4.0",
          outdated: true,
          auth: "signedIn",
          update: { command: "npm install -g @openai/codex@latest", elevated: false },
          ownerUpdate: true,
        },
      ],
      jobs: [
        {
          machine: "sample-machine",
          session: "sample-session",
          cli: "codex",
          profiles: ["codex"],
          terminal: "sample-terminal",
          state: "exited",
          exit_code: 23,
        },
      ],
    },
    options: { values: { "labs.previewFeatures": true } },
    steps: [
      wait('[data-harness-update-card="codex"]'),
      { selector: '[data-agent-update-job="exited"]', action: "focus" },
    ],
    note: "An update that finished with an error: the receipt stays visible while the card keeps a retryable Update action.",
  }),
  // Settings > Chief > Chiefs (u2586): every Chief; a row opens the same editor as Home.
  "chief-chiefs": variant("chief", {
    steps: [wait('[data-card="chiefs"] [data-chief]')],
    note: "Chiefs: picture, name, role, backend and a Locked badge; New Chief opens the editor.",
  }),
  "chief-editor": variant("chief", {
    steps: [click('[data-chief="agent_release"]'), wait('[data-card="chiefs"] section.chief-editor')],
    note: "A Chief row opens its editor in the card: backend, lock and history, never a dialog.",
  }),
  // Settings > Chief's look with the pet off (the default): the Chief's character stays checked.
  "chief-pet-off": variant("chief", {
    focus: "home.chiefPetMascot",
    note: "Chief Pet, pet off: the chosen character (Orb) is checked; Show Pet floats it.",
  }),
  // Settings > Chief's look with Mochi, the first animated set, picked and the pet shown.
  "chief-pet-mochi": variant("chief", {
    focus: "home.chiefPetMascot",
    options: { values: { "home.chiefPetMascot": "mochi", "home.chiefPetEnabled": true } },
    note: "Chief Pet with Mochi picked: the preview and the checked card show its static frame.",
  }),
  // Settings > Chief > Look's foot: the chat's Bubble Style, the row a search for it lands on.
  "chief-look-bubbles": variant("chief", {
    focus: "home.chiefBubbleStyle",
    note: "Look: the pet, the characters, then Bubble Style at the card's foot (no Chief Chat card of its own).",
  }),
  "agents-add-custom": variant("agents", {
    focus: "agents.add",
    steps: [wait("[data-agents-custom]")],
    note: "Add ACP Agent… (palette, the model picker's +): the custom command form.",
  }),
  "agents-add-registry": variant("agents", {
    focus: "agents.registry",
    steps: [wait("[data-registry-agent]")],
    note: "Add Agent from ACP Registry…: one click per agent; Added when it is a harness, disabled when it cannot start here.",
  }),
  "agents-registry-overflow": variant("agents", {
    focus: "agents.registry",
    agents: {
      registry: {
        agents: Array.from({ length: 40 }, (_, index) => ({
          id: `sample-agent-${index}`,
          name: `Sample agent ${index}`,
          description: "Sample coding agent",
          version: "1.0.0",
          launch: "path" as const,
        })),
      },
    },
    steps: [wait("[data-registry-agent]")],
    note: "Forty ACP Registry agents in the capped add-agent list.",
  }),
  // Settings > Agents > Add > Endpoint (plan api-and-open-models gaps 3 and 6): an open-weight model
  // or your own endpoint, picked from a preset.
  "agents-endpoint-empty": variant("agents", {
    focus: "agents.endpoint",
    steps: [wait("[data-agents-endpoint]")],
    play: showEndpoint(),
    note: "Endpoint tab as it opens: the model server on this Mac preset, its URL filled, no key field, no models yet (Check and Add waits for one).",
  }),
  "agents-endpoint-gateway-filled": variant("agents", {
    focus: "agents.endpoint",
    steps: [
      wait("[data-agents-endpoint]"),
      { selector: "[data-agents-endpoint] select", action: "change", value: "gateway" },
      input('[data-endpoint-field="baseUrl"] input', "https://gateway.example.com"),
      input('[data-endpoint-field="models"] input', "model-large, model-medium, model-small"),
      input('[data-endpoint-field="apiKey"] input', "sample-key"),
    ],
    play: showEndpoint(),
    note: "The Anthropic-compatible gateway preset filled in: it runs Claude Code, three models fill its Opus, Sonnet and Haiku slots, and the key field says where the key goes.",
  }),
  "agents-endpoint-fetched": variant("agents", {
    focus: "agents.endpoint",
    steps: [
      wait("[data-agents-endpoint]"),
      click('[data-endpoint-field="models"] button'),
      wait("[data-endpoint-fetched]"),
    ],
    play: showEndpoint("[data-endpoint-fetched]"),
    note: "Fetch Models on the local model server: the endpoint's three models fill the list and the line under it says how many it found.",
  }),
  "agents-endpoint-doctor-failed": variant("agents", {
    focus: "agents.endpoint",
    endpoint: {
      doctor: {
        ok: false,
        steps: [
          { name: "launch", ok: true },
          {
            name: "prompt",
            ok: false,
            detail: "401 Unauthorized",
            fix: "check the key: the endpoint refused it. Store it again with `cmux harness secret set hosted-models CMUX_BYO_API_KEY`",
          },
        ],
      },
    },
    steps: [
      wait("[data-agents-endpoint]"),
      { selector: "[data-agents-endpoint] select", action: "change", value: "hosted" },
      input('[data-endpoint-field="baseUrl"] input', "https://api.example.com/v1"),
      input('[data-endpoint-field="models"] input', "model-large"),
      input('[data-endpoint-field="apiKey"] input', "sample-key"),
      click("[data-endpoint-add]"),
      wait('[data-endpoint-status="failed"]'),
    ],
    play: showEndpoint('[data-endpoint-status="failed"]'),
    note: "Check and Add on a hosted provider whose key is refused: the failing step, its detail and fix; the form stays open and the key field is empty again.",
  }),
  "agents-endpoint-insecure": variant("agents", {
    focus: "agents.endpoint",
    steps: [
      wait("[data-agents-endpoint]"),
      { selector: "[data-agents-endpoint] select", action: "change", value: "team-server" },
      input('[data-endpoint-field="baseUrl"] input', "http://inference.example.com/v1"),
    ],
    play: showEndpoint(),
    note: "Your team's server over plain http to another machine: the line under the URL asks for https, and Check and Add waits.",
  }),
  "agents-stable-check-idle": variant("agents", {
    note: "Check actions at rest, reserving their translated Checking label width.",
    agents: { doctor: {} },
  }),
  "agents-stable-check-busy": variant("agents", {
    note: "The same Check actions while diagnostics run; button widths stay fixed.",
    agents: { doctor: { "acme-agent": { running: true } } },
  }),
  "agents-stable-added": variant("agents", {
    focus: "agents.registry",
    steps: [wait('[data-registry-agent="goose"]'), click('[data-registry-agent="goose"] button')],
    note: "The registry action after Add becomes Added, with its original width preserved.",
  }),
  "agents-doctor": variant("agents", {
    steps: [click('[data-agent-harness="acme-agent"] button'), wait("[data-agent-doctor]")],
    note: "Check: the doctor's steps inline, a failed step with its fix, later steps skipped.",
  }),
  "agents-removed": variant("agents", {
    steps: [click('[data-agent-harness="acme-agent"] button:last-of-type'), wait("output")],
    note: "Remove moves the profile aside: Removed with Undo.",
  }),
  "agents-cli": variant("agents", {
    agents: { manages: false },
    steps: [wait("[data-agents-cli]")],
    note: "An acpmux without the operations: the CLI commands, no Add, Check or Remove.",
  }),
  "agents-empty": variant("agents", { agents: { harnesses: [] }, note: "No harness: the empty line." }),
  "accounts-empty": variant("accounts", { accounts: accounts({}, { groups: [], cmux: cmuxSignedOut }) }),
  "accounts-sign-in-in-place": variant("accounts", {
    accounts: accounts({}, { signInAccounts: ACCOUNT_LISTS.signedOut }),
    note: "A host that signs in in place: GitHub, ChatGPT and Claude accounts; Add account or Sign in shows the code in the row (variant A).",
  }),
  "accounts-cmux-signing-in": variant("accounts", {
    accounts: accounts({}, { cmux: cmuxSigningIn }),
    note: "Sign In to cmux in progress: open it in the browser, or cancel.",
  }),
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
  "accounts-team-roles": variant("accounts", {
    accounts: withTeams(),
    note: "Teams: each team with your role (Admin or Member), the active one marked, and New Team.",
  }),
  "accounts-team-roles-unknown": variant("accounts", {
    accounts: withTeams((teams) => (teams.rolesUnknown = true)),
    note: "Only the sign-in service answered: roles read Role unknown.",
  }),
  "accounts-team-admin": variant("accounts", {
    accounts: withTeams((teams) => teams.run({ action: "team.details", team: "team-personal" })),
    note: "Details as an admin: your role, member count and plan, members (You marked), pending invitations, Rename and Delete.",
  }),
  "accounts-team-member": variant("accounts", {
    accounts: withTeams((teams) => teams.run({ action: "team.details", team: "team-acme" })),
    note: "Details as a member: read-only, no invitations, no Rename or Delete.",
  }),
  "accounts-team-rename": variant("accounts", {
    accounts: withTeams((teams) => {
      teams.run({ action: "team.details", team: "team-personal" });
      teams.run({ action: "team.rename", team: "team-personal" });
    }),
    note: "Rename Team: the field starts at the current name, up to 64 characters.",
  }),
  "accounts-team-delete": variant("accounts", {
    accounts: withTeams((teams) => {
      teams.run({ action: "team.details", team: "team-personal" });
      teams.run({ action: "team.delete", team: "team-personal" });
    }),
    note: "Delete Team asks first and names the team.",
  }),
  "accounts-team-delete-blocked": variant("accounts", {
    accounts: withTeams((teams) => {
      teams.teams = teams.teams.map((team) => ({ ...team, subscribed: team.id === "team-personal" }));
      teams.run({ action: "team.details", team: "team-personal" });
      teams.run({ action: "team.delete", team: "team-personal" });
      teams.run({ action: "team.confirmDelete", team: "team-personal" });
    }),
    note: "A team with an active subscription cannot be deleted: the confirmation says why.",
  }),
  "accounts-team-invited": variant("accounts", {
    accounts: withTeams((teams) => {
      teams.received = [
        {
          id: "inv-1",
          teamId: "team-research",
          team: "Sample team 3",
          invitedBy: "Sample Person",
          email: "you@example.com",
        },
        { id: "inv-2", teamId: "team-design", team: "Sample team 4", invitedBy: null, email: "you@example.com" },
      ];
    }),
    note: "Invitations to You: teams that invited one of your verified emails, each with Join Team and Decline.",
  }),
  "accounts-team-joined": variant("accounts", {
    accounts: withTeams((teams) => {
      teams.received = [
        {
          id: "inv-1",
          teamId: "team-research",
          team: "Sample team 3",
          invitedBy: "Sample Person",
          email: "you@example.com",
        },
      ];
      teams.run({ action: "team.accept", team: "inv-1" });
    }),
    note: "Join Team: the team joins your list as a member and becomes your active team.",
  }),
  "accounts-team-create": variant("accounts", {
    accounts: withTeams((teams) => teams.run({ action: "team.new" })),
    note: "New Team: you become its admin and it becomes your active team.",
  }),
  "accounts-team-deleted": variant("accounts", {
    accounts: withTeams((teams) => {
      teams.run({ action: "team.details", team: "team-personal" });
      teams.run({ action: "team.delete", team: "team-personal" });
      teams.run({ action: "team.confirmDelete", team: "team-personal" });
    }),
    note: "After deleting the active team, the other team is active and the notice says so.",
  }),
  "accounts-teams": variant("accounts", {
    accounts: accounts(
      {},
      {
        teams: {
          title: "Active Team",
          help: "Cloud machines, CodeRouter and phone access use this team.",
          options: [
            { id: "sample-team-1", name: "Sample team", active: true },
            { id: "sample-team-2", name: "Another sample team", active: false },
          ],
          disabled: false,
          note: null,
          error: null,
        },
        teamList: null,
      },
    ),
    note: "The active team switcher: one row with a pop-up menu of the teams, the active one checked.",
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

// One scroller (cx-jh7kq): a select opened near the bottom edge, then the content scrolled under
// it. The pop-up stays at its row (or waits hidden while the row is out of view); the document
// never scrolls, so the column never slides up under the window.
// sidebar.sectionLook is a More Options row on Sidebar: the focus opens its card's More Options.
variants["play-select-scroll"] = variant("sidebar", {
  focus: "sidebar.sectionLook",
  note: "A select opened near the bottom, then the content scrolled: one scroller, the pop-up stays at its row.",
  play: async (ctx) => {
    const content = ctx.find({ selector: ".content" });
    const control = `${row("sidebar.sectionLook")} .ui-select-button`;
    const bottom = ctx.find({ selector: control }).getBoundingClientRect().bottom;
    // Near the bottom of what shows: above the Appearance bar that sits over the content's foot.
    const floor =
      ctx.document.querySelector(".appearance-bar")?.getBoundingClientRect().top ??
      content.getBoundingClientRect().bottom;
    await ctx.scroll({ selector: ".content" }, content.scrollTop + bottom - (floor - 40));
    await ctx.click({ selector: control });
    await ctx.waitFor(() => ctx.document.querySelector(".ui-select-popup"));
    await ctx.scroll({ selector: ".content" }, content.scrollTop - 160);
  },
});
variants["play-section-change"] = variant("accounts", {
  note: "Changing category: the column fades in; the sidebar never moves.",
  play: async (ctx) => {
    await ctx.click({ selector: '[data-section-link="advanced"]' });
    await ctx.waitFor(() => ctx.document.querySelector('[data-section="advanced"]'));
  },
});

const githubConnection = {
  title: "GitHub",
  detail: "Connected",
  busy: false,
  connect: "Connect GitHub",
  disconnect: "Disconnect",
  reconfigure: "Reconfigure",
  confirm: "Disconnect GitHub? Agents will lose access through this connection.",
  cancel: "Cancel",
  refresh: "Refresh",
  canConnect: false,
  connections: [
    {
      id: "sample-github",
      canDisconnect: true,
      canReconfigure: true,
      account: "sample-team",
      status: "Connected",
      permissions: ["contents:write", "pull_requests:write"],
    },
  ],
};
for (const treatment of ["balanced", "compact", "inline"]) {
  variants[`github-connect-${treatment}`] = variant("accounts", {
    accounts: accounts({}, { github: githubConnection }),
    note: `GitHub App connection: ${treatment} treatment. Balanced uses the existing Accounts spacing.`,
    play: async (ctx) => {
      await ctx.waitFor(() => ctx.document.querySelector('[data-card="github-connection"]'));
      const card = ctx.document.querySelector<HTMLElement>('[data-card="github-connection"]')!;
      card.scrollIntoView({ block: "center" });
      if (treatment !== "balanced") {
        const style = ctx.document.createElement("style");
        style.textContent =
          treatment === "compact"
            ? '[data-card="github-connection"] .row { padding-block: 4px; } [data-card="github-connection"] .accounts-body { margin-top: 4px; }'
            : '[data-card="github-connection"] .row { display: flex; align-items: center; gap: 16px; } [data-card="github-connection"] .accounts-body { margin: 0; padding: 0; }';
        card.append(style);
      }
    },
  });
}
variants["github-connect-comparison"] = variant("accounts", {
  accounts: accounts({}, { github: githubConnection }),
});
variants["github-connect-empty"] = variant("accounts", {
  accounts: accounts(
    {},
    {
      github: {
        ...githubConnection,
        connections: [],
        canConnect: true,
        detail: "Connect the cmux GitHub App. Choose repositories and review permissions in GitHub.",
      },
    },
  ),
});
// Settings > Accounts > Team agent keys (TeamAgentKeysCard.tsx): admin, member, signed out,
// personal team and a conflict refusal, each with the app's copy (mockAgentKeys.ts).
for (const [state, agentKeys] of Object.entries(mockAgentKeys)) {
  // Variant names are lower kebab case: the mock's `signedOut` is `signed-out` here.
  const name = state.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
  variants[`team-agent-keys-${name}`] = variant("accounts", {
    accounts: accounts({}, { agentKeys }),
    play: async (ctx) => {
      await ctx.waitFor(() => ctx.document.querySelector('[data-card="team-agent-keys"]'));
      ctx.document.querySelector<HTMLElement>('[data-card="team-agent-keys"]')!.scrollIntoView({ block: "center" });
    },
  });
}
variants["github-connect-pending"] = variant("accounts", {
  accounts: accounts(
    {},
    {
      github: {
        ...githubConnection,
        connections: [],
        canConnect: true,
        detail: "Finish connecting in your browser, then refresh.",
      },
    },
  ),
});
variants["github-connect-confirm"] = variant("accounts", {
  accounts: accounts({}, { github: githubConnection }),
  play: async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector('[data-github-action="disconnect"]'));
    await ctx.click({ selector: '[data-github-action="disconnect"]' });
    await ctx.waitFor(() => ctx.document.querySelector('[data-card="github-connection"] output'));
  },
});

const screenSharingDevices = mockDevicesState();
const localFirstUseDevices = {
  ...screenSharingDevices,
  thisDevice: screenSharingDevices.thisDevice ? { ...screenSharingDevices.thisDevice, sharesText: null } : null,
  sharing: screenSharingDevices.sharing
    ? {
        ...screenSharingDevices.sharing,
        on: false,
        permissions: screenSharingDevices.sharing.permissions.map((permission) => ({ ...permission, granted: false })),
      }
    : null,
};
variants["devices-screen-sharing-local"] = variant("devices", {
  devices: localFirstUseDevices,
  note: "First use: Share is visible while Mac Screen is off and Screen Recording plus Accessibility still need permission.",
});
variants["devices-screen-sharing-remote"] = variant("devices", {
  devices: {
    ...localFirstUseDevices,
    others: localFirstUseDevices.others.map((device) =>
      device.id === "dev-macbook"
        ? {
            ...device,
            name: "Research MacBook Pro — Office Display",
            online: true,
            presence: "Online",
            sharesText: "Shares Mac Screen",
            screenAction: { kind: "view", title: "View screen", disabled: false },
          }
        : device,
    ),
  },
  note: "An online Mac has a direct View screen action; phones retain their access picker.",
});
variants["devices-screen-sharing-offline"] = variant("devices", {
  devices: screenSharingDevices,
  note: "An offline Mac keeps its disabled View screen affordance while its name and captions remain readable.",
});

for (const { name, scale } of pageDensities) {
  variants[`density-${name}`] = variant("appearance", {
    note: `${name}: scaled content, controls and navigation, with centered disclosure content and concentric corners on hover.`,
    play: async (ctx) => {
      await pageDensityPlay(scale)(ctx);
      await ctx.hover({ selector: ".content .more-options" });
    },
  });
  variants[`density-${name}-disclosure-open`] = variant("appearance", {
    note: `${name}: centered disclosure content with its rows open.`,
    play: async (ctx) => {
      await pageDensityPlay(scale)(ctx);
      await ctx.click({ selector: ".content .more-options" });
      await ctx.hover({ selector: ".content .more-options" });
    },
  });
}

export default settingsPageEntry({
  id: "pages.settings",
  anchors: [{ selector: "[data-settings-search]" }, { selector: '[data-section-link="general"]' }],
  title: "Settings",
  area: "Settings",
  height: 760,
  // Full-page surface: window mode defaults to `one`; standalone widths include tight panes.
  widths: { narrow: 480, normal: 1000, wide: 1440 },
  covers: [
    "page:cmux.settings",
    "pages/shared/pageDensity.css",
    "pages/settings/look.css",
    "pages/settings/refined.css",
    "pages/settings/layout.css",
    "pages/settings/styles.css",
    "pages/settings/components/AccentPicker.tsx",
    "pages/settings/components/AccountsSection.tsx",
    "pages/settings/components/AccountSignInSection.tsx",
    "pages/settings/components/AccountsTeams.tsx",
    "pages/settings/components/AgentHarnesses.tsx",
    "pages/settings/components/AgentIntegrations.tsx",
    "pages/settings/components/AgentToolsCard.tsx",
    "pages/settings/components/McpServersCard.tsx",
    "pages/settings/components/ComputerUseCard.tsx",
    "pages/settings/components/DevicesCard.tsx",
    "pages/settings/components/ChiefsCard.tsx#ChiefsCard",
    "pages/settings/components/HarnessesCard.tsx",
    "pages/settings/components/AgentHarnesses.tsx#AgentHarnesses",
    "pages/settings/components/ActionRow.tsx",
    "pages/settings/components/ArtBrowser.tsx",
    "pages/settings/components/BackdropLink.tsx",
    "pages/settings/components/BackdropScope.tsx",
    "pages/settings/components/ChiefPetCard.tsx",
    "pages/settings/components/ChannelsCard.tsx",
    "pages/settings/components/ImportSuggestionsCard.tsx",
    "pages/settings/components/VoiceInputCard.tsx",
    "pages/settings/components/FontPicker.tsx",
    "pages/settings/components/GhosttyDiagnostics.tsx",
    "pages/settings/components/GroupList.tsx",
    "pages/settings/components/Highlight.tsx",
    "pages/settings/components/HostCards.tsx",
    "pages/settings/components/HostSections.tsx",
    "pages/settings/components/MoreOptions.tsx",
    "pages/settings/components/PlaceholderSection.tsx",
    "pages/settings/components/ReadOnlyBanner.tsx",
    "pages/settings/components/RowNotice.tsx",
    "pages/settings/components/SearchField.tsx",
    "pages/settings/components/SearchResults.tsx",
    "pages/settings/components/SectionActions.tsx",
    "pages/settings/components/BetaChip.tsx",
    "pages/settings/components/SectionList.tsx",
    "pages/settings/components/SectionRoute.tsx",
    "pages/settings/components/SectionView.tsx",
    "pages/settings/components/SettingRow.tsx",
    "pages/settings/components/SettingsApp.tsx",
    "pages/settings/components/SettingsPage.tsx",
    "pages/settings/components/ScopeOverrides.tsx",
    "pages/settings/components/ThemeFiles.tsx",
    "pages/settings/components/ThemePicker.tsx",
    "pages/settings/components/ThemePreview.tsx",
    "pages/settings/components/AppIllustration.tsx",
    "pages/settings/components/ThemeStudio.tsx",
    "pages/settings/components/ExtensionsCard.tsx",
    "pages/settings/components/WorktreeSetupCard.tsx",
    "pages/settings/editors/AccentRowEditor.tsx",
    "pages/settings/editors/ChoiceOrNumberEditor.tsx",
    "pages/settings/editors/ColorEditor.tsx",
    "pages/settings/editors/DomainListEditor.tsx",
    "pages/settings/editors/DurationEditor.tsx",
    "pages/settings/editors/Editor.tsx",
    "pages/settings/editors/FolderListEditor.tsx",
    "pages/settings/editors/HostListEditor.tsx",
    "pages/settings/editors/MenuEditor.tsx",
    "pages/settings/editors/NumberEditor.tsx",
    "pages/settings/editors/NumberField.tsx",
    "pages/settings/editors/SearchTemplateEditor.tsx",
    "pages/settings/editors/ThemeRowEditor.tsx",
    "pages/settings/editors/Select.tsx",
    "pages/settings/editors/SoundEditor.tsx",
    "pages/settings/editors/StringMapEditor.tsx",
    "pages/settings/editors/TextEditor.tsx",
    "pages/settings/editors/TimeRangeEditor.tsx",
    "pages/settings/editors/ToggleEditor.tsx",
    "pages/settings/editors/UrlEditor.tsx",
    "pages/settings/icons.tsx",
  ],
  variants,
});
