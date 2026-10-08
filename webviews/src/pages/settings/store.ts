// The page's settings session. Settings data lives in one place, the TanStack Query cache
// (queries.ts): the user scope's rows, the host lists, the Accounts part and the theme colors.
// Reads and writes of setting values go through the SettingsTransport (transport.ts), the one
// boundary to the owner (the native host today, a Rust config service later); the host's other
// ops (lists, accounts, theme levels, actions) go through the page client. This class drives the
// fetches (start, change events, lazy parts) and owns only the page's UI state: the link to the
// owner and the per-row refusals. Components read both through useSettingsState (context.ts).
import { MutationObserver, type QueryClient } from "@tanstack/react-query";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";
import type { PageCommand } from "./keyboard";
import {
  createSettingsQueryClient,
  optimistic,
  scopeData,
  settingsKeys,
  type AccountsData,
  type HostData,
  type ScopeData,
  type ThemeColorsData,
  type Write,
} from "./queries";
import { rowsByKey } from "./schema";
import { t } from "./strings";
import { pageTransport, TransportError, type SettingsTransport } from "./transport";
import {
  errorCode,
  wireError,
  type AccountsRun,
  type AccountsState,
  type Domains,
  type HostLists,
  type ListRow,
  type ManagedInfo,
  type SettingsClient,
  type SettingsOpName,
  type SettingsOps,
  type SettingsPageAction,
  type SettingsStreams,
  type WireError,
} from "./ops";

/** A refused write: `message` is a page string; `detail` is the owner's own (English) text. */
export type RowError = { code: string; message: string; detail?: string };

export type SettingsState = {
  /** The first read finished (successfully or not). */
  loaded: boolean;
  /** Rows came from the owner; until then editors are read-only (defaults are not live values). */
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
  /** Theme colors by name (cmux.settings.theme.colors); null until read or when the host has none. */
  themeColors: ReadonlyMap<string, GhosttyTheme> | null;
};

/** The page's own state: nothing here is a setting value. */
export type UiState = { connected: boolean; errors: ReadonlyMap<string, RowError> };

/** What the query cache holds, as the page composes it. */
export type CacheView = {
  scope: ScopeData | undefined;
  /** The scope's first read finished (data or error). */
  scopeSettled: boolean;
  host: HostData | undefined;
  accounts: AccountsData | undefined;
  themeColors: ThemeColorsData | undefined;
};

export type WriteResult = { ok: true } | { ok: false; error: WireError };

/** Where the page opens things it does not edit itself (catalog actions). */
export type NativeTarget = "cmuxJSON";

const emptyDomains: Domains = { themes: [], font_families: [], sounds: [] };

/** The page's state from the cache and the UI state (one function for hooks and getSnapshot). */
export function composeState(ui: UiState, cache: CacheView): SettingsState {
  const scope = cache.scope;
  return {
    loaded: cache.scopeSettled,
    readable: (scope?.rows.size ?? 0) > 0,
    connected: ui.connected,
    revision: scope?.revision ?? 0,
    rows: scope?.rows ?? new Map(),
    diagnostics: scope?.diagnostics ?? new Map(),
    problems: scope?.problems ?? [],
    managed: scope?.managed ?? new Map(),
    errors: ui.errors,
    domains: scope?.domains ?? emptyDomains,
    host: cache.host ?? null,
    accounts: cache.accounts ?? null,
    themeColors: cache.themeColors ?? null,
  };
}

type Reply<R> = { ok: true; value: R } | { ok: false; error: WireError };

export class SettingsStore {
  readonly queryClient: QueryClient;
  readonly transport: SettingsTransport;
  private ui: UiState = { connected: true, errors: new Map() };
  private readonly listeners = new Set<() => void>();
  private readonly unsubscribers: Array<() => void> = [];
  private readonly commandListeners = new Set<(command: PageCommand) => void>();
  private disposed = false;
  private themeColorsRequested = false;

  constructor(
    private readonly client: SettingsClient,
    options: { transport?: SettingsTransport; queryClient?: QueryClient } = {},
  ) {
    this.transport = options.transport ?? pageTransport(client);
    this.queryClient = options.queryClient ?? createSettingsQueryClient();
    // Each key's read, so a cache observer (useSettingsState) and a refetch know how to read it.
    this.queryClient.setQueryDefaults(settingsKeys.scope("user"), { queryFn: this.scopeQuery().queryFn });
    this.queryClient.setQueryDefaults(settingsKeys.host, { queryFn: () => this.native("cmux.settings.host.lists") });
    this.queryClient.setQueryDefaults(settingsKeys.accounts, {
      queryFn: () => this.native("cmux.settings.accounts.state"),
    });
    this.queryClient.setQueryDefaults(settingsKeys.themeColors, {
      queryFn: async (): Promise<ThemeColorsData> =>
        new Map((await this.native("cmux.settings.theme.colors")).themes.map((theme) => [theme.name, theme])),
    });
    // Any cache change (a read, an optimistic write, a rollback) is a new page state.
    this.unsubscribers.push(this.queryClient.getQueryCache().subscribe(() => this.emit()));
  }

