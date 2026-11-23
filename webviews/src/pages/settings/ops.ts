// The Settings page's contract: the `cmux.settings/1` pane-protocol ops (plans/cmux-next/
// settings-react.md, pane-protocol.md "Pages"). The daemon's config owner serves the data ops;
// until the pane-protocol router reaches the daemon, the app's page bridge relays each one to
// the daemon's v2 `settings.<verb>` operation unchanged (it moves `idempotency_key` into the v2
// envelope, stamps origin `user`, and prefixes every v2 error code with `cmux.`:
// `settings.managed` -> `cmux.settings.managed`, `revision.conflict` -> `cmux.revision.conflict`).
// The native ops are served by the app (live preview, sound) or are catalog actions.
//
// These types are hand-written until the op set is declared with the cmux-pane-protocol
// schemars macro; then they come from the generated client.

import type { AcpmuxUsageLimits } from "../../agent-session/acpmux/model";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";
import type { WorktreeRecipe } from "../../worktreeRecipe";
import { OWNER_SENTENCE } from "../shared/userMessage";

/** A museum search result (cmux.settings.art.search); its thumbnail is at `museum/<key>`. */
export type MuseumArtResult = {
  key: string;
  title: string;
  artist: string;
  date: string;
  source: string;
  page: string;
};

/** A workspace's own background: its name and value (null follows appearance.background). */
export type WorkspaceBackground = { workspace: string; title: string; value: string | null; opacity?: number | null };

export type ManagedInfo = { source: string; reason: string; team?: string | null };

/** One `cmux.settings.list` row: the schema row plus what applies now. */
export type ListRow = {
  key: string;
  /** Raw user preference, null when unset; distinguishes an explicit default from absence. */
  stored?: unknown;
  value: unknown;
  default: unknown;
  customized: boolean;
  managed: ManagedInfo | null;
  /** Chat roots retain refused entries and administrator provenance for the list editor. */
  folders?: Array<{ path: string; managed: boolean; reason: string | null }>;
  user_roots?: string[];
};

export type Diagnostic = { path: string | string[]; message: string; kind?: string };

/**
 * A note at a row, not a problem (#44894): where its value comes from or why it does not draw.
 * `setByThemeFile` and `overThemeFile` name the theme file (`themes/<name>.json`); `plainBackgrounds`
 * marks the window background rows while Plain Backgrounds is on.
 */
export type RowNoteData = { path: string; kind: string; file?: string };

/** `recent_fonts`: font families written lately to any font setting, newest first (RecentFonts.swift). */
export type Domains = { themes: string[]; font_families: string[]; sounds: string[]; recent_fonts: string[] };

/** Published value domains; `null` for a domain the app never published. */
export type PublishedDomains = { [K in keyof Domains]: string[] | null };

export type SnapshotResult = {
  revision: number;
  schema_hash: string;
  effective: Record<string, unknown>;
  managed: Record<string, ManagedInfo>;
  diagnostics: Diagnostic[];
  /** Row notes; absent from an older host. */
  notes?: RowNoteData[];
  domains?: Partial<PublishedDomains> | null;
};

/** One Ghostty config key, keybind action or unreadable line cmux does not apply (R92). */
export type GhosttyDiagnostic = {
  kind: "key" | "keybind-action" | "invalid";
  name: string;
  file: string | null;
  line: number | null;
  reason: "superseded" | "not-applicable" | "later" | null;
  replacement: string | null;
};

/** A color the Ghostty config sets itself, which no theme changes (Ghostty applies the config over the theme). */
export type ThemeOverride = {
  /** The Ghostty key: `background`, `foreground`, `palette`, … */
  key: string;
  /** The file, with `~` for home. */
  file: string;
  /** The 1-based line of the assignment in effect. */
  line: number;
};

/** One space or machine row (`cmux.settings.host.lists`). */
/** `icon` is the row's wire icon (a space's; a machine's symbol): an emoji, a symbol or a stored asset. */
export type HostListRow = {
  id: string;
  title: string;
  subtitle: string | null;
  icon?: string | null;
  active: boolean;
  /** A machine's color now (`#RRGGBB`: the person's pick, else the automatic one). */
  color?: string;
  /** The key a machine's pick is under in `appearance.machineColors` (its name, trimmed and lowercased). */
  color_key?: string;
  /**
   * A Cloud machine the Cloud API says the signed-in caller owns: its "Dedicated agent machine" switch
   * (acpmux vmHost), once the machine answered. Absent on every other machine (team VMs, personal and
   * SSH machines never have it). `busy`: a set is
   * running or the machine is not reachable now; the switch is disabled.
   */
  vm_host?: { on: boolean; busy: boolean; error: string | null };
};

/** One browser profile row. */
export type BrowserProfile = {
  id: string;
  name: string;
  color: string | null;
  icon: string | null;
  is_default: boolean;
  source: string | null;
};

/** One row of Settings > Devices. */
export type DeviceRow = {
  id: string;
  title: string;
  subtitle: string;
  detail: string | null;
  /** connected, offline, pending or error. */
  state: string;
  removable: boolean;
  /** A paired client machine's Full-access setting; absent on a row without one. */
  full_access?: boolean;
  /** What turning Full access on allows, beside the switch. */
  full_access_help?: string;
};

/** One entry of a menu's tree: a row key, `-` for a separator, or a submenu with its rows (the
 * app's `folder:<name>`, or the person's `group:<id>` with a title). */
export type MenuNode = string | { key: string; title?: string; items: MenuNode[] };

/** A right-click menu's arrangement (Swift `ContextMenuLayout`): the whole menu as a tree, and
 * the rows it hides (kept in place). */
export type MenuLayout = { items: MenuNode[]; hidden: string[] };

/** One row a menu's arrangement can place: an action, a submenu, or a folder (`folder:<name>`). */
export type MenuRow = {
  key: string;
  title: string;
  kind: "item" | "submenu" | "folder";
  /** An SF Symbol the page shows from `cmux-page://cmux.settings/symbol/<name>`; null for none. */
  symbol: string | null;
  /** The folder key the app generates the row in; null for the top level. */
  home: string | null;
};

/** One right-click menu in Settings > Menus. */
export type ContextMenuState = {
  id: string;
  title: string;
  /** workspace, tabs, terminal, browser or other: where the list groups it. */
  area: string;
  customized: boolean;
  rows: MenuRow[];
  /** The app's own arrangement (what Reset draws). */
  generated: MenuLayout;
  /** The arrangement drawn now: every row once, hidden ones in place. */
  layout: MenuLayout;
};

/** Settings > Menus as the app serves it (`context_menus` in the host lists). */
export type ContextMenusHostState = { show_customize_item: boolean; menus: ContextMenuState[] };

/** Settings > Devices as the app serves it (`devices` in the host lists), every text localized. */
export type DevicesHostState = {
  title: string;
  help: string;
  empty: string;
  add_title: string;
  remove_title: string;
  remove_confirm_title: string;
  remove_help: string;
  full_access_title: string;
  activity_title: string;
  error: string | null;
  rows: DeviceRow[];
  activity: Array<{ time: string; what: string; subject: string }>;
};

/** A consent this joined Mac keeps (acpmux's machine consent): `signedInMachines` lets the person's other Macs signed in to this account open workspaces here. */
export type JoinConsentSurface = "screen" | "control" | "signedInMachines";

/** This Mac joined to a team with the one-line join: its consent switches, all off until the person turns them on. */
export type DevicesJoinState = {
  title: string;
  /** "Joined to <team> as <name>". */
  joined: string;
  help: string;
  error: string | null;
  /** A consent write is in flight: the switches are disabled until it ends. */
  busy: boolean;
  /** acpmux's record is known: without it the switches are disabled (an off nobody confirmed). */
  known: boolean;
  /** The label of the action that turns every switch off while the record is unknown; null while it is known. */
  revoke_all: string | null;
  switches: Array<{ surface: JoinConsentSurface; title: string; help: string; on: boolean }>;
};

/** The lists the host shows beside the schema rows; `rooms` is null when spaces are unsupported. */
export type HostLists = {
  /** Existing Debug preference, forwarded unchanged for the normal picker placement fallback. */
  harness_placement?: string;
  /** The app is a DEV build: the Development category shows (Settings > Development). */
  dev_build?: boolean;
  rooms: HostListRow[] | null;
  machines: HostListRow[];
  browser_profiles: BrowserProfile[];
  profile_colors: Array<{ name: string; swatch: string; fill: string }>;
  /**
   * Theme levels of the active window (`room`, `workspace`, `terminal`) and each one's theme: a
   * level with a theme overrides appearance.theme there (the page shows it inline, P4).
   * `config` is the Ghostty config's own theme colors (unnamed), sent while appearance.theme
   * is unset: the preview of "Use Ghostty Config". The app theme is the key appearance.appTheme.
   */
  theme?: {
    levels: string[];
    current: Record<string, string | null>;
    config?: GhosttyTheme | null;
    /** The Mac's own light or dark (the side of a light/dark pair the terminals use). The page's
     * prefers-color-scheme is its window's, which a light or dark App Theme sets. */
    system_scheme?: "light" | "dark";
  };
  terminal?: { ghostty_config: string; shell_integration: string | null };
  /** R92: the Ghostty lines cmux does not apply (the socket's `ghostty.diagnostics` list). */
  ghostty_diagnostics?: GhosttyDiagnostic[] | null;
  /** The Theme section's notice: colors the Ghostty config sets itself, which no theme changes. */
  theme_overrides?: ThemeOverride[];
  settings_file?: string | null;
  /** Computer Use Setup (Agents): the helper's grants; null while unknown (off, starting). */
  computer_use?: ComputerUseState | null;
  /** Settings > Mobile: the iPhone host's status, space and connected phones; every text localized by the host. */
  iphone?: IPhoneHostState | null;
  /** Settings > Server: each server's status, version line, Restart Recommended, socket and tailnet address; every text localized by the host. */
  server?: ServerHostState | null;
  /** Settings > Devices (plans/cmux-next/add-device-DESIGN.md): every device, its texts localized by the app. */
  devices?: DevicesHostState | null;
  /** Settings > Devices: this joined Mac's Screen sharing and Control consent (labs.machineJoin); null unless joined. */
  devices_join?: DevicesJoinState | null;
  /** Settings › Import: the import suggestion cards, every text localized by the host (ui/ImportCards.tsx parses it). */
  import_suggestions?: unknown;
  /** Updates > Web UI: the web UI served between app updates; null unless the bundle takes them (NIGHTLY). */
  web_updates?: WebUpdatesState | null;
  /** Updates > App Update: the app update's status, a download's progress and the buttons; every text localized by the host. */
  app_update?: AppUpdateState | null;
  /** Settings > Chief > Voice input: the Debug toggle home.voiceInput; null where it does not exist (Release). */
  voice_input?: { on: boolean } | null;
  /** Settings > Menus: every right-click menu's rows and the person's arrangement of it. */
  context_menus?: ContextMenusHostState;
  /**
   * Wallpaper choices; thumbnails at `backdrop/<id>` on the page's own origin. Each carries its
   * picker collection (`darkArt`, `museumIcons`, `calm`, `dore`, `yours`, `apple`, `video`) and
   * its localized title. `video: true` marks a moving wallpaper; a macOS still (`apple`) says
   * whether macOS has downloaded the full picture.
   */
  backdrops?: Array<{
    id: string;
    title: string;
    attribution: string;
    collection?: string;
    collection_title?: string;
    video?: boolean;
    downloaded?: boolean;
    /** A macOS dynamic wallpaper (frames by sun position or clock): Switch Automatically's Sun. */
    dynamic?: boolean;
  }>;
  /** Where an unset number row's slider sits when the app resolves it (the theme's window opacity). */
  derived?: Record<string, number>;
};

