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

import type { GhosttyTheme } from "../../theme/ghosttyTheme";

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
  value: unknown;
  default: unknown;
  customized: boolean;
  managed: ManagedInfo | null;
  /** Chat roots retain refused entries and administrator provenance for the list editor. */
  folders?: Array<{ path: string; managed: boolean; reason: string | null }>;
  user_roots?: string[];
};

export type Diagnostic = { path: string | string[]; message: string; kind?: string };

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
   * A Cloud machine cmux made: its "Dedicated agent machine" switch (acpmux vmHost), once the machine
   * answered. Absent on every other machine (personal and SSH machines never have it). `busy`: a set is
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

/** The lists the host shows beside the schema rows; `rooms` is null when spaces are unsupported. */
export type HostLists = {
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
  /** Settings › Import: the import suggestion cards, every text localized by the host (ui/ImportCards.tsx parses it). */
  import_suggestions?: unknown;
  /** Settings > Accounts > This Mac on Your Tailnet (Labs): the daemon's own tailnet node; null while Labs is off. */
  tailnet?: TailnetState | null;
  /** Updates > Web UI: the web UI served between app updates; null unless the bundle takes them (NIGHTLY). */
  web_updates?: WebUpdatesState | null;
  /** Settings > Chief > Voice input: the Debug toggle home.voiceInput; null where it does not exist (Release). */
  voice_input?: { on: boolean } | null;
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
/** This Mac on Your Tailnet: the host's card, every text localized by the host. The sign-in link
 * never reaches the page (Reopen asks the host to open it). */
export type TailnetPhase =
  | "unavailable"
  | "signed_out"
  | "starting"
  | "waiting"
  | "needs_approval"
  | "failed"
  | "signed_in";
export type TailnetState = {
  title: string;
  phase: TailnetPhase;
  status_title: string;
  status: string;
  busy: boolean;
  error: string | null;
  /** "Limit access to your Tailscale account": on unless every tailnet member may connect. */
  limited: boolean;
  /** False until the node reads the choice: the switch shows the owner-only default, disabled. */
  limit_editable: boolean;
  limit_title: string;
  limit_help: string;
  sign_in_title: string;
  reopen_title: string;
  cancel_title: string;
  sign_out_title: string;
  address_title: string;
  copy_title: string;
  pair_title: string;
  done_title: string;
  /** `https://<name>.<tailnet>.ts.net` once signed in. */
  address?: string;
  /** After Pair: the QR code (a PNG data URL) and the `cmux host join` line it encodes. */
  pair?: { qr: string | null; command: string; help: string };
};

export type IPhoneHostState = {
  title: string;
  allowed: boolean;
  status_title: string;
  status: string;
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
export type ComputerUsePhase = "disabled_by_policy" | "off" | "unavailable" | "starting" | "ready" | "version_mismatch";

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
};

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

/** The Accounts part as the host draws it (texts already localized by the app). */
export type AccountsState = {
  teams: AccountsTeams | null;
  refresh: string;
  refreshing: boolean;
  /** cmux's own account: who is signed in, sign in, switch and sign out. */
  cmux: AccountsCmux;
  removeTitle: string;
  groups: Array<{ id: string; title: string; rows: AccountsRow[] }>;
};

/** One Accounts gesture; `secret` only for the paste form's save and send, `team` for selectTeam. */
export type AccountsRun = { action: string; provider?: string; account?: string; secret?: string; team?: string };

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
  latest?: string | null;
  outdated?: boolean;
  /** Only from evidence (a profile's check or a probe's sign-in error). */
  auth?: "signedIn" | "signedOut" | "unknown";
  /** How to update it; `elevated`: needs sudo, so the page shows `command` and never runs it. */
  update?: { command: string; elevated: boolean } | null;
  /** The update owner runs this channel (npm, Bun or native); without it Update is not offered. */
  ownerUpdate?: boolean;
  /** acpmux runs its update on its own when a check finds it outdated (off by default). */
  autoUpdate?: boolean;
  /** What auto-update last did for it. */
  lastAutoUpdate?: { ok: boolean; detail: string } | null;
};