  /** Subscribes to changes and the connection, then reads everything once. */
  async start(): Promise<void> {
    const stopTransport = await this.transport.subscribe({
      changed: (event) => {
        if (this.disposed) return;
        // Another writer changed these keys: an older refusal no longer applies.
        if (event.keys.some((key) => this.ui.errors.has(key))) {
          const errors = new Map(this.ui.errors);
          for (const key of event.keys) errors.delete(key);
          this.updateUi({ errors });
        }
        void this.refresh();
      },
      connection: (connected) => {
        if (this.disposed) return;
        this.updateUi(connected ? { connected: true, errors: new Map() } : { connected: false });
        if (connected) void this.refresh();
      },
    });
    if (this.disposed) stopTransport();
    else this.unsubscribers.push(stopTransport);
    await Promise.all([
      this.listen("cmux.settings.host.changed", (host) => this.queryClient.setQueryData(settingsKeys.host, host)),
      this.listen("cmux.settings.accounts.changed", (accounts) =>
        this.queryClient.setQueryData(settingsKeys.accounts, accounts),
      ),
      this.listen("cmux.page.command", (event) => {
        for (const listener of this.commandListeners) listener(event.command);
      }),
    ]);
    await Promise.all([this.refresh(), this.refreshHost()]);
  }

  /** The user scope's query (one key per scope); its function reads through the transport. */
  scopeQuery() {
    return {
      queryKey: settingsKeys.scope("user"),
      queryFn: async (): Promise<ScopeData> => {
        try {
          const read = scopeData(await this.transport.get("user"));
          if (!this.ui.connected) this.updateUi({ connected: true });
          return read;
        } catch (error) {
          if (error instanceof TransportError && error.code === "unavailable") this.updateUi({ connected: false });
          throw error;
        }
      },
    };
  }

  /** Re-reads the scope. The newest read wins: a read still in flight is cancelled first, so an
   * older answer never replaces a newer one. */
  async refresh(): Promise<void> {
    if (this.disposed) return;
    const { queryKey } = this.scopeQuery();
    await this.queryClient.cancelQueries({ queryKey, exact: true });
    await this.queryClient.fetchQuery({ ...this.scopeQuery(), staleTime: 0 }).catch(() => undefined);
  }

  /** Re-reads the host lists (after an action, or when the host has no change stream). */
  async refreshHost(): Promise<void> {
    await this.fetchNative(settingsKeys.host);
  }

  /** Reads the Accounts part. */
  async refreshAccounts(): Promise<void> {
    await this.fetchNative(settingsKeys.accounts);
  }