/** Settings > Server (plans/cmux-next/server-updates-DESIGN.md section 10): one row per server the app heard from. */
export type ServerHostState = {
  title: string;
  /** Shown while `servers` is empty. */
  empty: string;
  socket_title: string;
  tailnet_title: string;
  copy_title: string;
  pair_title: string;
  servers: Array<{
    id: string;
    /** `cmux-tui` or `acpmux`. */
    kind: string;
    /** The paired host's name; null for this Mac. */
    host: string | null;
    /** "cmux-tui", or "cmux-tui on cmux-mini". */
    name: string;
    running: boolean;
    status: string;
    /** "Version 0.67.0 · Build abc1234 · Protocol 12". */
    version_line: string;
    /** Present when a restart would turn on new features; the button opens the host's confirm. */
    restart: { title: string; help: string; button: string } | null;
    /** This Mac's control socket (the local server only). */
    socket: string | null;
    /** This Mac's Tailscale address (the local server only). */
    tailnet: string | null;
  }>;
};

/**
 * The Mobile page's iPhone card: the iPhone host the app runs while the schema row
 * `mobile.allowIPhoneConnections` is on and an account is signed in. Every text is localized by
 * the host.
 */
export type IPhoneHostState = {
  title: string;
  allowed: boolean;
  status_title: string;
  status: string;
  /** The Sign In button's title while the status says to sign in; null (or absent from an older host) otherwise. */
  sign_in?: string | null;
  /** `off`, `unavailable`, `connecting`, `online` or `waiting`. */
  phase: string;
  account_title: string;
  /** "Registered as <email>": the account phones must sign in with; null while signed out. */
  account: string | null;
  space_title: string;
  /** The team the Mac is listed in (or the personal space); null while signed out. */
  space: string | null;
  how_title: string;
  how: string;
  phones_title: string;
  phones_empty: string;
  /**
   * The account's phones (with their live link when connected), then live links of phones the list
   * does not have yet. `transport` (`webrtc`, `wireguard`) and `path` (`direct`, `relay`, `turn`)
   * are read-only facts of a live link; only a `removable` row has Remove.
   */
  phones: Array<{
    id: string;
    title: string;
    subtitle: string;
    connected: boolean;
    removable: boolean;
    transport: string | null;
    path: string | null;
  }>;
  /** Why the list could not load or a removal failed; null when it worked. */
  phones_error: string | null;
  remove_title: string;
  remove_help: string;
  /** With phase `removed` (the owner removed this Mac): the button that allows connections again. */
  allow_again_title?: string;
  /** Phones asking to pair, oldest first; Allow and Don't Allow are the person's own gesture. */
  pending_title?: string;
  pending?: Array<{ id: string; title: string; subtitle: string }>;
  pair_allow_title?: string;
  pair_deny_title?: string;
  /** "Blocked requests: N" after a Don't Allow quieted prompts (or too many asked); null when none. */
  blocked?: string | null;
  blocked_help?: string;
};

/** `ComputerUseSetup.Phase` in the app. */
export type ComputerUsePhase =
  | "disabled_by_policy"
  | "off"
  | "unavailable"
  | "starting"
  | "failed"
  | "ready"
  | "version_mismatch";

/**
 * Updates > App Update (the app's UpdaterService): what the update does now, whether or not the
 * person asked (a background download and its failure show here; the sidebar shows only the staged
 * update's Restart to Update). `progress` is 0...1, null while unmeasured, absent with no bar.
 * Every text is the host's.
 */
export type AppUpdateState = {
  title: string;
  phase: string;
  status: string;
  detail: string | null;
  progress?: number | null;
  actions: { id: AppUpdateAction; title: string; prominent: boolean }[];
};

/** A button of the App Update card (Swift `SettingsUpdateAction`). */
export type AppUpdateAction = "check" | "update" | "cancel_download" | "retry" | "install";

/** A web update the app keeps: its commit and when that commit landed (unix seconds). */
export type WebUpdateVersion = { commit: string; committed_at: number };

/**
 * Updates > Web UI (the app's WebUpdates): `served` is the update the pages serve now (null: the
 * built-in web UI), `active` the one served from the next safe point, `pending` what that safe point
 * swaps in, `refusal` why the newest update was not taken.
 */
export type WebUpdatesState = {
  channel: "every-merge" | "nightly" | "off";
  phase: "idle" | "checking" | "downloading" | "failed";
  served: WebUpdateVersion | null;
  active: WebUpdateVersion | null;
  previous: WebUpdateVersion | null;
  pending: "update" | "bundled" | null;
  last_check: number | null;
  refusal: "app_too_old" | "not_newer" | "untrusted" | "damaged" | "offline" | null;
};

/** The Computer Use card's state: the grants of the helper that runs (or would run). */
export type ComputerUseState = {
  phase: ComputerUsePhase;
  accessibility: boolean | null;
  screen_recording: boolean | null;
  /** The helper app's name, null when this build has no signed helper. */
  helper: string | null;
  /** Legacy Computer Use is off: its helper can't verify this cmux build (not team-signed). */
  host_unverified?: boolean;
  /** Driver "upstream" was chosen, but this build has no upstream helper: the legacy helper runs. */
  upstream_fallback?: boolean;
  /** The engine's version line ("cmux Computer Use 1.0"), localized by the host; absent while unknown. */
  engine?: string | null;
  /** The worker process: `running` (with its pid), `starting`, `stopped` or `failed`; absent while unknown. */
  worker?: { state: "running" | "starting" | "stopped" | "failed"; pid?: number | null } | null;
  /** Saved per-app answers (Approved apps): "Always allow" or "Never", newest first. */
  approvals?: ComputerUseApproval[];
  /** Apps running now, offered by the Denied Apps editor's Add menu. */
  running_apps?: Array<{ id: string; name: string }>;
};

/** One saved Computer Use answer for an app (`computerUse.approval.*` actions change it). */
export type ComputerUseApproval = { app_id: string; name: string; decision: "always" | "never" };

/** One button of the Accounts part; the host localizes every text. */
export type AccountsButton = {
  id: string;
  title: string;
  disabled: boolean;
  help: string | null;
  destructive: boolean;
};

/** One provider row of the Accounts part (`cmux.settings.accounts.state`). */
export type AccountsRow = {
  provider: string;
  name: string;
  detail: string | null;
  status: string;
  statusKind: "success" | "attention" | "neutral" | "quiet";
  busy: boolean;
  buttons: AccountsButton[];
  linked: Array<{ id: string; label: string; state: string; healthy: boolean; busy: boolean }>;
  note: string | null;
  outcome: { kind: "success" | "neutral" | "danger" | "attention"; text: string } | null;
  confirm: { text: string; confirm: string; cancel: string } | null;
  paste: { title: string; body: string; placeholder: string; buttons: AccountsButton[] } | null;
};

/**
 * The account's teams, the active one marked (`active`). Every team-scoped feature follows the
 * active team; null when signed out or teamless.
 */
export type AccountsTeams = {
  title: string;
  help: string;
  options: Array<{ id: string; name: string; active: boolean }>;
  /** Switching is off: a managed device, or a switch being saved. */
  disabled: boolean;
  note: string | null;
  error: string | null;
};

/**
 * cmux's own account row. Button ids are run as actions: `cmux.signIn`, `cmux.cancelSignIn`,
 * `cmux.continueInBrowser`, `cmux.switchAccount`, `cmux.signOut`.
 */
export type AccountsCmux = {
  title: string;
  detail: string | null;
  status: string;
  statusKind: "success" | "attention" | "neutral" | "quiet";
  busy: boolean;
  buttons: AccountsButton[];
  note: string | null;
  error: string | null;
};

/** An inline team name form (New Team, Rename Team); the field starts at `value`. */
export type AccountsTeamForm = {
  kind: "create" | "rename";
  title: string;
  help: string;
  value: string;
  placeholder: string;
  maxLength: number;
  submit: string;
  cancel: string;
  error: string | null;
  busy: boolean;
};

/** The open team's details. Admins get `buttons` (`team.rename`, `team.delete`); members `readOnly`. */
export type AccountsTeamDetails = {
  loading: string | null;
  error: string | null;
  facts: Array<{ label: string; value: string }>;
  membersTitle: string;
  members: Array<{ id: string; name: string; detail: string | null; role: string; you: string | null }>;
  /** Pending invitations; null unless the person is an admin. */
  invitationsTitle: string | null;
  invitations: Array<{ id: string; email: string; role: string; expires: string | null }> | null;
  noInvitations: string | null;
  buttons: AccountsButton[];
  readOnly: string | null;
  rename: AccountsTeamForm | null;
  confirm: { text: string; confirm: string; cancel: string; error: string | null; busy: boolean } | null;
};

/** One team with the person's role; `toggle` runs `team.details`. */
export type AccountsTeamRow = {
  id: string;
  name: string;
  role: string;
  roleKind: "admin" | "member" | "unknown";
  active: string | null;
  open: boolean;
  toggle: AccountsButton;
  detail: AccountsTeamDetails | null;
};

/**
 * The account's teams with roles, the open team's details and the create, rename and delete forms.
 * Gestures run as `team.<gesture>`: `details`, `new`, `create` (`name`), `rename`, `saveName`
 * (`team`, `name`), `delete`, `confirmDelete`, `cancel`. Null when signed out.
 */
export type AccountsTeamList = {
  title: string;
  newTeam: AccountsButton;
  rows: AccountsTeamRow[];
  empty: string | null;
  create: AccountsTeamForm | null;
  notice: { kind: "success" | "neutral" | "danger" | "attention"; text: string } | null;
  /** Invitations to the person; null when there are none. */
  received: AccountsReceivedInvitations | null;
};

/** One invitation addressed to the person: `accept` runs `team.accept`, `decline` runs
 * `team.decline`, each with the invitation's id as `team`. */
export type AccountsReceivedInvitation = {
  id: string;
  team: string;
  detail: string;
  expires: string | null;
  accept: AccountsButton;
  decline: AccountsButton;
};

/** Invitations to You: the teams that invited one of the person's verified emails. */
export type AccountsReceivedInvitations = {
  title: string;
  rows: AccountsReceivedInvitation[];
  error: string | null;
};

/** The Accounts part as the host draws it (texts already localized by the app). */
export type GitHubConnectionState = {
  title: string;
  detail: string;
  busy: boolean;
  connect: string;
  disconnect: string;
  /** Reconfigure's title (absent from an older host, which has no Reconfigure). */
  reconfigure?: string;
  confirm: string;
  cancel: string;
  refresh: string;
  canConnect: boolean;
  connections: Array<{
    id: string;
    account: string;
    status: string;
    permissions: string[];
    canDisconnect: boolean;
    /** An active connection: Reconfigure opens its installation's page on GitHub (repositories, account access). */
    canReconfigure?: boolean;
  }>;
  /** The Sign In button's title while nobody is signed in to cmux; null (or absent from an older host) otherwise. */
  signIn?: string | null;
};

/** One agent's team key as the host draws it: never the key, only whether one is set and its summary. */
export type TeamAgentKeyRow = {
  agent: "claude" | "codex";
  name: string;
  set: boolean;
  status: string;
  /** Kind, last four characters (admins only) and when it changed; null when unset. */
  detail: string | null;
  error: string | null;
  notice: string | null;
};

/**
 * Settings > Accounts > Team agent keys: the active team's shared Claude and Codex keys, which the
 * team's Cloud machines use in place of members' own. Gestures: `agentKeySave` (`provider` = agent,
 * `name` = kind, `secret` = the pasted key, sent once and cleared), `agentKeyRemove` (`provider`),
 * `agentKeyRefresh`. Admins (`canManage`) change keys; members read `note`.
 */
