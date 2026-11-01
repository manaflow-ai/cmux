// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { AccountsCmux, AccountsRow, AccountsState, CloudEnvironmentsState, HostLists } from "./ops";
import { categories, homes } from "./categories";
import { MockTeams } from "./mockTeams";
import { mockThemeColors } from "./mockThemes";
import { schema } from "./schema";
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
  // Guided Setup's button (Restart Helper when the helper failed): it shows in every phase.
  selector: '[data-card="computer-use"] [data-action-row] button',
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
  "agents-harnesses-registry": variant("agents", {
    note: "Harnesses: found on PATH, a profile file, an installed ACP Registry agent, a terminal-only harness, and acpmux's problem text.",
    harnesses: {
      loading: false,
      problem: null,
      harnesses: [
        { id: "claude", name: null, kind: "claude-stdio", source: "path", problem: null },
        { id: "codex", name: null, kind: "acp", source: "path", problem: null },
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
  // Leo, 10-19: Appearance's floating Undo, Redo and Reset, after a background pick (Undo names it).
  "appearance-undo-bar": variant("appearance", {
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
  // The terminal font list open: recent fonts first under a Recent tag, every family in its own face.
  "font-picker-open": variant("appearance", {
    focus: "terminal.fontFamily",
    options: { values: { "terminal.fontFamily": "JetBrains Mono" } },
    steps: [click(`${row("terminal.fontFamily")} [data-font-picker]`), wait("[data-font-option]")],
    note: "Terminal Font Family's list: the default first, then the fonts picked lately with a Recent tag, then every installed family, each drawn in its own face. Arrow keys preview live; Return picks, Escape reverts.",
  }),
  // Unset surface rows rest on the window's values, dimmed under an "Inherits window" badge.
  "surfaces-inherit-window": variant("appearance", {
    focus: "appearance.surfaces.sidebar.opacity",
    options: { values: { "appearance.backgroundOpacity": 0.8 } },
    host: { ...host, derived: { "appearance.backgroundOpacity": 0.8 } },
    steps: [wait(row("appearance.surfaces.sidebar.opacity"))],
    note: "Surfaces: each unset opacity rests on the window's 80% and each unset color on the window's color, dimmed with an Inherits window badge; no row reads a truncated default label.",
  }),
  "backdrops-pending": variant("appearance", {
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
    options: { values: { "appearance.background": "none" } },
    host: { ...host, backdrops: [] },
    // With no artwork the picker hides (useBackdropsShown) and the setting draws as its plain row.
    steps: [wait(row("appearance.background"))],
    note: "No artwork returned yet: the picker stays hidden and Background is its plain row, so the setting stays usable while the host list loads or is unavailable.",
  }),
  // Add from a Link (backgrounds plan phase 3): the link form open under the picker, a link typed.
  "backdrops-link": variant("appearance", {
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
    steps: [
      wait('[data-card="backdrop"] .backdrop-scope'),
      { selector: '[aria-label="This Workspace (Research)"]', action: "click" },
    ],
    note: "Change Background… on a workspace: This Workspace (Research) picked, following All Workspaces until it has its own.",
  }),
  // The curated backdrop art (cx-t2x.7): the real thumbnails of three works from each picker
  // collection, labelled "Title — Artist" with the credit lines the app sends, one picked.
  "curated-art": variant("appearance", {
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
  // Browse More Art (cx-t2x.8): a search across the open museum collections, sample answers.
  "art-browser": variant("appearance", {
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
    steps: [
      wait('[data-card="backdrop"]'),
      click('[data-card="backdrop"] button[aria-expanded]'),
      input('[data-card="art-browser"] input[type="search"]', "night"),
      click('[data-card="art-browser"] button[type="submit"]'),
      wait('[data-card="art-browser"] .backdrop-grid'),
    ],
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
  "cloud-environments-row-shape": variant("accounts", {
    environments: rowShapeEnvironments,
    note: "One failed Cloud Environment row with status, repository, error log and actions.",
    play: async (ctx) => {
      const card = ctx.find({ selector: '[data-card="cloudEnvironments"]' });
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
  "theme-app-light-dark": variant("theme", {
    allThemes: true,
    options: {
      values: {
        "appearance.theme": "light:Catppuccin Latte,dark:Catppuccin Mocha",
        "appearance.appTheme": "light:Rose Pine Dawn,dark:Rose Pine",
        "appearance.accent": "magenta",
      },
    },
    note: "One Theme card: the terminal and the app theme each with Match System Appearance, then the accent.",
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
  // Agents > Computer Use Setup (ComputerUseCard): off (grants unknown), every grant given, none.
  // Focusing the card's first button scrolls it into view.
  "computer-use-off": variant("agents", {
    host: { ...host, computer_use: { phase: "off", accessibility: null, screen_recording: null, helper: null } },
    steps: [wait('[data-card="computer-use"]'), focusComputerUse],
    note: "Computer Use off: the switch, then Guided Setup offering to turn it on; no grant rows.",
  }),
  "computer-use-failed": variant("agents", {
    host: { ...host, computer_use: { phase: "failed", accessibility: null, screen_recording: null, helper: null } },
    steps: [
      wait('[data-card="computer-use"]'),
      {
        selector: '[data-card="computer-use"] [data-action="palette.computerUse.restart"]',
        action: "focus",
      },
    ],
    note: "The helper did not respond. Restart Helper is the only action.",
  }),
  "computer-use-granted": variant("agents", {
    host: {
      ...host,
      computer_use: { phase: "ready", accessibility: true, screen_recording: true, helper: "cmux Computer Use" },
    },
    steps: [wait('[data-card="computer-use"] [data-granted="true"]'), focusComputerUse],
    note: "Computer Use ready: Accessibility and Screen Recording both allowed.",
  }),
  "computer-use-host-unverified": variant("agents", {
    host: {
      ...host,
      computer_use: {
        phase: "ready",
        accessibility: true,
        screen_recording: true,
        helper: "cmux Computer Use",
        host_unverified: true,
      },
    },
    steps: [wait('[data-card="computer-use"]'), focusComputerUse],
    note: "The legacy helper can't verify this build (not team-signed): legacy Computer Use is off.",
  }),
  "computer-use-upstream-fallback": variant("agents", {
    host: {
      ...host,
      computer_use: {
        phase: "ready",
        accessibility: true,
        screen_recording: true,
        helper: "cmux Computer Use",
        upstream_fallback: true,
      },
    },
    steps: [wait('[data-card="computer-use"]'), focusComputerUse],
    note: "Driver Upstream in a build without its helper: Legacy runs, and the status line says so.",
  }),
  "computer-use-not-granted": variant("agents", {
    host: {
      ...host,
      computer_use: { phase: "ready", accessibility: false, screen_recording: false, helper: "cmux Computer Use" },
    },
    steps: [wait('[data-card="computer-use"] [data-granted="false"]'), focusComputerUse],
    note: "Computer Use ready but neither grant given: both rows say Not Allowed.",
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
  // Settings > Chief > Chief Pet with the pet off (the default): the Chief's character stays checked.
  "chief-pet-off": variant("chief", {
    focus: "home.chiefPetMascot",
    note: "Chief Pet, pet off: the chosen character (Orb) is checked; Show Pet floats it.",
  }),
  // Settings > Chief > Chief Pet with Mochi, the first animated set, picked and the pet shown.
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
// One scroller (cx-jh7kq): a select opened near the bottom edge, then the content scrolled under
// it. The pop-up stays at its row (or waits hidden while the row is out of view); the document
// never scrolls, so the column never slides up under the window.
variants["play-select-scroll"] = variant("appearance", {
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
    "pages/settings/components/AccentPicker.tsx",
    "pages/settings/components/AccountsSection.tsx",
    "pages/settings/components/AccountsTeams.tsx",
    "pages/settings/components/AgentHarnesses.tsx",
    "pages/settings/components/AgentIntegrations.tsx",
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
    "pages/settings/components/PlaceholderSection.tsx",
    "pages/settings/components/ReadOnlyBanner.tsx",
    "pages/settings/components/ResetButton.tsx",
    "pages/settings/components/RowNotice.tsx",
    "pages/settings/components/SearchField.tsx",
    "pages/settings/components/SearchResults.tsx",
    "pages/settings/components/SectionActions.tsx",
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
    "pages/settings/editors/AccentRowEditor.tsx",
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
    "pages/settings/editors/ThemeRowEditor.tsx",
    "pages/settings/editors/SegmentedEditor.tsx",
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
