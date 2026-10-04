// The page's view of the daemon's settings. One immutable state object, replaced on each
// change and read with useSyncExternalStore. Writes go straight to the page client as
// `cmux.settings.*` ops; while the daemon is unreachable they are refused here and nothing
// queues. A `cmux.settings.changed` event (any writer: this page, the CLI, a hand edit)
// re-reads the rows; an older read never replaces a newer one.
import type { PageCommand } from "./keyboard";
import { rowsByKey } from "./schema";
import { t } from "./strings";
import {
  errorCode,
  newIdempotencyKey,
  revisionNumber,
  wireError,
  type Diagnostic,
  type Domains,
  type HostLists,
  type AccountsRun,
  type AccountsState,
  type SettingsPageAction,
  type ListRow,
  type ManagedInfo,
  type MutationResult,
  type SettingsClient,
  type SettingsOpName,
  type SettingsOps,
  type SettingsStreams,
  type SnapshotResult,
  type WireError,
} from "./ops";

/** A refused write: `message` is a page string; `detail` is the owner's own (English) text. */
export type RowError = { code: string; message: string; detail?: string };

export type SettingsState = {
  /** The first read finished (successfully or not). */
  loaded: boolean;
  /** Rows came from the daemon; until then editors are read-only (defaults are not live values). */
  readable: boolean;
  connected: boolean;
  revision: number;
  rows: ReadonlyMap<string, ListRow>;
  diagnostics: ReadonlyMap<string, string[]>;
  /** Every problem of the last load, in file order (Advanced lists them). */
  problems: ReadonlyArray<{ path: string; message: string }>;
  managed: ReadonlyMap<string, ManagedInfo>;
  errors: ReadonlyMap<string, RowError>;
  domains: Domains;
  /** Spaces, machines and browser profiles; null until read, or when the host has none. */
  host: HostLists | null;
  /** The Accounts part; null until read, or when the host has none. */
  accounts: AccountsState | null;
};

export type WriteResult = { ok: true } | { ok: false; error: WireError };

/** Where the page opens things it does not edit itself (catalog actions). */
export type NativeTarget = "cmuxJSON" | "section";

const emptyDomains: Domains = { themes: [], font_families: [], sounds: [] };

type Reply<R> = { ok: true; value: R } | { ok: false; error: WireError };

export class SettingsStore {
  private state: SettingsState = {
    loaded: false,
    readable: false,
    connected: true,
    revision: 0,
    rows: new Map(),
    diagnostics: new Map(),
    problems: [],
    managed: new Map(),
    errors: new Map(),
    domains: emptyDomains,
    host: null,
    accounts: null,
  };
  private readonly listeners = new Set<() => void>();
  private refreshSequence = 0;
  private readonly unsubscribers: Array<() => void> = [];
  private readonly commandListeners = new Set<(command: PageCommand) => void>();
  private disposed = false;

  constructor(private readonly client: SettingsClient) {}

  /** Subscribes to changes and the connection, then reads everything once. */
  async start(): Promise<void> {
    await Promise.all([
      // Every change re-reads: rows and revision may come from different moments, so a
      // revision comparison could skip a newer change. refreshSequence keeps the newest read.
      this.listen("cmux.settings.changed", (event) => {
        // Another writer changed these keys: an older refusal no longer applies.
        if (event.keys.some((key) => this.state.errors.has(key))) {
          const errors = new Map(this.state.errors);
          for (const key of event.keys) errors.delete(key);
          this.update({ errors });
        }
        void this.refresh();
      }),
      this.listen("cmux.page.connection", (event) => {
        this.update(event.connected ? { connected: true, errors: new Map() } : { connected: false });
        if (event.connected) void this.refresh();
      }),
      this.listen("cmux.settings.host.changed", (host) => this.update({ host })),
      this.listen("cmux.settings.accounts.changed", (accounts) => this.update({ accounts })),
      this.listen("cmux.page.command", (event) => {
        for (const listener of this.commandListeners) listener(event.command);
      }),
    ]);
    await Promise.all([this.refresh(), this.refreshHost()]);
  }