export type TeamAgentKeysState = {
  title: string;
  detail: string;
  /** Signed out, personal team, or read-only member copy; null otherwise. */
  note: string | null;
  signIn: string | null;
  busy: boolean;
  canManage: boolean;
  error: string | null;
  refresh: string;
  labels: {
    add: string;
    replace: string;
    remove: string;
    confirmRemove: string;
    cancel: string;
    save: string;
    kind: string;
    secret: string;
    placeholder: string;
  };
  kinds: Array<{ id: "api_key" | "oauth"; title: string }>;
  agents: TeamAgentKeyRow[];
};

/** A member's Chief tier (Settings > Team > Compute). */
export type ChiefTier = "standard" | "plus" | "max";

/**
 * The team's monthly Cloud allotment as the backend keeps it (Settings > Team > Compute). Micros are
 * millionths of a US dollar. Every seat includes $25 a month of pooled usage; `commit_micros` is the
 * extra pooled usage the admin commits to, in $25 steps at 20% off. Field names are the wire's.
 */
export interface TeamAllotment {
  commit_micros: number;
  mode: "ask" | "auto";
  auto_max_micros: number | null;
  tiers: Record<string, ChiefTier>;
  snoozed_until: number | null;
  changed_at: number;
  changed_by: string;
}

/** One member's Cloud use over this month and the last 14 days. `spare_micros` is warm-spare time,
 * the platform's cost, shown to the team as $0. */
export interface MemberUse {
  member: string;
  tier: ChiefTier;
  month_micros: number;
  usd14_micros: number;
  active_days14: number;
  share_micros: number;
  rank: number;
  over_share14: number;
  plan_limit_ms14: number;
  spare_micros: number;
}

/** Why the scheduler proposes what it proposes. */
export type AllotmentReason =
  | { kind: "unused"; members: string[] }
  | { kind: "over"; member: string; count: number }
  | { kind: "runaway"; member: string; rate_micros_h: number }
  | { kind: "tier"; member: string; to: ChiefTier; costs_micros: number };

/** The scheduler's proposal: `position` and the commit it would set (`to_commit_micros`).
 * `allot_micros` = included + tier credits + commit. Members are never refused by the allotment. */
export interface AllotmentDecision {
  allot_micros: number;
  forecast_micros: number;
  position: "down" | "hold" | "up";
  to_commit_micros: number;
  reasons: AllotmentReason[];
  members: MemberUse[];
  order: string[];
  apply: boolean;
}

/** `cmux.settings.cloud.allotment.get` and `.set`'s answer. `allotment` is null before an admin
 * ever set one. */
export interface AllotmentView {
  allotment: TeamAllotment | null;
  decision: AllotmentDecision;
  hard_cap_micros: number | null;
  as_of: number;
}

export type AllotmentPosition = AllotmentDecision["position"];

/** One gesture of the Compute card: up and down apply the decision's `to_commit_micros`; hold
 * snoozes proposals 14 days. `auto` sets the mode. */
/** No `action`: only the mode changes (the Auto switch); the commit and any snooze are kept, as the platform's
 * cloud.allotment.set does. `hold` snoozes proposals. */
export type AllotmentSet = { action?: AllotmentPosition; auto?: boolean };

/** Which way of paying for a model a Settings > Models connection is (cmux-tui/docs/model-connections.md). */
export type ModelConnectionKind =
  | "codex-login"
  | "claude-login"
  | "subscription"
  | "chatgpt-plan"
  | "claude-token"
  | "api-key";

/** A model provider a connection pays (product names, shown as they are). */
export type ModelProvider = "openai" | "anthropic" | "openrouter" | "google" | "xai";

/** One of the person's connections (acpmux `_acpmux/connections`), in the order threads use them. */
export type ModelConnection = {
  /** The acpmux route id. */
  id: string;
  kind: ModelConnectionKind;
  provider: ModelProvider;
  families: string[];
  label: string;
  /** Shown on this local page only. */
  email: string | null;
  plan: string | null;
  signedIn: boolean;
  /** The routing switch: a disabled connection serves no thread. */
  enabled: boolean;
  defaultFor: string[];
  /** False: only this Mac's own chats can use it (a Mac login Cloud threads cannot reach). */
  servesCloud: boolean;
};

/** Settings > Models (`cmux.settings.models.state`): the person's connections, the organization's,
 * the members policy, and a ChatGPT sign-in in flight. */
export type ModelsState = {
  /** `available`: false when this Mac's daemon does not list connections. */
  personal: { connections: ModelConnection[]; spread: boolean; available: boolean };
  organization: {
    team: { id: string; name: string } | null;
    canEdit: boolean;
    keys: { agent: "claude" | "codex"; set: boolean; last4: string | null }[];
  };
  /** Null without a team. */
  members: { ownConnections: boolean; chooseRunout: boolean; canEdit: boolean } | null;
  /** `attempt`: a Continue with ChatGPT sign-in waiting on the browser; `error`: the last one's
   * failure code (`access_denied`, `no_chatgpt_account`, ...). */
  chatgpt: { attempt: string | null; error: string | null };
};

/** One Settings > Models gesture. `addKey`, `addClaudeToken` and `orgKey` carry a pasted secret once:
 * the app moves it into the Keychain and passes acpmux or the team only a reference.
 * `claudeSetupToken` opens a cmux terminal tab running `claude setup-token`. */
export type ModelsRun =
  | { action: "order"; ids: string[] }
  | { action: "spread"; on: boolean }
  | { action: "enable"; id: string; on: boolean }
  | { action: "remove"; id: string }
  | { action: "connectChatGPT"; id?: string }
  | { action: "cancelChatGPT" }
  | { action: "connectClaude" }
  | { action: "claudeSetupToken" }
  | { action: "addClaudeToken"; token: string; label?: string }
  | { action: "addKey"; provider: ModelProvider; key: string; label?: string }
  | { action: "orgKey"; agent: "claude" | "codex"; key: string | null }
  | { action: "members"; ownConnections?: boolean; chooseRunout?: boolean };

/** A dictation engine's provider (acpmux `_acpmux/voice/state` `providers`; crate cmux-voice's catalog). */
export type DictationProvider = {
  /** The `agentPane.dictationEngine` value: `onDevice`, `openai`, `groq`, `localServer`, `whisperCpp`, `custom`. */
  id: string;
  label: string;
  kind: "local" | "cloud";
  wire: "builtin" | "openaiTranscriptions" | "whisperCppInference";
  key: "none" | "optional" | "required";
  defaultUrl: string;
  defaultModel: string;
};

/** The dictation engine the three `agentPane.dictationEngine*` settings name, as acpmux resolves them
 * (`cmux.settings.dictation.run` `state`, `setKey` and `removeKey`). The key itself never comes back:
 * only whether the Keychain holds one for `keyAccount`. */
export type DictationState = Omit<DictationProvider, "id" | "defaultUrl" | "defaultModel"> & {
  engine: string;
  /** The effective base URL; empty when the engine needs none or has none yet. */
  url: string;
  model: string;
  /** `<provider>@<origin>`; null when no key can be stored (no URL yet, or a keyless engine). */
  keyAccount: string | null;
  keyService: string;
  hasKey: boolean;
  providers: DictationProvider[];
};

/** Why a dictation call failed (a closed set; crate cmux-voice). */
export type DictationErrorCode =
  | "key_missing"
  | "key_invalid"
  | "offline"
  | "timeout"
  | "rate_limited"
  | "bad_endpoint"
  | "rejected"
  | "too_large"
  | "provider_error"
  | "bad_response"
  | "not_configured";

/** A dictation call's failure: `detail` is short, scrubbed of the key, and may be empty. */
export type DictationError = { code: DictationErrorCode | (string & {}); detail: string };

/** Check Connection's answer (`_acpmux/voice/check`): no audio is sent. */
export type DictationCheck = { ok: true } | { ok: false; error: DictationError };

/** One Settings > Agent Chat dictation gesture. `setKey` carries a pasted key once (it needs a user
 * gesture, like Models' addKey): the app stores it in the Keychain at the account a fresh state
 * names, and the page never sees it again. */
export type DictationRun =
  | { action: "state" }
  | { action: "setKey"; key: string }
  | { action: "removeKey" }
  | { action: "check" };

/** What a gesture answers: the check's result for `check`, else the state after it. */
export type DictationAnswer<R extends DictationRun> = R extends { action: "check" } ? DictationCheck : DictationState;

export type AccountsState = {
  github?: GitHubConnectionState;
  /** Older hosts omit it. */
  agentKeys?: TeamAgentKeysState | null;
  teams: AccountsTeams | null;
  /** Older hosts omit it. */
  teamList?: AccountsTeamList | null;
  refresh: string;
  refreshing: boolean;
  /** cmux's own account: who is signed in, sign in, switch and sign out. */
  cmux: AccountsCmux;
  removeTitle: string;
  groups: Array<{ id: string; title: string; rows: AccountsRow[] }>;
};

/**
 * One Accounts gesture; `secret` only for the paste form's save and send, `team` for selectTeam and
 * the `team.*` gestures, `name` for a team create or rename.
 */
export type AccountsRun = {
  action: string;
  provider?: string;
  account?: string;
  secret?: string;
  team?: string;
  name?: string;
};

/** One Settings > Agents row: a harness acpmux knows (never its command line or env). */
export type AgentHarnessRow = {
  id: string;
  name: string;
  /** `acp`, `claude-stdio` or `terminal`. */
  kind: string;
  /** `builtIn`, `user`, `managed`, `cmuxJson`, `acpx` or `registry`. */
  source: string;
  removable: boolean;
  default: boolean;
  family?: string;
  icon?: string;
  /** The icon acpmux resolved (`_acpmux/harnesses` `iconSpec`; shared/harnessIcons.ts). */
  iconSpec?: unknown;
  unavailable?: string;
  probeError?: string;
  sourcePath?: string;
};

export type AgentDoctorStep = {
  name: string;
  ok?: boolean;
  status?: "pass" | "warn" | "fail" | "skip";
  detail?: string;
  fix?: string;
};
export type AgentDoctorResult = { running?: boolean; ok?: boolean; steps?: AgentDoctorStep[] };

export type AgentRegistryAgent = {
  id: string;
  name: string;
  description?: string;
  version?: string;
  website?: string;
  /** How it can start here: `path` (installed), `npx`, `uvx` or `none`. */
  launch: string;
  installed?: boolean;
  /** The harness it already is, when added. */
  harnessId?: string;
};

/** Settings > Agents (`cmux.settings.agents.state`). */
export type AgentsState = {
  /** `loading`, `ready` or `unreachable` (no daemon answered; `message` says why). */
  status: string;
  message?: string;
  /** False for an acpmux without the add, remove and doctor operations: the page shows the CLI. */
  manages: boolean;
  harnesses: AgentHarnessRow[];
  doctor: Record<string, AgentDoctorResult>;
  registry?: { agents: AgentRegistryAgent[] };
  /** The last removal, for Undo. */
  removed?: { id: string; backup: string };
};

/** One Settings > Agents gesture (`cmux.settings.agents.run`). */
export type AgentsRun =
  | AgentsSymbolRun
  | { action: "refresh" }
  | { action: "registry"; refresh?: boolean }
  | {
      action: "add";
      registry?: string;
      id?: string;
      displayName?: string;
      command?: string;
      args?: string[];
      protocol?: "acp" | "terminal";
      envKeys?: string[];
    }
  | { action: "remove"; id: string }
  | { action: "restore"; backup?: string }
  | { action: "doctor"; id: string; noPrompt?: boolean }
  /** A user profile's icon: a typed value, an image's base64 bytes, or Automatic (`clear`). */
  | { action: "icon"; id: string; icon?: string; data?: string; ext?: "png" | "svg"; clear?: true };
