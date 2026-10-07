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

export type Domains = { themes: string[]; font_families: string[]; sounds: string[] };

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

/** One space or machine row (`cmux.settings.host.lists`). */
export type HostListRow = { id: string; title: string; subtitle: string | null; active: boolean };

/** One browser profile row. */
export type BrowserProfile = {
  id: string;
  name: string;
  color: string | null;
  icon: string | null;
  is_default: boolean;
  source: string | null;
};

/** The lists the host shows beside the schema rows; `rooms` is null when spaces are unsupported. */
export type HostLists = {
  rooms: HostListRow[] | null;
  machines: HostListRow[];
  browser_profiles: BrowserProfile[];
  profile_colors: Array<{ name: string; swatch: string; fill: string }>;
  /** Theme levels of the active window (`room`, `workspace`, `terminal`) and each one's theme. */
  theme?: { levels: string[]; current: Record<string, string | null> };
  terminal?: { ghostty_config: string; shell_integration: string | null };
  /** R92: the Ghostty lines cmux does not apply (the socket's `ghostty.diagnostics` list). */
  ghostty_diagnostics?: GhosttyDiagnostic[] | null;
  settings_file?: string | null;
  /** Wallpaper choices; thumbnails at `backdrop/<id>` on the page's own origin. */
  backdrops?: Array<{ id: string; title: string; attribution: string }>;
  /** Where an unset number row's slider sits when the app resolves it (the theme's window opacity). */
  derived?: Record<string, number>;
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

/** The Accounts part as the host draws it (texts already localized by the app). */
export type AccountsState = {
  refresh: string;
  refreshing: boolean;
  /** The Sign In to cmux button's title when cmux is signed out. */
  signIn: string | null;
  removeTitle: string;
  groups: Array<{ id: string; title: string; rows: AccountsRow[] }>;
};

/** One Accounts gesture; `secret` only for the paste form's save and send. */
export type AccountsRun = { action: string; provider?: string; account?: string; secret?: string };

/** The v2 mutation result: `revision` is a decimal string. */
export type MutationResult = { value: { keys: string[] }; revision: string; replayed: boolean };

type Mutation<P> = P & { idempotency_key: string; if_revision?: string };

/** Every op the page calls: params and result. */
export type SettingsOps = {
  "cmux.settings.list": [{ section?: string }, ListRow[]];
  "cmux.settings.snapshot": [Record<string, never>, SnapshotResult];
  "cmux.settings.set": [Mutation<{ key: string; value: unknown }>, MutationResult];
  "cmux.settings.reset": [Mutation<{ key: string }>, MutationResult];
  "cmux.settings.reset_all": [Mutation<object>, MutationResult];
  /** Native: spaces, machines and browser profiles from the app's live stores. */
  "cmux.settings.host.lists": [Record<string, never>, HostLists];
  /** Native: the Accounts part (providers, linked accounts, forms). */
  "cmux.settings.accounts.state": [Record<string, never>, AccountsState];
  /** Native: one Accounts gesture; a failed Keychain save answers its message. */
  "cmux.settings.accounts.run": [AccountsRun, { error?: string }];
  /** Native: set the theme of one level of the active window; `spec` null uses the Ghostty config. */
  "cmux.settings.theme.set": [{ level: string; spec: string | null }, unknown];
  /** Native: whether typed text is a theme spec Ghostty accepts (a pair, a path). */
  "cmux.settings.theme.accepts": [{ text: string }, { accepts: boolean }];
  /** Native: the cmux picker chooses folders for a folder list row; the host writes them. */
  "cmux.settings.folders.add": [{ key: string }, { added: string[] }];
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
};

export type SettingsOpName = keyof SettingsOps;

/** Streams the page subscribes to. */
export type SettingsStreams = {
  "cmux.settings.changed": { revision: number; keys: string[]; origin?: string };
  /** The Accounts part changed (the event carries the new state). */
  "cmux.settings.accounts.changed": AccountsState;
  /** The host lists changed (the event carries the new lists). */
  "cmux.settings.host.changed": HostLists;
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
  "browserProfile.rename",
  "browserProfile.setColor",
  "browserProfile.clearColor",
  "browserProfile.setIcon",
  "browserProfile.clearIcon",
  "browserProfile.manageExtensions",
  "browserProfile.delete",
  "reloadConfiguration",
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