  /** Reads the theme colors once (the Theme section asks when it first draws). */
  async loadThemeColors(): Promise<void> {
    // An observer creates the query before any read, so the cache cannot say "already asked".
    if (this.themeColorsRequested) return;
    this.themeColorsRequested = true;
    await this.queryClient.fetchQuery({ queryKey: settingsKeys.themeColors }).catch(() => undefined);
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

  /** The section's action buttons; empty when the host has none. */
  async sectionActions(section: string): Promise<Array<{ id: string; title: string; enabled: boolean }>> {
    const reply = await this.request("cmux.settings.section.actions", { section });
    return reply.ok ? reply.value : [];
  }

  /** Runs a section button (a registry action; the host allows only the sections' own). */
  runSectionAction(id: string): void {
    void this.request("cmux.app.action.run", { action: id });
  }

  /** Opens the cmux picker for the folder list `key`; the host writes the chosen folders. */
  async addFolders(key: string): Promise<void> {
    const reply = await this.request("cmux.settings.folders.add", { key });
    if (!reply.ok) this.setError(key, rowError(reply.error));
    else await this.refresh();
  }

  revealSettingsFile(): void {
    void this.request("cmux.settings.file.reveal", {});
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
    this.queryClient.clear();
  }

  /** The UI state's subscription (the cache has its own; useSettingsState reads both). */
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getUi = (): UiState => this.ui;

  /** The cache as the page composes it, read outside React (keyboard commands, tests). */
  cacheView(): CacheView {
    const scopeState = this.queryClient.getQueryState(settingsKeys.scope("user"));
    return {
      scope: this.queryClient.getQueryData<ScopeData>(settingsKeys.scope("user")),
      scopeSettled: scopeState !== undefined && scopeState.status !== "pending",
      host: this.queryClient.getQueryData<HostData>(settingsKeys.host),
      accounts: this.queryClient.getQueryData<AccountsData>(settingsKeys.accounts),
      themeColors: this.queryClient.getQueryData<ThemeColorsData>(settingsKeys.themeColors),
    };
  }

  getSnapshot = (): SettingsState => composeState(this.ui, this.cacheView());

  /** Dispatcher commands (find, back, forward, reset) for the mounted page. */
  onCommand(listener: (command: PageCommand) => void): () => void {
    this.commandListeners.add(listener);
    return () => this.commandListeners.delete(listener);
  }

  set(key: string, value: unknown): Promise<WriteResult> {
    return this.write({ kind: "set", key, value });
  }

  reset(key: string): Promise<WriteResult> {
    return this.write({ kind: "reset", key });
  }

  resetAll(): Promise<WriteResult> {
    return this.write({ kind: "resetAll" });
  }

  preview(key: string, value: unknown): void {
    if (this.ui.connected) void this.request("cmux.settings.preview", { key, value });
  }

  previewEnd(key: string): void {
    void this.request("cmux.settings.preview.end", { key });
  }

  /** Opens cmux.json in the editor (the palette's action). The Swift Settings window is gone (R82). */
  openNative(_target: NativeTarget): void {
    void this.request("cmux.app.action.run", { action: "palette.openCmuxSettingsFile" });
  }

  playSound(name: string): void {
    void this.request("cmux.settings.sound.play", { name });
  }

  /**
   * One write as a mutation: the scope shows the new value at once (optimistic), goes back to
   * the previous read when the owner refuses, and is read again once the write settles.
   * Writes are refused here while the owner is unreachable; nothing queues.
   */
  private async write(write: Write): Promise<WriteResult> {
    if (!this.ui.connected) {
      return { ok: false, error: { code: "cmux.page.unavailable", message: "cmux is not connected" } };
    }
    const key = settingsKeys.scope("user");
    const queryClient = this.queryClient;
    const observer = new MutationObserver<void, TransportError, Write, { previous: ScopeData | undefined }>(
      queryClient,
      {
        mutationKey: settingsKeys.write,
        mutationFn: (next) =>
          next.kind === "set"
            ? this.transport.set(next.key, next.value)
            : this.transport.reset(next.kind === "reset" ? next.key : "all"),
        onMutate: async (next) => {
          await queryClient.cancelQueries({ queryKey: key });
          const previous = queryClient.getQueryData<ScopeData>(key);
          if (previous) queryClient.setQueryData(key, optimistic(previous, next));
          return { previous };
        },
        onError: (_error, _next, context) => {
          if (context?.previous) queryClient.setQueryData(key, context.previous);
        },
        onSettled: () => this.refresh(),
      },
    );
    try {
      await observer.mutate(write);
    } catch (error) {
      const wire = error instanceof TransportError ? error.wire : wireError(error);
      const code = errorCode(wire);
      if (code === "unavailable") this.updateUi({ connected: false });
      else if (code !== "revision_conflict" && write.kind !== "resetAll") this.setError(write.key, rowError(wire));
      return { ok: false, error: wire };
    } finally {
      observer.reset();
    }
    if (write.kind !== "resetAll") this.setError(write.key, null);
    return { ok: true };
  }

  private async fetchNative(queryKey: readonly string[]): Promise<void> {
    if (this.disposed) return;
    await this.queryClient.fetchQuery({ queryKey, staleTime: 0 }).catch(() => undefined);
  }

  /** One of the host's own reads, for its query; rejects with the host's error. */
  private async native<K extends SettingsOpName>(op: K): Promise<SettingsOps[K][1]> {
    const reply = await this.request(op, {} as SettingsOps[K][0]);
    if (!reply.ok) throw new TransportError(reply.error);
    return reply.value;
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

  private setError(key: string, error: RowError | null): void {
    if (!error && !this.ui.errors.has(key)) return;
    const errors = new Map(this.ui.errors);
    if (error) errors.set(key, error);
    else errors.delete(key);
    this.updateUi({ errors });
  }

  private updateUi(patch: Partial<UiState>): void {
    this.ui = { ...this.ui, ...patch };
    this.emit();
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}

function rowError(error: WireError): RowError {
  const code = errorCode(error);
  return { code, message: errorText(code), detail: error.message };
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

/** The managed info of a row, from cmux.settings.list or the snapshot. */
export function managedOf(state: SettingsState, key: string): ManagedInfo | null {
  return state.rows.get(key)?.managed ?? state.managed.get(key) ?? null;
}

/** The current value of a row, falling back to the schema default before the first list. */
export function valueOf(state: SettingsState, key: string): unknown {
  const row = state.rows.get(key);
  return row ? row.value : rowsByKey.get(key)?.default;
}