/** The template PNG of an SF Symbol a harness icon names, as a `data:` URL (`{src}`). */
export type AgentsSymbolRun = { action: "symbol"; name: string };
/** One acpmux harness of Settings > Agents > Harnesses (`cmux.settings.harnesses.state`). */
export type HarnessRow = {
  id: string;
  /** A profile file's display name; null names it by id. */
  name: string | null;
  kind: "acp" | "claude-stdio" | "terminal" | string;
  /** managed, user-file, cmux-json (profile files), registry, path or config. */
  source: string;
  /** Why it cannot start, as acpmux says it (its own text). */
  problem: string | null;
  /** From `_acpmux/harness/health` (absent from an older daemon): installed and newest versions. */
  version?: string | null;
  /** Where acpmux found its program, and the npm package or Homebrew formula behind it: two rows
   * with the same are one install, with one update card. */
  path?: string | null;
  package?: string | null;
  latest?: string | null;
  outdated?: boolean;
  /** Only from evidence (a profile's check or a probe's sign-in error). */
  auth?: "signedIn" | "signedOut" | "expired" | "unknown";
  /** How to update it; `elevated`: needs sudo, so the page shows `command` and never runs it. */
  update?: { command: string; elevated: boolean } | null;
  /** The update owner runs this channel (npm, Bun or native); without it Update is not offered. */
  ownerUpdate?: boolean;
  /** acpmux runs its update on its own when a check finds it outdated (off by default). */
  autoUpdate?: boolean;
  /** What auto-update last did for it. */
  lastAutoUpdate?: { ok: boolean; detail: string } | null;
  /** When acpmux last checked it (ms since the epoch); the card shows the newest as "Checked 5m ago". */
  checkedAt?: number | null;
};

/** One provider account routing may use (acpmux `_acpmux/accounts`): the CLI's own login (`builtin`)
 * or an account added in a shadow home. Folders arrive under `~`; actions name the id only. */
export type ProviderAccount = {
  id: string;
  family: "codex" | "claude" | string;
  name: string;
  /** Its own login folder; null is the CLI's default (`defaultHome`). */
  home: string | null;
  defaultHome?: string | null;
  /** The folder whose settings and chats a shadow home shares. */
  shadowOf: string | null;
  signedIn: boolean;
  plan: string | null;
  /** Shown on this local Settings page only. */
  email: string | null;
  /** Routing may move chats onto it. */
  enabled: boolean;
  builtin: boolean;
  /** New chats of its family run on it. */
  default?: boolean;
  /** An API-key account: no login folder, sign-in or sign-out. */
  key?: boolean;
  /** Its plan's 5-hour and weekly limits, read when Settings opens (acpmux `_acpmux/account/usage`,
   * the chat's `usageLimits` shape); null or absent when none was read (Claude Code reports its
   * limits only during a chat, and a Codex login in the keychain is not asked). */
  usage?: AcpmuxUsageLimits | null;
};

/** The Harnesses part: acpmux's harnesses (the host reads `_acpmux/harnesses`). */
export type HarnessesState = {
  loading: boolean;
  /** `unavailable`: no acpmux in this app; `unreachable`: its daemon did not answer. */
  problem: "unavailable" | "unreachable" | null;
  harnesses: HarnessRow[];
  /** acpmux's provider accounts; null or absent from a daemon without `_acpmux/accounts`. */
  accounts?: ProviderAccount[] | null;
  /** Receipts and terminal observations from the captured update owner. */
  jobs?: Array<{
    machine: string;
    session: string;
    cli: string;
    profiles: string[];
    terminal?: string;
    intent_key?: string;
    can_resume?: boolean;
    /** Nothing runs for it (or the owner cannot tell): Dismiss stops it blocking another update. */
    can_dismiss?: boolean;
    state: "created" | "pending" | "exited" | "unknown";
    exit_code?: number;
    signal?: number;
    /** With `exited`: the owner saw the end but no process result; settled, never a success. */
    outcome?: "unknown";
  }>;
};

/** One Harnesses gesture: Sign in and Check open a terminal tab with `harness login`; Update
 * (one `id`) and Update all start owner-bound native terminal jobs. `focus`: Settings came forward,
 * so an account sign-in or sign-out typed into a terminal tab since then is read back. */
export type HarnessesRun = {
  action:
    | "refresh"
    | "focus"
    | "signIn"
    | "check"
    | "registry"
    | "update"
    | "updateAll"
    | "autoUpdate"
    | "resumeUpdate"
    | "dismissUpdate"
    | "accountEnable"
    | "accountAdd"
    | "accountSignIn"
    | "accountSignOut"
    | "accountRename"
    | "accountDefault"
    | "accountRemove";
  id?: string;
  /** With every account gesture but `accountAdd`: a listed account id. */
  account?: string;
  /** With `accountAdd`: the provider family (`codex`, `claude`) that gets a new account. */
  family?: string;
  /** With `accountAdd`: `new` signs in a login folder of its own, `key` adds an API key. */
  way?: "new" | "key";
  /** With `accountAdd` and `accountRename`: its name. */
  name?: string;
  /** With `accountAdd` `key`: the key's reference (`keychain:NAME`, `env:VAR`, `file:/path`), never a key. */
  secret?: string;
  /** With `resumeUpdate` and `dismissUpdate`: the retained intent key, not a new operation id. */
  intent?: string;
  /** With `autoUpdate` (for `id`) and `accountEnable` (for `account`): turn it on or off. */
  on?: boolean;
  /** With `refresh`: the daemon checks every harness again (after an update). */
  recheck?: boolean;
};

/** Settings > Accounts > Cloud Environments (`cmux.settings.environments.state`,
 * plans/cmux-next/cloud-environments-DESIGN.md): the team's environments on the cmux-next Cloud path.
 * `status` is CloudDO's; the page localizes it. `error` texts come from the host. */
export type CloudEnvironmentStatus = "unbuilt" | "building" | "ready" | "stale" | "failed";
/** A plain variable (baked into the snapshot) or a secret (a vault item's name; its value never
 * enters the snapshot), as CloudDO's `CloudEnvironmentVariable`. */
export type CloudEnvironmentVariable = { name: string; value: string } | { name: string; secret: string };
export type CloudEnvironmentRow = {
  id: string;
  name: string;
  repo: string | null;
  setup_script: string;
  /** Absent from a host that predates variables. */
  env?: CloudEnvironmentVariable[];
  status: CloudEnvironmentStatus | string;
  /** The last failed build's message and its log tail; null otherwise. */
  error: string | null;
  log_tail: string | null;
};
export type CloudEnvironmentsState = {
  /** False on the classic Cloud path or while signed out: the card explains instead of listing. */
  available: boolean;
  loading: boolean;
  environments: CloudEnvironmentRow[];
  error: string | null;
};
/** One Cloud Environments gesture: Refresh, Save (create, or edit with `id`), Build, Delete. */
export type CloudEnvironmentsRun =
  | { action: "refresh" }
  | {
      action: "save";
      id?: string;
      /** Required to create; an edit sends it only when renamed. */
      name?: string;
      repo?: string;
      setup_script?: string;
      /** The whole list; absent leaves it as it is. */
      env?: CloudEnvironmentVariable[];
    }
  | { action: "build"; id: string }
  | { action: "delete"; id: string };

/** Settings > Server > This Mac on Your Tailnet: acpmux's embedded tailnet node as `_acpmux/tailnet/*`
 * answers it (cmux-tui acpmux tailnet/embedded.rs `Snapshot::to_json`), relayed unchanged by the app on
 * its person connection. */
export type TailnetState = {
  /** `stopped`, `starting`, `needs_login`, `needs_machine_auth`, `running` or `error` (or another
   * backend state, shown as signed out). */
  state: string;
  /** The sign-in page while `needs_login`; only the person's own connection is sent it. */
  browse_to_url?: string;
  /** This Mac's MagicDNS name while running. */
  dns_name?: string;
  ips?: string[];
  /** acpmux's own text for the last failure. */
  error?: string;
};

/** One entry of the customize library (`cmux --json customize library`; cmux-customize
 * `library.rs` `Listed`): something the person applied, kept as a layer they turn on and off. */
export type LibraryEntry = {
  /** 1 is the top: it wins over every entry below it. */
  position: number;
  name: string;
  on: boolean;
  /** How it came in: `ask`, `profile`, `try-on`, `by hand`, `import`. */
  source: string;
  /** The words that asked for it, oldest first. */
  words: string[];
  description: string;
  /** What it looks like at a glance: the colors it sets and the keys it sets (no capture). */
  thumbnail: { swatches: string[]; keys: string[] };
  settings: string[];
  files: string[];
  added_ms: number | null;
  /** Keys and files a higher entry that is on sets too, so this one's value is not in use. */
  overridden: string[];
};

/** Two or more entries that are on set the same key or file; the highest one's value is in use. */
export type LibraryConflict = { kind: string; key: string; winner: string; losers: string[] };

/** The library, top first. */
export type LibraryListing = { entries: LibraryEntry[]; conflicts: LibraryConflict[] };

/** A library verb the page runs. `order` takes `position` (`top`, `bottom` or a number from 1). */
export type LibraryRun =
  | { verb: "list" }
  | { verb: "on" | "off" | "remove"; name: string }
  | { verb: "order"; name: string; position: string };

/** `cmux --json customize library …` as the host answers it: a listing (`library`), and for a
 * change what it did; a refusal is the CLI's error envelope (`code`, `message`). */
export type LibraryAnswer = {
  library?: LibraryListing;
  generation?: unknown;
  code?: string;
  message?: string;
};

/** A customization being tried on (`cmux customize try`; cmux-customize `try_on.rs`): applied now,
 * back to generation `revert_to` by itself at `expires_ms` unless the person keeps it. */
export type CustomizeTryOn = {
  generation: number;
  revert_to: number | null;
  started_ms: number;
  expires_ms: number;
  /** What is tried on, in one line (the profile, or what was asked for). */
  label: string;
  origin: string;
};

/** `cmux --json customize status|keep|revert` as the host answers it: a status carries `try_on`; a
 * refusal is the CLI's error envelope (`code`, `message`). */
export type CustomizeAnswer = { try_on?: CustomizeTryOn | null; code?: string; message?: string };

/** Settings > Privacy and Security > Shared Links (`cmux.settings.shares.list`): this Mac's daemon's
 * chat shares as `agent-session-share-list` answers them (cmux-tui server/agent_session_shares.rs),
 * and each chat's tab title by surface number. Times are milliseconds since the epoch. */
export type ShareGuestWire = {
  guest_id: string;
  name: string;
  joined_at: number;
  /** `active`, `kicked` or `left`. */
  state: string;
  account?: string;
  role?: string;
};
export type ShareInviteeWire = { account: string; role: string; invited_at: number; state: string };
export type ShareWire = {
  share_id: string;
  /** `provisioning`, `active`, `revoked`, `expired` or `closed`. */
  state: string;
  session: string;
  surface: number;
  created_at: number;
  expires_at: number;
  uses_left: number;
  invite_url?: string | null;
  guests: ShareGuestWire[];
  invitees?: ShareInviteeWire[];
};
export type SharesState = {
  /** False when this Mac's daemon is not connected: the card says so instead of listing. */
  available: boolean;
  shares?: ShareWire[];
  /** A chat's tab title by its surface number; a chat with no open tab has none. */
  titles?: Record<string, string>;
};

/** Settings > Keys (`cmux.settings.keys.list`): what `cmux keys ls --json` lists (cmux-tui
 * cli/key_broker.rs) and the key requests agents sent with `cmux keys request` that wait for the
 * person. A record never carries a value. Times are RFC 3339 (UTC, `Z`). Older records may lack
 * the newer fields, so each is optional here and read defensively (keys.ts). */