/** The Harnesses part: acpmux's harnesses (the host reads `_acpmux/harnesses`). */
export type HarnessesState = {
  loading: boolean;
  /** `unavailable`: no acpmux in this app; `unreachable`: its daemon did not answer. */
  problem: "unavailable" | "unreachable" | null;
  harnesses: HarnessRow[];
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
 * (one `id`) and Update all start owner-bound native terminal jobs. */
export type HarnessesRun = {
  action:
    | "refresh"
    | "signIn"
    | "check"
    | "registry"
    | "update"
    | "updateAll"
    | "autoUpdate"
    | "resumeUpdate"
    | "dismissUpdate";
  id?: string;
  /** With `resumeUpdate` and `dismissUpdate`: the retained intent key, not a new operation id. */
  intent?: string;
  /** With `autoUpdate`: turn it on or off for `id`. */
  on?: boolean;
  /** With `refresh`: the daemon checks every harness again (after an update). */
  recheck?: boolean;
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

/** The Agent integrations part (`SettingsAgentIntegrations.state`). */
export type IntegrationsState = {
  loading: boolean;
  /** `unavailable`: this build carries no cmux CLI; `failed`: status did not answer. */
  problem: "unavailable" | "failed" | null;
  /** The command to run by hand (`cmux agent hook install`); a row appends its id. */
  command: string;
  providers: IntegrationRow[];
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
  health_title: string;
  pulled_reason: string | null;
  /** This Mac runs it ("You Are Here"). */
  installed: boolean;
  /** This Mac kept a copy for rollback. */
  kept: boolean;
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

/** Settings > Updates' Channels card (`cmux.settings.channels.state`). */
export type ChannelsState = {
  title: string;
  installed: string;
  switch: ChannelSwitch | null;
  labels: { you_are_here: string; following: string; kept: string; compare: string; commit: string; release: string };
  tracks: ChannelTrack[];
  /** The app's local acpmux daemon: its build, and whether it is up to date or restarting. */
  daemon?: { title: string; value: string } | null;
  /** Other machines the app updates that cannot update in place or whose update failed, one line each. */
  machines?: ChannelMachines | null;
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
  /** Native: Settings > Mobile's Remove: the phone leaves the account's devices (the person's gesture only). */
  "cmux.settings.mobile.remove_phone": [{ id: string }, Record<string, never>];
  /** Native: Settings > Devices' Remove: the device leaves every store that lets it in (the person's gesture only). */
  "cmux.settings.devices.remove": [{ id: string }, { error?: string }];
  /** Native: Settings > Devices' Full access switch on a paired client machine (the person's gesture only). */
  "cmux.settings.devices.full_access": [{ id: string; on: boolean }, { error?: string }];
  /** Native: Settings > Machines' "Dedicated agent machine" switch on a Cloud machine (on: the person's gesture only). */
  "cmux.settings.machines.vm_host": [{ id: string; on: boolean }, { error?: string }];
  /** Native: after the owner removed this Mac, allow iPhone connections again (a new device; the person's gesture only). */
  "cmux.settings.mobile.allow_again": [Record<string, never>, Record<string, never>];
  /** Native: Settings > Server's Restart…: opens the host's confirm, never restarts by itself (the person's gesture only). */
  "cmux.settings.server.restart": [{ kind: string; host?: string | null }, Record<string, never>];
  /** Native: Settings > Server's Pair: opens the Server panel's pairing card (the person's gesture only). */
  "cmux.settings.server.pair": [Record<string, never>, Record<string, never>];
  /** A phone's pairing request: Allow or Don't Allow (the person's own gesture only). */
  "cmux.settings.mobile.answer_pair": [{ id: string; allow: boolean }, Record<string, never>];
  /** Native: This Mac on Your Tailnet's buttons (the person's gesture only, Labs only). */
  "cmux.settings.tailnet.sign_in": [Record<string, never>, Record<string, never>];
  "cmux.settings.tailnet.cancel": [Record<string, never>, Record<string, never>];
  "cmux.settings.tailnet.sign_out": [Record<string, never>, Record<string, never>];
  "cmux.settings.tailnet.pair": [Record<string, never>, Record<string, never>];
  "cmux.settings.tailnet.close_pair": [Record<string, never>, Record<string, never>];
  "cmux.settings.tailnet.copy_address": [Record<string, never>, Record<string, never>];
  /** Native: Updates > Web UI's Check Now (updates.web.check); the host lists follow the check. */
  "cmux.settings.web_updates.check": [Record<string, never>, Record<string, never>];
  /** Native: Updates > Web UI's Roll Back (updates.web.rollback), from the next safe point. */
  "cmux.settings.web_updates.rollback": [Record<string, never>, Record<string, never>];
  /** Native: Settings > Chief > Voice input's switch writes home.voiceInput (the person's gesture only). */
  "cmux.settings.voice_input.set": [{ on: boolean }, Record<string, never>];
  /** Native: the Accounts part (providers, linked accounts, forms). */
  "cmux.settings.accounts.state": [Record<string, never>, AccountsState];
  /** Native: one Accounts gesture; a failed Keychain save answers its message. */
  "cmux.settings.accounts.run": [AccountsRun, { error?: string }];
  /** Native: Settings > Agents, the harnesses acpmux knows and the last doctor answers. */
  "cmux.settings.agents.state": [Record<string, never>, AgentsState];
  /** Native: one Agents gesture; a daemon refusal rejects with `cmux.agents.<code>` and its text. */
  "cmux.settings.agents.run": [AgentsRun, unknown];
  /** Native: acpmux's harnesses (Settings > Agents). */
  "cmux.settings.harnesses.state": [Record<string, never>, HarnessesState];
  /** Native: one Harnesses gesture (a terminal tab for sign-in, or a refresh). */
  "cmux.settings.harnesses.run": [HarnessesRun, unknown];
  /** Native: Settings > Devices; rejects with `cmux.page.unavailable` when the host has no device hub. */
  "cmux.settings.devices.state": [Record<string, never>, DevicesState];
  /** Native: one Devices gesture; a failure answers its localized text in `error`. */
  "cmux.settings.devices.run": [DevicesRun, DevicesRunResult];
  /** Native: the coding-agent hooks `cmux agent hook status` reports (Settings > Agents). */
  "cmux.settings.integrations.state": [Record<string, never>, IntegrationsState];
  /** Native: one Agent integrations gesture (`agent hook install|uninstall <id>`, or a refresh). */
  "cmux.settings.integrations.run": [IntegrationsRun, unknown];
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
  /** The host lists changed (the event carries the new lists). */
  "cmux.settings.host.changed": HostLists;
  /** Settings > Updates' row of other machines changed (its new value; null: none to list). */
  "cmux.settings.channels.machines.changed": ChannelsState["machines"];
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

/** The error a call rejected with, as a plain record. */
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
  "palette.computerUse.accessibility",
  "palette.computerUse.screenRecording",
  "import.card",
  "importFromBrowser",
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