  /** Re-reads the host lists (after an action, or when the host has no change stream). */
  async refreshHost(): Promise<void> {
    const reply = await this.request("cmux.settings.host.lists", {});
    if (reply.ok && !this.disposed) this.update({ host: reply.value });
  }

  /** Sets one theme level of the active window, then re-reads the lists (the current theme). */
  async setTheme(level: string, spec: string | null): Promise<void> {
    await this.request("cmux.settings.theme.set", { level, spec });
    await this.refreshHost();
  }

  /** Whether `text` is a theme spec the host accepts. */
  async acceptsTheme(text: string): Promise<boolean> {
    const reply = await this.request("cmux.settings.theme.accepts", { text });
    return reply.ok && reply.value.accepts;
  }

  revealSettingsFile(): void {
    void this.request("cmux.settings.file.reveal", {});
  }

  /** Reads the Accounts part. */
  async refreshAccounts(): Promise<void> {
    const reply = await this.request("cmux.settings.accounts.state", {});
    if (reply.ok && !this.disposed) this.update({ accounts: reply.value });
  }

  /** One Accounts gesture; answers the failure text of a Keychain save, else null. */
  async runAccounts(run: AccountsRun): Promise<string | null> {
    const reply = await this.request("cmux.settings.accounts.run", run);
    await this.refreshAccounts();
    if (!reply.ok) return reply.error.message;
    return reply.value.error ?? null;
  }

  /** Runs one of the page's catalog actions (`target` is `kind:id`), then re-reads the lists. */
  async runAction(action: SettingsPageAction, args: Record<string, unknown> = {}, target?: string): Promise<void> {
    await this.request("cmux.app.action.run", target ? { action, args, target } : { action, args });
    await this.refreshHost();
  }

  dispose(): void {
    this.disposed = true;
    for (const unsubscribe of this.unsubscribers.splice(0)) unsubscribe();
    this.listeners.clear();
    this.commandListeners.clear();
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): SettingsState => this.state;

  /** Dispatcher commands (find, back, forward, reset) for the mounted page. */
  onCommand(listener: (command: PageCommand) => void): () => void {
    this.commandListeners.add(listener);
    return () => this.commandListeners.delete(listener);
  }

  /** Fetches rows and the snapshot; an older response never replaces a newer one. */
  async refresh(): Promise<void> {
    const sequence = ++this.refreshSequence;
    const [list, snapshot] = await Promise.all([
      this.request("cmux.settings.list", {}),
      this.request("cmux.settings.snapshot", {}),
    ]);
    if (sequence !== this.refreshSequence || this.disposed) return;
    if (!list.ok || !snapshot.ok) {
      const error = !list.ok ? list.error : !snapshot.ok ? snapshot.error : null;
      const unavailable = error !== null && errorCode(error) === "unavailable";
      this.update({ loaded: true, connected: unavailable ? false : this.state.connected });
      return;
    }
    this.update({
      loaded: true,
      readable: list.value.length > 0,
      connected: true,
      revision: revisionNumber(snapshot.value.revision),
      rows: new Map(list.value.map((row) => [row.key, row])),
      managed: new Map(Object.entries(snapshot.value.managed ?? {})),
      diagnostics: diagnosticsByKey(snapshot.value.diagnostics ?? []),
      problems: (snapshot.value.diagnostics ?? []).map((diagnostic) => ({
        path: Array.isArray(diagnostic.path) ? diagnostic.path.join(".") : diagnostic.path,
        message: diagnostic.message,
      })),
      domains: publishedDomains(snapshot.value),
    });
  }

  set(key: string, value: unknown): Promise<WriteResult> {
    return this.write(key, () =>
      this.request("cmux.settings.set", { key, value, idempotency_key: newIdempotencyKey() }),
    );
  }

  reset(key: string): Promise<WriteResult> {
    return this.write(key, () => this.request("cmux.settings.reset", { key, idempotency_key: newIdempotencyKey() }));
  }

  resetAll(): Promise<WriteResult> {
    return this.write(null, () => this.request("cmux.settings.reset_all", { idempotency_key: newIdempotencyKey() }));
  }