export type KeyUseWire = { target: string; last_used_at?: string | null; count?: number };
export type KeyRecordWire = {
  id: string;
  /** What to show; older records have none (keys.ts falls back to the name, bucket or id). */
  label?: string | null;
  /** Local keys only: the `[A-Z_][A-Z0-9_]*` name agents use. */
  name?: string | null;
  /** `local` or `cloudflare`. */
  provider?: string;
  /** `secret` or `r2`. */
  kind?: string;
  /** `stdin`, `generated`, `person` or `cloudflare`. */
  source?: string;
  bucket?: string | null;
  purpose?: string | null;
  /** The sites the key may be sent to; empty: any. */
  hosts?: string[];
  /** Where copies were written (`gh-secret:owner/repo:NAME`, `file:/path`). */
  stores?: string[];
  uses?: KeyUseWire[];
  /** Who stored or minted it (`CLAUDE_CODE_SESSION_ID=…`, `user=leo`). */
  by?: string | null;
  asked_by?: string | null;
  created_at?: string | null;
  expires_at?: string | null;
  /** `live`, `expired` or `revoked`. */
  state?: string;
};
/** One `keys.request` waiting for the person; the app keeps it in memory only. */
export type KeyRequestWire = {
  id: string;
  name: string;
  purpose: string;
  hosts: string[];
  /** Who asked, as the CLI names it (`CLAUDE_CODE_SESSION_ID=…`). */
  requester: string;
  asked_at: string;
};
export type KeysState = {
  /** False when this build's `cmux` could not list keys: the card says so instead of the list. */
  available?: boolean;
  requests: KeyRequestWire[];
  keys: KeyRecordWire[];
};

/** Settings > Devices (`cmux.settings.devices.state`): this Mac and the person's other devices on
 * the device hub, Mac Screen access to this Mac, relays and the access history. The host sends
 * every text localized; the page draws and forwards each gesture (`cmux.settings.devices.run`). */
export type DevicesTone = "success" | "attention" | "danger" | "neutral";
export type DevicesScope = "none" | "ask" | "view" | "full";
export type DevicesState = {
  /** The device hub is configured in this build (deviceHub.url set). */
  available: boolean;
  /** Connection line under the header: "Connected", "Connecting…", "Not signed in", "Off" … */
  status: { text: string; tone: DevicesTone };
  /** Button title when this Mac left the hub (it removed itself) and may sign in again; else null. */
  signIn: string | null;
  /** The last failure, localized; null when none. */
  error: string | null;
  labels: DevicesLabels;
  thisDevice: DevicesDevice | null;
  others: DevicesDevice[];
  /** "Allow Mac Screen on this Mac"; null until this Mac is registered. */
  sharing: { on: boolean; busy: boolean; permissions: DevicesPermission[] } | null;
  relays: DevicesRelay[];
  /** Newest first. */
  history: DevicesHistoryRow[];
};
export type DevicesPermissionId = "screenRecording" | "accessibility";
export type DevicesPermission = { id: DevicesPermissionId; title: string; detail: string; granted: boolean };
export type DevicesDevice = {
  id: string;
  name: string;
  /** Localized platform: "Mac", "iPhone". */
  platform: string;
  /** Display fingerprint ("1A2B 3C4D …"), null when unknown. */
  fingerprint: string | null;
  /** The whole fingerprint (lowercase hex SHA-256 of the signing key) for the tooltip and Copy. */
  fingerprintFull: string | null;
  online: boolean;
  /** "Online", "Offline · seen 5 minutes ago". */
  presence: string;
  thisDevice: boolean;
  /** Whether it shares its Mac Screen; with a localized note when it does ("Shares Mac Screen"). */
  sharesText: string | null;
  /** This device's Mac Screen access to THIS Mac (null for this device). */
  access: DevicesScope | null;
  /** A compact first-class Mac Screen action; absent for phones and older hosts. */
  screenAction?: { kind: "view" | "share"; title: string; disabled?: boolean } | null;
  /** Removal confirmation texts for this row. */
  removeConfirm: { title: string; body: string; confirm: string };
};
export type DevicesRelayMode = "shared_secret" | "static";
export type DevicesRelay = {
  id: string;
  name: string;
  urls: string[];
  mode: DevicesRelayMode;
  /** Localized mode: "Shared secret", "Username and password". */
  modeText: string;
  enabled: boolean;
  priority: number;
  /** This Mac holds the relay's secret (it can use and check it). */
  hasSecret: boolean;
  checking: boolean;
  /** The last Check Relay result, null when never checked. */
  check: { tone: DevicesTone; text: string } | null;
};
export type DevicesHistoryRow = {
  id: string;
  /** Localized date and time. */
  time: string;
  /** Raw audit event (shared, unshared, requested, approved, denied, started, ended,
   * permission_changed, device_added, device_removed) for styling, and its localized pill text. */
  event: string;
  eventText: string;
  tone: DevicesTone;
  /** Viewer device name (or "—"). */
  device: string;
  /** Host device name (or "—"). */
  host: string;
  /** Localized scope ("View only", "Full control", "—"). */
  scope: string;
  detail: string;
  /** "22m 27s" or "". */
  duration: string;
};
export type DevicesLabels = {
  thisDeviceSection: string;
  thisDeviceBadge: string;
  othersSection: string;
  noOthers: string;
  fingerprint: string;
  rename: string;
  renameTitle: string;
  nameField: string;
  save: string;
  cancel: string;
  remove: string;
  access: string;
  accessOptions: Array<{ value: DevicesScope; title: string }>;
  sharingSection: string;
  sharingToggle: string;
  sharingDetail: string;
  openSettings: string;
  allowed: string;
  relaysSection: string;
  relaysEmpty: string;
  relaysHelp: string;
  addRelay: string;
  editRelay: string;
  deleteRelay: string;
  deleteRelayTitle: string;
  deleteRelayBody: string;
  checkRelay: string;
  relayOff: string;
  relayName: string;
  relayURLs: string;
  relayURLsHelp: string;
  relayMode: string;
  modeOptions: Array<{ value: DevicesRelayMode; title: string }>;
  relaySecret: string;
  relaySecretKeep: string;
  relayUsername: string;
  relayPassword: string;
  relayEnabled: string;
  relayPriority: string;
  relayPriorityHelp: string;
  historySection: string;
  historyEmpty: string;
  historyColumns: {
    time: string;
    event: string;
    device: string;
    host: string;
    scope: string;
    detail: string;
    duration: string;
  };
  refresh: string;
  /** The Copy button beside a fingerprint. */
  copy: string;
};
export type DevicesRelayDraft = {
  /** Absent for a new relay. */
  id?: string;
  name: string;
  urls: string[];
  mode: DevicesRelayMode;
  /** shared_secret mode; empty/absent on edit keeps the saved secret. */
  secret?: string;
  /** static mode; both empty/absent on edit keep the saved credentials. */
  username?: string;
  password?: string;
  enabled: boolean;
  priority: number;
};
export type DevicesRun =
  | { action: "refresh" }
  | { action: "openScreen"; id: string }
  | { action: "shareThisMac"; id: string }
  | { action: "signIn" }
  | { action: "rename"; id: string; name: string }
  | { action: "remove"; id: string }
  | { action: "setAccess"; id: string; scope: DevicesScope }
  | { action: "setSharing"; on: boolean }
  | { action: "openPermission"; id: DevicesPermissionId }
  | { action: "saveRelay"; relay: DevicesRelayDraft }
  | { action: "checkRelay"; id?: string; relay?: DevicesRelayDraft }
  | { action: "deleteRelay"; id: string };
/** `error`: a localized failure to show near the control; `text`: a result line (Check Relay). */
export type DevicesRunResult = { error?: string; text?: string; ok?: boolean };
/** One coding agent's hooks as `cmux agent hook status` reports them (Settings > Agents >
 * Agent integrations). `conflict`: a file cmux did not create is in the way (install refuses
 * it); `unavailable`: the file could not be read. */
export type IntegrationRow = {
  id: string;
  path: string;
  state: "installed" | "partial" | "absent" | "conflict" | "unavailable";
  /** For `conflict` / `unavailable`: what is in the way. */
  reason: "symlink" | "not_a_file" | "not_a_directory" | "not_owned" | "unreadable" | null;
  /** The CLI's own (English) text for a conflict. */
  detail: string | null;
  /** The CLI's refusal of this row's last gesture, in the CLI's own words. */
  error: string | null;
  /** When the CLI gave no words of its own: `noAnswer` (it did not answer) or `notFinished`
   * (it failed without saying why); the page shows its localized text. Absent from older hosts. */
  errorKind?: "noAnswer" | "notFinished" | null;
};

/** One coding agent of Settings > Agents > Agents on This Mac: whether it gets cmux's MCP server when
 * cmux starts it (`cmux setup mcp`). The name is the product's own, never translated. */
export type AgentToolsCardRow = {
  id: string;
  name: string;
  /** `terminals`: started in cmux, it gets cmux's tools; `ready`: not yet (the answer is not on). */
  state: "ready" | "terminals" | "failed";
  /** The line that removes a `cmux` entry in the agent's own settings that runs `cmux mcp serve`, used
   * outside cmux (not this build's own manual line); null or absent for none. Remove runs it only on
   * the person's click. */
  leftover?: string | null;
};

/** Agents on This Mac (`SettingsAgentTools.state`). */
export type AgentToolsCardState = {
  /** The first read answered (an empty list then says none was found). */
  loaded: boolean;
  /** Turn On runs. */
  applying: boolean;
  /** The answer could not be saved. */
  failed: boolean;
  /** `agents.cmuxMcp` now. Absent from older hosts. */
  choice?: "ask" | "on" | "off";
  rows: AgentToolsCardRow[];
  /** The lines a person runs themselves to use cmux's tools in agents started elsewhere (cmux never
   * runs them). Absent from older hosts. */
  manual?: string[];
  /** Why the last Remove kept the entry (it holds settings cmux could not put back), as the CLI
   * says it; null or absent otherwise. */
  note?: string | null;
};

/** One Agents on This Mac gesture; `turnOn` and `removeLeftover` run only on a click. */
export type AgentToolsCardRun = { action: "refresh" | "turnOn" } | { action: "removeLeftover"; id: string };

/** The Agent integrations part (`SettingsAgentIntegrations.state`). */
export type IntegrationsState = {
  loading: boolean;
  /** `unavailable`: this build carries no cmux CLI; `failed`: status did not answer. */
  problem: "unavailable" | "failed" | null;
  /** The command to run by hand (`cmux agent hook install`); a row appends its id. */
  command: string;
  providers: IntegrationRow[];
};

/** One saved MCP server (Settings > MCP Servers; optchat-chief `settings_row`). Never a secret. */
export type McpServerRow = {
  name: string;
  /** `remote`: a URL; `local`: a command on this Mac. */
  kind: "remote" | "local";
  address: string;
  /** The publisher's domain, or `local`. */
  publisher: string;
  /** The address is exactly the one cmux knows for that service. */
  verified: boolean;
  state: "connected" | "signInNeeded" | "failed" | "unknown";
  /** Why the last connect failed, in the server's own words. */
  problem: string | null;
  /** Who has it, as the person chose on the connect card. */
  scope: "chat" | "chief" | "allChiefs" | "agents" | "everywhere";
  tools: number;
  /** A sign-in waits for the person; `page` is its sign-in page. */
  signingIn: boolean;
  page: string | null;
  /** The last gesture's refusal ("" when it gave no words of its own). */
  error: string | null;
};

/** Settings > MCP Servers (`SettingsMcpServers.state`). */
export type McpServersState = {
  loading: boolean;
  /** `unavailable`: this build has no Chief helper; `failed`: the list did not answer. */
  problem: "unavailable" | "failed" | null;
  servers: McpServerRow[];
};

/** One MCP Servers gesture; sign in and remove run only on a click. */
export type McpServersRun = { action: "refresh" } | { action: "signin" | "remove"; name: string };

/** A coding agent whose own settings Settings > Agents > Claude Code & Codex shows. */
export type AgentConfigAgent = "claude" | "codex";

/** One config file the agent reads (`cmux agent-config settings get`): its scope (`managed`,
 * `user`, `project`, `local`, `profile:NAME`), whether it exists and how many keys it holds. */
export type AgentConfigFile = {
  scope: string;
  label: string;
  path: string;
  exists: boolean;
  writable: boolean;
  keys: number;
  error: string | null;
};

/** One effective leaf setting: `display` is short and already masked for secrets (`masked`). */
export type AgentConfigEntry = {
  key: string;
  display: string;
  scope: string;
  path: string;
  overridden: { scope: string; display: string }[];
  masked: boolean;
  curated: boolean;
};

/** One setting the card edits: `choice` offers only `choices`; for `text` they are suggestions.
 * `value` and `scope` are null when unset (the agent's default applies). */
export type AgentConfigCurated = {
  key: string;
  title: string;
  kind: "text" | "choice";
  choices: string[];
  value: string | null;
  scope: string | null;
  writableScopes: string[];
};

/** `cmux --json agent-config settings get --agent A`: the agent's settings as it sees them. */
export type AgentConfigState = {
  agent: AgentConfigAgent;
  files: AgentConfigFile[];
  entries: AgentConfigEntry[];
  curated: AgentConfigCurated[];
  /** Codex's NAME.config.toml files; an older cmux leaves it out for Claude Code. */
  profiles?: { name: string; path: string; keys: number }[];
  notes: string[];
  keysOnDisk: number;
  keysShown: number;
};

/** `set` / `unset`'s answer: the file written and its backup. */
export type AgentConfigChange = {
  ok: true;
  agent: AgentConfigAgent;
  key: string;
  scope: string;
  path: string;
  backup: string | null;
};

/** One Claude Code & Codex settings call. `get` only reads; `set`, `unset` and `open` (a path a
 * fresh `get` lists in `files`) run only on the person's click. */
export type AgentConfigRun = {
  verb: "get" | "set" | "unset" | "open";
  agent: AgentConfigAgent;
  key?: string;
  value?: string;
  scope?: string;
  path?: string;
};

/** What the host answers: the state, a change, `{ok}` for an open, `{enabled: false}` while
 * `labs.agentCustomization` is off, or the CLI's refusal envelope. */
export type AgentConfigAnswer =
  | AgentConfigState
  | AgentConfigChange
  | { ok: true }
  | { enabled: false }
  | { code: string; message: string };

/** One skill or slash command an agent loads (`cmux agent-config skills list --json`). */
export type AgentSkillRow = {
  agent: "claude" | "codex";
  kind: "skill" | "command";
  scope: "user" | "project" | "plugin" | "system" | "admin";
  /** What the person types after `/` (Claude Code) or `$` (Codex). */
  name: string;
  description: string;
  /** The SKILL.md or command file: what Edit opens. */
  path: string;
  /** `plugin@marketplace` for a plugin's. */
  plugin?: string;
  enabled: boolean;
  /** Claude Code's `skillOverrides` value, when one is set. */
  override?: string;
  /** The agent's own settings file the switch writes; absent: the agent has no switch for it. */
  switchFile?: string;
};

/** Settings > Agents > Claude Code & Codex > Skills (`SettingsAgentSkills.state`); Labs `labs.agentCustomization`. */
export type AgentSkillsState =
  | { enabled: false }
  | {
      enabled: true;
      loading: boolean;
      /** `unavailable`: no bundled CLI; `failed`: the list did not answer. */
      problem: "unavailable" | "failed" | null;
      skills: AgentSkillRow[];
      /** Files an agent skips, in its own words. */
      problems: Array<{ agent: "claude" | "codex"; path: string; message: string }>;
      /** `files` (cmux read the folders) or `app-server` (Codex's own list). */
      sources: { claude: string; codex: string } | null;
      elapsedMs: number | null;
      /** The CLI's refusal of the last switch ("" with no words of its own). */
      refusal: { path: string; message: string } | null;
    };

/** One Skills gesture; on and off run only on a click. */
export type AgentSkillsRun =
  | { action: "refresh" }
  | { action: "open" | "reveal"; path: string }
  | { action: "on" | "off"; path: string; agent: "claude" | "codex" };

/** One MCP server Claude Code or Codex starts, from its own config files (`cmux agent-config mcp
 * list --json`, cmux-agent-customize `mcp.rs`). Never a secret: env and header values are names only. */
export type AgentMcpServer = {
  agent: "claude" | "codex";
  name: string;
  /** `user`: every folder; `local`: Claude, this folder only; `project`: the folder's own file; `plugin`: Codex, a plugin's. */
  scope: "user" | "local" | "project" | "plugin";
  transport: "stdio" | "http" | "sse";
  command: string | null;
  /** Arguments, a secret-looking flag's value masked. */
  args: string[];
  /** The URL without its password. */
  url: string | null;
  /** Whether the agent starts it (in the shown folder, for Claude's per-folder switches). */
  enabled: boolean;
  /** Claude project servers: approved in Claude, or waiting for the person there. */
  approval?: "approved" | "pending";
  env: string[];
  headers: string[];
  file: string;
  plugin?: string;
  /** Another scope's server of the same name runs instead. */
  shadowed: boolean;
  removable: boolean;
};

/** Settings > MCP Servers, Claude Code and Codex (`SettingsAgentMcpServers.state`); `enabled` false
 * while Labs `labs.agentCustomization` is off, and then nothing else. */
export type AgentMcpState = {
  enabled: boolean;
  loading?: boolean;
  /** `unavailable`: no bundled cmux CLI; `failed`: the list did not answer. */
  problem?: "unavailable" | "failed" | null;
  /** The folder Claude's per-folder switches and the project files are read for. */
  project?: string;
  servers: AgentMcpServer[];
  problems?: { agent: string; why: string }[];
  /** The last edit's refusal, for the row `agent:scope:name`. */
  error?: { key: string; why: string } | null;
  /** The last list: click to rows, and the CLI's own share (ms). */
  listMs?: number | null;
  cliMs?: number | null;
};

/** One Claude Code / Codex MCP gesture; all but refresh run only on a click. */
export type AgentMcpRun =
  | { action: "refresh" | "pickFolder" }
  | {
      action: "enable" | "disable" | "remove";
      agent: AgentMcpServer["agent"];
      name: string;
      scope: AgentMcpServer["scope"];
    }
  | {
      action: "add";
      agent: AgentMcpServer["agent"];
      name: string;
      scope: "user" | "local" | "project";
      command?: string;
      args?: string[];
      url?: string;
      transport?: "http" | "sse";
      /** `KEY=VALUE` lines. */
      env?: string[];
      headers?: string[];
    };

/** One Claude Code or Codex hook handler (`cmux --json agent-config hooks list`, cmux-agent-customize hooks.rs `HookEntry`). */
export type AgentHookRow = {
  /** Stable across Turn Off / Turn On; the CLI's handle for the row. */
  id: string;
  agent: "claude" | "codex";
  /** `user` (~/.claude/settings.json, ~/.codex/hooks.json), `user-local`, `user-config`, `project`,
   * `project-local` or `plugin`. */
  scope: string;
  file: string;
  event: string;
  matcher: string | null;
  type: string;
  command: string;
  timeout: number | null;
  enabled: boolean;
  /** `cmux` (cmux's own, read-only), `plugin` (read-only) or `user`. */
  owner: "user" | "cmux" | "plugin";
  read_only: boolean;
  /** Codex: `trusted`, `untrusted`, `modified` or `unsupported` (Codex runs only trusted hooks). */
  trust?: string;
  /** Codex: the hooks.state key its trust and on/off live under. */
  state_key?: string;
  plugin?: string;
};

/** One config file the hooks list read. */
export type AgentHookFile = {
  agent: "claude" | "codex";
  scope: string;
  path: string;
  exists: boolean;
  hooks: number;
  error?: string;
  disable_all_hooks?: boolean;
};

/** `cmux --json agent-config hooks list`. */
export type AgentHooksListing = {
  hooks: AgentHookRow[];
  files: AgentHookFile[];
  counts: { claude: number; codex: number };
  codex_hooks_feature: boolean | null;
  disabled_store?: string;
  elapsed_micros: number;
};

/** Settings > Agents > Claude Code & Codex > Hooks (`SettingsAgentHooks.state`); `available` is the
 * Labs switch `labs.agentCustomization`. */
export type AgentHooksState =
  | { available: false }
  | { available: true; listing: AgentHooksListing | null; error: string | null };

/** One Hooks gesture; every one but refresh runs only on a click. */
export type AgentHooksRun =
  | { action: "refresh" }
  | { action: "enable" | "disable" | "remove"; id: string }
  | {
      action: "add";
      agent: "claude" | "codex";
      event: string;
      command: string;
      matcher?: string;
      timeout?: number;
      scope?: "user" | "user-local";
    };

/** One Agent integrations gesture; each runs only on a click. */
export type IntegrationsRun = { action: "refresh" } | { action: "install" | "repair" | "remove"; id: string };

/** The v2 mutation result: `revision` is a decimal string. */
export type MutationResult = { value: { keys: string[] }; revision: string; replayed: boolean };

type Mutation<P> = P & { idempotency_key: string; if_revision?: string };

/** One build on a channel's track (Settings > Updates, Channels). Every text and link is the host's. */
export type ChannelBuild = {
  build: string;
  version: string;
  date: string;
  commit: string | null;
  commit_url: string | null;
  /** GitHub's compare from the installed build's commit; null for that build or an unknown commit. */
  compare_url: string | null;
  health: "promoted" | "held" | "pulled" | "pending";
  health_title: string | null;
  pulled_reason: string | null;
  /** This Mac runs it ("You Are Here"). */
  installed: boolean;
  /** This Mac kept a copy for rollback. */
  kept: boolean;
  /** The row offers Switch (`cmux.settings.channels.switch_build`): any build but the installed
   * and pulled ones, on an app that follows a feed. Absent from older hosts. */
  switch?: boolean;
  prs: { number: number; url: string }[];
};

/** One release channel's recent builds, newest first. */
export type ChannelTrack = {
  ring: "stable" | "nightly" | "canary" | "dev";
  title: string;
  followed: boolean;
  release_url: string | null;
  /** The empty track's line; null when it has builds. */
  empty: string | null;
  builds: ChannelBuild[];
};

/** The way back to a slower channel the running build is not on: Go Back into the build this
 * Mac kept (`build` and `action`), or only a line that the running build stays (both null). */
export type ChannelSwitch = {
  ring: ChannelTrack["ring"];
  build: string | null;
  action: string | null;
  detail: string;
};

/**
 * Settings > Updates' row of other machines: one line each; `updates` (beside `lines`) is the id
 * the line's Update button sends (`cmux.settings.channels.update_machine`), null for no button.
 * An app that offers no button sends neither `updates` nor `updateLabel`.
 */
export type ChannelMachines = { title: string; lines: string[]; updates?: (string | null)[]; updateLabel?: string };

/**
 * A Switch or Go Back the host is running (`cmux.settings.channels.switch.changed`): `build` is the
 * build it restarts into (Go Back's: the kept build), `label` the host's text for the stage it is
 * at ("Downloading… 42%", "Checking the download…", "Restarting…"), `fraction` 0..1 while it
 * downloads, else null.
 */
export type ChannelsProgress = { build: string; label: string; fraction: number | null };

/** Settings > Updates' Channels card (`cmux.settings.channels.state`). */
export type ChannelsState = {
  title: string;
  installed: string;
  switch: ChannelSwitch | null;
  labels: {
    you_are_here: string;
    following: string;
    kept: string;
    compare: string;
    commit: string;
    release: string;
    /** The rows' Switch button; absent from older hosts. */
    switch?: string;
  };
  tracks: ChannelTrack[];
  /** The app's local acpmux daemon: its build, and whether it is up to date or restarting. */
  daemon?: { title: string; value: string } | null;
  /** Other machines the app updates that cannot update in place or whose update failed, one line each. */
  machines?: ChannelMachines | null;
  /** The switch running when the card reads; null or absent: none (older hosts send none). */
  progress?: ChannelsProgress | null;
};