  preview(key: string, value: unknown): void {
    if (this.state.connected) void this.request("cmux.settings.preview", { key, value });
  }

  previewEnd(key: string): void {
    void this.request("cmux.settings.preview.end", { key });
  }

  openNative(target: NativeTarget, section?: string): void {
    const params =
      target === "cmuxJSON"
        ? { action: "palette.openCmuxSettingsFile" }
        : { action: "openSettings", args: section ? { section } : {} };
    void this.request("cmux.app.action.run", params);
  }

  playSound(name: string): void {
    void this.request("cmux.settings.sound.play", { name });
  }

  private async request<K extends SettingsOpName>(op: K, params: SettingsOps[K][0]): Promise<Reply<SettingsOps[K][1]>> {
    try {
      return { ok: true, value: await this.client.call<SettingsOps[K][1]>(op, params) };
    } catch (error) {
      return { ok: false, error: wireError(error) };
    }
  }

  private async listen<K extends keyof SettingsStreams>(
    stream: K,
    onEvent: (event: SettingsStreams[K]) => void,
  ): Promise<void> {
    try {
      const unsubscribe = await this.client.subscribe<SettingsStreams[K]>(stream, (event) => {
        if (!this.disposed) onEvent(event);
      });
      if (this.disposed) unsubscribe();
      else this.unsubscribers.push(unsubscribe);
    } catch {
      // A host without this stream: the page still works, it only misses live updates.
    }
  }

  private async write(key: string | null, send: () => Promise<Reply<MutationResult>>): Promise<WriteResult> {
    if (!this.state.connected) {
      return { ok: false, error: { code: "cmux.page.unavailable", message: "cmux is not connected" } };
    }
    const reply = await send();
    if (!reply.ok) {
      const { error } = reply;
      const code = errorCode(error);
      if (code === "unavailable") this.update({ connected: false });
      else if (code === "revision_conflict") void this.refresh();
      else if (key) this.setError(key, { code, message: errorText(code), detail: error.message });
      return { ok: false, error };
    }
    if (key) this.setError(key, null);
    await this.refresh();
    return { ok: true };
  }

  private setError(key: string, error: RowError | null): void {
    if (!error && !this.state.errors.has(key)) return;
    const errors = new Map(this.state.errors);
    if (error) errors.set(key, error);
    else errors.delete(key);
    this.update({ errors });
  }

  private update(patch: Partial<SettingsState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function errorText(code: string): string {
  if (code === "managed") return t("settingsPage.managed");
  if (code === "invalid") return t("settingsPage.invalidValue");
  return t("settingsPage.writeFailed");
}

/** The lock line of a managed row, in the page's language. */
export function managedText(info: ManagedInfo): string {
  return info.team ? t("settingsPage.managedByTeam", info.team) : t("settingsPage.managed");
}

function publishedDomains(snapshot: SnapshotResult): Domains {
  const domains = snapshot.domains ?? {};
  return {
    themes: domains.themes ?? [],
    font_families: domains.font_families ?? [],
    sounds: domains.sounds ?? [],
  };
}

/** Diagnostics keyed by schema row: the row whose key equals the path or is its prefix. */
function diagnosticsByKey(diagnostics: Diagnostic[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const diagnostic of diagnostics) {
    const path = Array.isArray(diagnostic.path) ? diagnostic.path.join(".") : diagnostic.path;
    let key = path;
    while (key && !rowsByKey.has(key)) key = key.includes(".") ? key.slice(0, key.lastIndexOf(".")) : "";
    if (!key) continue;
    out.set(key, [...(out.get(key) ?? []), diagnostic.message]);
  }
  return out;
}

/** The managed info of a row, from cmux.settings.list or the snapshot. */
export function managedOf(state: SettingsState, key: string): ManagedInfo | null {
  return state.rows.get(key)?.managed ?? state.managed.get(key) ?? null;
}

/** The current value of a row, falling back to the schema default before the first list. */
export function valueOf(state: SettingsState, key: string): unknown {
  const row = state.rows.get(key);
  return row ? row.value : rowsByKey.get(key)?.default;
}