/** Every op the page calls: params and result. */
export type SettingsOps = {
  "cmux.settings.list": [{ section?: string }, ListRow[]];
  "cmux.settings.snapshot": [Record<string, never>, SnapshotResult];
  "cmux.settings.set": [Mutation<{ key: string; value: unknown }>, MutationResult];
  "cmux.settings.reset": [Mutation<{ key: string }>, MutationResult];
  "cmux.settings.reset_all": [Mutation<object>, MutationResult];
  /** Native: spaces, machines and browser profiles from the app's live stores. */
  "cmux.settings.host.lists": [Record<string, never>, HostLists];
  /** Native: every release channel's recent builds, read on demand (Settings > Updates). */
  "cmux.settings.channels.state": [{ ring?: string }, ChannelsState];
  /** Native: the card's Go Back: restarts once into a kept build of a slower channel (the person's gesture only). */
  "cmux.settings.channels.go_back": [{ ring: string; build: string }, Record<string, never>];
  "cmux.settings.channels.update_machine": [{ id: string }, Record<string, never>];
  /** Native: a build row's Switch: restarts once into that build, older or newer, downloading it
   * first unless it is kept (the person's gesture only). */
  "cmux.settings.channels.switch_build": [{ build: string }, Record<string, never>];
  /** Native: Settings > Mobile's Remove: the phone leaves the account's devices (the person's gesture only). */
  "cmux.settings.mobile.remove_phone": [{ id: string }, Record<string, never>];
  /** Native: Settings > Devices' Remove: the device leaves every store that lets it in (the person's gesture only). */
  "cmux.settings.devices.remove": [{ id: string }, { error?: string }];
  /** Native: Settings > Devices' Full access switch on a paired client machine (the person's gesture only). */
  "cmux.settings.devices.full_access": [{ id: string; on: boolean }, { error?: string }];
  /** Native: Settings > Machines' "Dedicated agent machine" switch on a Cloud machine (on: the person's gesture only). */
  "cmux.settings.machines.vm_host": [{ id: string; on: boolean }, { error?: string }];
  /** Native: Settings > Devices' consent switch of this joined Mac (Screen sharing, Control, Your other Macs) (on: the person's gesture only). */
  "cmux.settings.devices.join_consent": [{ surface: JoinConsentSurface; on: boolean }, { error?: string }];
  /** Native: after the owner removed this Mac, allow iPhone connections again (a new device; the person's gesture only). */
  "cmux.settings.mobile.allow_again": [Record<string, never>, Record<string, never>];
  /** Native: Settings > Server's Restart…: opens the host's confirm, never restarts by itself (the person's gesture only). */
  "cmux.settings.server.restart": [{ kind: string; host?: string | null }, Record<string, never>];
  /** Native: Settings > Server's Pair: opens the Server panel's pairing card (the person's gesture only). */
  "cmux.settings.server.pair": [Record<string, never>, Record<string, never>];
  /** A phone's pairing request: Allow or Don't Allow (the person's own gesture only). */
  "cmux.settings.mobile.answer_pair": [{ id: string; allow: boolean }, Record<string, never>];
  /** Native: Updates > App Update's buttons (Restart to Update only on the person's own click); the host lists follow. */
  "cmux.settings.app_update.run": [{ action: AppUpdateAction }, Record<string, never>];
  /** Native: Updates > Web UI's Check Now (updates.web.check); the host lists follow the check. */
  "cmux.settings.web_updates.check": [Record<string, never>, Record<string, never>];
  /** Native: Updates > Web UI's Roll Back (updates.web.rollback), from the next safe point. */
  "cmux.settings.web_updates.rollback": [Record<string, never>, Record<string, never>];
  /** Native: General > Language's Relaunch: the app relaunches so its menus take app.language (the person's gesture only). */
  "cmux.settings.language.relaunch": [Record<string, never>, Record<string, never>];
  /** Native: Settings > Chief > Voice input's switch writes home.voiceInput (the person's gesture only). */
  "cmux.settings.voice_input.set": [{ on: boolean }, Record<string, never>];
  /** Native: Settings > Menus saves a menu's arrangement; null (Reset) removes it (the person's gesture only). */
  "cmux.settings.context_menus.set": [{ menu: string; layout: MenuLayout | null }, Record<string, never>];
  /** Native: Settings > Menus turns Customize Menu… at the end of every menu on or off. */
  "cmux.settings.context_menus.show_item": [{ show: boolean }, Record<string, never>];
  /** Native: the Accounts part (providers, linked accounts, forms). */
  "cmux.settings.accounts.state": [Record<string, never>, AccountsState];
  /** Native: one Accounts gesture; a failed Keychain save answers its message. */
  "cmux.settings.accounts.run": [AccountsRun, { error?: string }];
  /** Native: Settings > Agents, the harnesses acpmux knows and the last doctor answers. */
  "cmux.settings.agents.state": [Record<string, never>, AgentsState];
  /** Native: one Agents gesture; a daemon refusal rejects with `cmux.agents.<code>` and its text. */
  "cmux.settings.agents.run": [AgentsRun, unknown];
  /** Native: Settings > Models, the person's and the organization's connections (model-connections.md). */
  "cmux.settings.models.state": [Record<string, never>, ModelsState];
  /** Native: one Settings > Models gesture; a refusal rejects with the host's text. */
  "cmux.settings.models.run": [ModelsRun, unknown];
  /** Native: the dictation engine's key and connection check (`_acpmux/voice/*` through the app; the key
   * goes to the Keychain). `check` answers a DictationCheck, every other gesture a DictationState. */
  "cmux.settings.dictation.run": [DictationRun, DictationState | DictationCheck];
  /** Native: acpmux's harnesses (Settings > Agents). */
  "cmux.settings.harnesses.state": [Record<string, never>, HarnessesState];
  /** Native: one Harnesses gesture (a terminal tab for sign-in, or a refresh). */
  "cmux.settings.harnesses.run": [HarnessesRun, unknown];
  /** Native: Settings > Accounts > Cloud Environments (CloudDO through the Cloud app server). */
  "cmux.settings.environments.state": [Record<string, never>, CloudEnvironmentsState];
  /** Native: one Cloud Environments gesture; Build and Delete ask natively first; a failure answers `error`. */
  "cmux.settings.environments.run": [CloudEnvironmentsRun, { error?: string | null }];
  /** Native: this Mac's tailnet node; null when acpmux has no tailnet or did not take the person's proof. */
  "cmux.settings.tailnet.state": [Record<string, never>, TailnetState | null];
  /** Native, the person's click: starts the node; a saved login resumes, else it reports `needs_login`. */
  "cmux.settings.tailnet.start": [Record<string, never>, TailnetState | null];
  /** Native, the person's click: a fresh sign-in page for a running node that is not signed in. */
  "cmux.settings.tailnet.login": [Record<string, never>, TailnetState | null];
  /** Native, the person's click: signs the node out and closes its listeners. */
  "cmux.settings.tailnet.logout": [Record<string, never>, TailnetState | null];
  /** Native: one `cmux customize` verb through the bundled CLI, for the try-on bar. */
  "cmux.settings.customize.run": [{ verb: "status" | "keep" | "revert" }, CustomizeAnswer];
  /** Settings > Team > Compute: the team's Cloud allotment, who uses what, and the scheduler's
   * proposal (the backend's `cloud.allotment.get`). Only the mock provider serves it today. */
  "cmux.settings.cloud.allotment.get": [Record<string, never>, AllotmentView];
  /** Settings > Team > Compute, an admin's one click: scale down, hold or scale up, and Auto (the
   * backend's `cloud.allotment.set`); answers the view after it. */
  "cmux.settings.cloud.allotment.set": [AllotmentSet, AllotmentView];
  /** Native: this Mac's chat shares (Settings > Privacy and Security > Shared Links). */
  "cmux.settings.shares.list": [Record<string, never>, SharesState];
  /** Native: the share stops working and its guests leave at once; a daemon refusal rejects. */
  "cmux.settings.shares.revoke": [{ share_id: string }, unknown];
  /** Native: one `cmux customize library` verb through the bundled CLI (Appearance >
   * Customization Library). A change runs only on the person's click or key in the page. */
  "cmux.settings.customize.library": [LibraryRun, LibraryAnswer];
  /** Native: Settings > Keys: this Mac's keys (`cmux keys ls`, never a value) and the waiting requests. */
  "cmux.settings.keys.list": [Record<string, never>, KeysState];
  /** Native, the person's click: the value goes to `cmux keys put` on stdin only, and the agent's
   * waiting `cmux keys request` is answered; a refusal rejects and the request stays. */
  "cmux.settings.keys.answer": [{ request_id: string; value: string }, { stored: boolean; name?: string }];
  /** Native, the person's click: the agent's request ends as declined. */
  "cmux.settings.keys.decline": [{ request_id: string }, unknown];
  /** Native, the person's click: a local key's value is deleted (its record stays, revoked); a
   * provider key is deleted at the provider. */
  "cmux.settings.keys.revoke": [{ id: string }, unknown];
  /** Native: Settings > Agents > Worktree Setup, the session host's `project.list`,
   * `git.worktree.setup` and (on your click) `project.update` field `worktree`, on the app's own
   * connection: a page may not reach them itself. */
  "cmux.settings.worktree.list": [{ limit?: number }, unknown];
  "cmux.settings.worktree.read": [{ path: string }, unknown];
  "cmux.settings.worktree.save": [Mutation<{ path: string; worktree: WorktreeRecipe | null }>, unknown];
  /** Native: Settings > Devices; rejects with `cmux.page.unavailable` when the host has no device hub. */
  "cmux.settings.devices.state": [Record<string, never>, DevicesState];
  /** Native: one Devices gesture; a failure answers its localized text in `error`. */
  "cmux.settings.devices.run": [DevicesRun, DevicesRunResult];
  /** Native: the coding-agent hooks `cmux agent hook status` reports (Settings > Agents). */
  "cmux.settings.integrations.state": [Record<string, never>, IntegrationsState];
  /** Native: one Agent integrations gesture (`agent hook install|uninstall <id>`, or a refresh). */
  "cmux.settings.integrations.run": [IntegrationsRun, unknown];
  /** Native: the coding agents and whether their configs hold cmux's MCP server (Settings > Agents). */
  "cmux.settings.agentTools.state": [Record<string, never>, AgentToolsCardState];
  /** Native: Turn On (`agents.cmuxMcp` on), Remove an agent's old cmux entry (`cmux setup mcp --remove ID`) or a refresh. */
  "cmux.settings.agentTools.run": [AgentToolsCardRun, AgentToolsCardState];
  /** Native: the person's saved MCP servers (Settings > MCP Servers). */
  "cmux.settings.mcp.state": [Record<string, never>, McpServersState];
  /** Native: one MCP Servers gesture (`optchat-chief integrations --json signin|remove`, or a refresh). */
  "cmux.settings.mcp.run": [McpServersRun, unknown];
  /** Native: Settings > Agents > Claude Code & Codex, one `cmux --json agent-config settings`
   * verb through the bundled CLI; `{enabled: false}` while labs.agentCustomization is off. */
  "cmux.settings.agentConfig": [AgentConfigRun, AgentConfigAnswer];
  /** Native: Claude Code's and Codex's skills and slash commands (Settings > Agents, Labs `labs.agentCustomization`). */
  "cmux.settings.agentSkills.state": [Record<string, never>, AgentSkillsState];
  /** Native: one Skills gesture (`cmux agent-config skills on|off FILE`, open, reveal, or a refresh). */
  "cmux.settings.agentSkills.run": [AgentSkillsRun, AgentSkillsState];
  /** Native: the MCP servers Claude Code and Codex start, from their own files (Labs `labs.agentCustomization`). */
  "cmux.settings.agentMcp.state": [Record<string, never>, AgentMcpState];
  /** Native: one Claude Code / Codex MCP gesture (`cmux agent-config mcp enable|disable|remove|add`, a folder pick or a refresh). */
  "cmux.settings.agentMcp.run": [AgentMcpRun, unknown];
  /** Native: every Claude Code and Codex hook (Labs labs.agentCustomization; `cmux agent-config hooks list`). */
  "cmux.settings.agentHooks.state": [Record<string, never>, AgentHooksState];
  /** Native: one Hooks gesture (`cmux agent-config hooks enable|disable|remove|add`, or a refresh); returns the state after it. */
  "cmux.settings.agentHooks.run": [AgentHooksRun, AgentHooksState];
  /** Native: set the theme of one level of the active window; `spec` null uses the Ghostty config. */
  "cmux.settings.theme.set": [{ level: string; spec: string | null }, unknown];
  /** Native: the colors of every published theme, for the theme preview and the picker's swatches. */
  "cmux.settings.theme.colors": [Record<string, never>, { themes: GhosttyTheme[] }];
  /** Native: write `base` with its saved edits as the Ghostty theme file `name` (the person only). */
  "cmux.settings.theme.save": [{ name: string; base: string; replace: boolean }, { name?: string }];
  /** Native: copy a theme file the person picks into their Ghostty themes; `token` retries a name in use. */
  "cmux.settings.theme.import": [{ token?: string; replace?: boolean }, { name?: string }];
  /** Let Themes Set Colors: the host comments out the `theme_overrides` lines and reloads the config. */
  "cmux.settings.theme.overrides.release": [Record<string, never>, { files: number }];
  /** Native: open the file of the first `theme_overrides` line in cmux's editor, at that line. */
  "cmux.settings.theme.overrides.open": [Record<string, never>, unknown];
  /** Native, person only: open the active theme file (`appearance.themeFile`) in the default editor;
   * with none active the bundled `cmux theme export --save my-look --use` makes one from the current look. */
  "cmux.settings.theme.file.open": [Record<string, never>, unknown];
  /** Native: whether typed text is a theme spec Ghostty accepts (a pair, a path). */
  "cmux.settings.theme.accepts": [{ text: string }, { accepts: boolean }];
  /** Native: the cmux picker chooses folders for a folder list row; the host writes them. */
  "cmux.settings.folders.add": [{ key: string }, { added: string[] }];
  /** The cmux picker for an image; the host copies it to the backgrounds folder and sets it. */
  "cmux.settings.backdrop.choose_image": [Record<string, never>, { id: string | null }];
  /** Native: download an https image or movie and set it as a picked file is; errors carry the
   * cmux.settings.backdrop.* refusal codes the picker words. */
  "cmux.settings.backdrop.image.link": [{ url: string }, { id: string }];
  /** Native: delete one of the person's own background images; the bytes the rest take. */
  "cmux.settings.backdrop.image.remove": [{ id: string }, { bytes: number }];
  /** Native: show one of the person's images, or the backgrounds folder, in Finder. */
  "cmux.settings.backdrop.image.reveal": [{ id?: string }, Record<string, never>];
  /** Native: the bytes the person's own background images take. */
  "cmux.settings.backdrop.image.usage": [Record<string, never>, { bytes: number; folder?: string }];
  "cmux.settings.backdrop.image.folder": [Record<string, never>, { id: string | null }];
  /** Native: the moving wallpaper that is the macOS screen saver; id null when it is not an aerial,
   * `pending` while macOS has not downloaded it. Writes nothing. */
  "cmux.settings.backdrop.image.screen_saver": [Record<string, never>, { id: string | null; pending: boolean }];
  /** Native: opens the Wallpaper pane of System Settings, where macOS downloads its wallpapers. */
  "cmux.settings.backdrop.wallpaper_settings": [Record<string, never>, Record<string, never>];
  /** Native: a workspace's own background (cx-t2x.5); `value` null follows appearance.background. */
  "cmux.settings.backdrop.workspace": [{ workspace: string }, WorkspaceBackground];
  /** Native: save a workspace's own background; null follows appearance.background again. */
  "cmux.settings.backdrop.workspace.set": [
    { workspace: string; value?: string | null; opacity?: number | null },
    unknown,
  ];
  /** Native: show `value` in that workspace's windows without saving it; `end` drops the preview. */
  "cmux.settings.backdrop.workspace.preview": [
    { workspace: string; value?: string | null; opacity?: number | null; end?: boolean },
    unknown,
  ];
  /** Browse More Art: public-domain works in open museum collections matching `query`. */
  "cmux.settings.art.search": [{ query: string }, { results: MuseumArtResult[] }];
  /** Downloads the work `key` into the backgrounds folder and sets it as the background. */
  "cmux.settings.art.use": [{ key: string }, { id: string }];
  /** Native: the buttons at the end of a section (registry titles, localized by the app). */
  "cmux.settings.section.actions": [{ section: string }, Array<{ id: string; title: string; enabled: boolean }>];
  /** Native: show the settings file in Finder. */
  "cmux.settings.file.reveal": [Record<string, never>, unknown];
  /** Native: show `value` live while a gesture runs; never written. */
  "cmux.settings.preview": [{ key: string; value: unknown }, unknown];
  /** Native: drop the live preview of `key`. */
  "cmux.settings.preview.end": [{ key: string }, unknown];
  /** Native: play a notification sound. */
  "cmux.settings.sound.play": [{ name: string }, unknown];
  /** Native: a catalog action, run with origin user (react-pages.md 1.3). */
  "cmux.app.action.run": [{ action: string; args?: Record<string, unknown>; target?: string }, unknown];
  /** Native: write text to the pasteboard (react-pages.md 1.3). */
  "cmux.app.clipboard.write": [{ text: string }, unknown];
};

export type SettingsOpName = keyof SettingsOps;

/** Streams the page subscribes to. */
export type SettingsStreams = {
  "cmux.settings.changed": { revision: number; keys: string[]; origin?: string };
  /** The Accounts part changed (the event carries the new state). */
  "cmux.settings.accounts.changed": AccountsState;
  /** Settings > Agents changed (the event carries the new state); the host watches acpmux only
   * while a page subscribes. */
  "cmux.settings.agents.changed": AgentsState;
  /** The Harnesses part changed (the event carries the new state). */
  "cmux.settings.harnesses.changed": HarnessesState;
  /** The Devices part changed (the event carries the new state). */
  "cmux.settings.devices.changed": DevicesState;
  /** Settings > Models changed (a connection, the order, a ChatGPT sign-in finishing). */
  "cmux.settings.models.changed": ModelsState;
  /** A key request arrived or ended (the page reads `cmux.settings.keys.list` again). */
  "cmux.settings.keys.changed": { revision: number };
  /** The host lists changed (the event carries the new lists). */
  "cmux.settings.host.changed": HostLists;
  /** Settings > Updates' row of other machines changed (its new value; null: none to list). */
  "cmux.settings.channels.machines.changed": ChannelsState["machines"];
  /** A Switch or Go Back moved to its next stage (null: none runs, it ended or was refused). */
  "cmux.settings.channels.switch.changed": ChannelsProgress | null;
  /** The page bridge's link to the daemon (one stream for every page). */
  "cmux.page.connection": { connected: boolean };
  /** Commands from the app's key dispatcher (the page handles no Cmd or Ctrl chords). */
  "cmux.page.command": { command: "find" | "focusSearch" | "back" | "forward" | "reset" };
};

export type SettingsStreamName = keyof SettingsStreams;

/**
 * The page client (react-pages.md 1.1, `webviews/src/pages/shared/pageClient.ts`): a call
 * rejects with an error that has `code`, `message` and optional `details` (the protocol's
 * ProtocolError). Any object with this shape works, so the page does not import the adapter.
 */
export interface SettingsClient {
  call<R>(op: string, params: unknown, opts?: { signal?: AbortSignal }): Promise<R>;
  subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void>;
}

export type WireError = { code: string; message: string; details?: Record<string, unknown> };

/** Codes the page acts on, without the namespace (`cmux.settings.managed` -> `managed`). */
export type ErrorCode =
  | "managed"
  | "invalid"
  | "removed"
  | "agent_refused"
  | "revision_conflict"
  | "idempotency_conflict"
  | "unavailable"
  | string;

const unavailableCodes = new Set(["cmux.protocol.closed", "cmux.page.unavailable", "cmux.protocol.auth_refused"]);

/** Refusals the host words for the person: the updater's (Go Back, Switch, Update) and a
 * person-only action's (RefusalStrings). Any other failure shows the plain sentence. */
export const SETTINGS_SENTENCES = {
  "cmux.page.refused": OWNER_SENTENCE,
  "cmux.app.user_only": OWNER_SENTENCE,
} as const;

/** The error a call rejected with, as a plain record (its `message` is for logs; the page shows
 * `userMessage(error)`). */
export function wireError(error: unknown): WireError {
  if (typeof error === "object" && error !== null && typeof (error as WireError).code === "string") {
    const { code, message, details } = error as WireError;
    return { code, message: typeof message === "string" ? message : code, details };
  }
  return { code: "cmux.page.unavailable", message: String(error) };
}

/** `cmux.settings.managed` -> `managed`; transport loss -> `unavailable`. */
export function errorCode(error: WireError): ErrorCode {
  if (unavailableCodes.has(error.code)) return "unavailable";
  if (error.code === "cmux.revision.conflict") return "revision_conflict";
  if (error.code === "cmux.idempotency.conflict") return "idempotency_conflict";
  const dot = error.code.lastIndexOf(".");
  return dot === -1 ? error.code : error.code.slice(dot + 1);
}

/**
 * The only catalog actions the Settings page may run through `cmux.app.action.run`; the page
 * bridge refuses every other action from this page (and the mock does too).
 */
export const settingsPageActions = [
  "palette.openCmuxSettingsFile",
  "openSettings",
  "browserProfile.new",
  "server.addServer",
  "device.add",
  "remote.newGroup",
  "browserProfile.rename",
  "browserProfile.setColor",
  "browserProfile.clearColor",
  "browserProfile.setIcon",
  "browserProfile.clearIcon",
  "browserProfile.manageExtensions",
  "browserProfile.delete",
  "browserProfile.clearBrowsingData",
  "reloadConfiguration",
  "palette.computerUse.setup",
  "palette.computerUse.restart",
  "palette.computerUse.accessibility",
  "palette.computerUse.screenRecording",
  // Settings > Computer Use > Saved Approvals: forget an app's answer or change it (args `{app_id}`,
  // `{app_id, decision}`); the host runs them through the worker's approvals control message.
  "computerUse.approval.forget",
  "computerUse.approval.set",
  "import.card",
  "importFromBrowser",
  // Settings > Mobile's Sign In, where the iPhone card says to sign in (msg 3790).
  "palette.auth.signIn",
  // A search no setting matches: Ask cmux to do this opens the Customize chat with the words.
  "customize.open",
] as const;

export type SettingsPageAction = (typeof settingsPageActions)[number];

/** v2 revisions are decimal strings in mutation results and numbers in reads. */
export function revisionNumber(value: unknown): number {
  const number = typeof value === "string" ? Number(value) : typeof value === "number" ? value : Number.NaN;
  return Number.isFinite(number) ? number : 0;
}

/** A fresh idempotency key per user write (the v2 owner replays a retried key). */
export function newIdempotencyKey(): string {
  return `settings-page-${crypto.randomUUID()}`;
}
