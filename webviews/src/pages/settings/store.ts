// The page's settings session. Settings data lives in one place, the TanStack Query cache
// (queries.ts): the user scope's rows, the host lists, the Accounts part and the theme colors.
// Reads and writes of setting values go through the SettingsTransport (transport.ts), the one
// boundary to the owner (the native host today, a Rust config service later); the host's other
// ops (lists, accounts, theme levels, actions) go through the page client. This class drives the
// fetches (start, change events, lazy parts) and owns only the page's UI state: the link to the
// owner and the per-row refusals. Components read both through useSettingsState (context.ts).
import { MutationObserver, type QueryClient } from "@tanstack/react-query";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";
import { AppearanceHistory, diff, type HistoryEntry, type TargetState } from "./appearanceHistory";
import {
  appearanceKeys,
  captureAppearance,
  captureKeys,
  captureThemes,
  changeLabel,
  tracksAppearance,
  withLinked,
} from "./appearanceUndo";
import type { PageCommand } from "./keyboard";
import {
  createSettingsQueryClient,
  optimistic,
  scopeData,
  shareScope,
  settingsKeys,
  type AccountsData,
  type DevicesData,
  type HarnessesData,
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
  type AgentsRun,
  type AgentsState,
  type ChannelsState,
  type DevicesRun,
  type DevicesRunResult,
  type DevicesState,
  type Domains,
  type HarnessesRun,
  type HarnessesState,
  type HostLists,
  type IntegrationsRun,
  type IntegrationsState,
  type ListRow,
  type ManagedInfo,
  type MuseumArtResult,
  type SettingsClient,
  type SettingsOpName,
  type SettingsOps,
  type SettingsPageAction,
  type SettingsStreams,
  type WireError,
  type WorkspaceBackground,
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
  /** The Harnesses part (Settings > Agents); null until read, or when the host has none. */
  harnesses: HarnessesState | null;
  /** The Devices part (Settings > Devices); null until read, or when the host has none. */
  devices: DevicesState | null;
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
  harnesses?: HarnessesData | undefined;
  devices?: DevicesData | undefined;
  themeColors: ThemeColorsData | undefined;
};

export type WriteResult = { ok: true } | { ok: false; error: WireError };

/** Where the page opens things it does not edit itself (catalog actions). */
export type NativeTarget = "cmuxJSON";

/** `appearance.background`, which the picker's host ops set. */
const BACKGROUND = "appearance.background";

const emptyDomains: Domains = { themes: [], font_families: [], sounds: [], recent_fonts: [] };

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
    harnesses: cache.harnesses ?? null,
    devices: cache.devices ?? null,
    themeColors: cache.themeColors ?? null,
  };
}

export type Reply<R> = { ok: true; value: R } | { ok: false; error: WireError };

export class SettingsStore {
  readonly queryClient: QueryClient;
  readonly transport: SettingsTransport;
  private ui: UiState = { connected: true, errors: new Map() };
  private readonly listeners = new Set<() => void>();
  private readonly unsubscribers: Array<() => void> = [];
  private readonly commandListeners = new Set<(command: PageCommand) => void>();
  private disposed = false;
  private themeColorsRequested = false;
  /** The last composed state and what it was composed from (getSnapshot answers it while equal). */
  private composed: { ui: UiState; cache: CacheView; state: SettingsState } | null = null;
  /** The newest revision a finished or running read of the scope is sure to show. */
  private covered = 0;
  /** Settings > Appearance's undo stack (appearanceHistory.ts): page state, never written. */
  readonly appearance = new AppearanceHistory();
  /** Every appearance target as it was when Appearance first showed in this visit. */
  private appearanceOpened: TargetState[] | null = null;
  /** How many appearance steps are running (`trackAppearance`); inner ones record nothing. */
  private tracking = 0;

  constructor(
    private readonly client: SettingsClient,
    options: { transport?: SettingsTransport; queryClient?: QueryClient } = {},
  ) {
    this.transport = options.transport ?? pageTransport(client);
    this.queryClient = options.queryClient ?? createSettingsQueryClient();
    // Each key's read, so a cache observer (useSettingsState) and a refetch know how to read it.
    this.queryClient.setQueryDefaults(settingsKeys.scope("user"), {
      queryFn: this.scopeQuery().queryFn,
    });
    this.queryClient.setQueryDefaults(settingsKeys.host, {
      queryFn: () => this.native("cmux.settings.host.lists"),
    });
    this.queryClient.setQueryDefaults(settingsKeys.accounts, {
      queryFn: () => this.native("cmux.settings.accounts.state"),
    });
    this.queryClient.setQueryDefaults(settingsKeys.harnesses, {
      queryFn: () => this.native("cmux.settings.harnesses.state"),
    });
    this.queryClient.setQueryDefaults(settingsKeys.devices, {
      queryFn: () => this.native("cmux.settings.devices.state"),
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
    // Every subscription at once (one round trip, not two), then the reads, so no change can land
    // between a read and its subscription.
    const listening = Promise.all([
      this.listen("cmux.settings.host.changed", (host) => this.queryClient.setQueryData(settingsKeys.host, host)),
      this.listen("cmux.settings.accounts.changed", (accounts) =>
        this.queryClient.setQueryData(settingsKeys.accounts, accounts),
      ),
      this.listen("cmux.settings.harnesses.changed", (harnesses) =>
        this.queryClient.setQueryData(settingsKeys.harnesses, harnesses),
      ),
      this.listen("cmux.settings.devices.changed", (devices) =>
        this.queryClient.setQueryData(settingsKeys.devices, devices),
      ),
      // A machine's update failing while Updates shows (its toast's Details opens it) shows in
      // the Channels card's row at once, in every channel's read.
      this.listen("cmux.settings.channels.machines.changed", (machines) =>
        this.queryClient.setQueriesData<ChannelsState | null>({ queryKey: [...settingsKeys.all, "channels"] }, (state) =>
          state ? { ...state, machines } : state,
        ),
      ),
      this.listen("cmux.page.command", (event) => {
        for (const listener of this.commandListeners) listener(event.command);
      }),
    ]);
    const stopTransport = await this.transport.subscribe({
      changed: (event) => {
        if (this.disposed) return;
        // Another writer changed these keys: an older refusal no longer applies.
        if (event.keys.some((key) => this.ui.errors.has(key))) {
          const errors = new Map(this.ui.errors);
          for (const key of event.keys) errors.delete(key);
          this.updateUi({ errors });
        }
        // A read that already shows this revision (this page's own write re-reads it) is enough.
        void this.refresh(typeof event.revision === "number" ? event.revision : undefined);
      },
      connection: (connected) => {
        if (this.disposed) return;
        this.updateUi(connected ? { connected: true, errors: new Map() } : { connected: false });
        if (connected) void this.refresh();
      },
    });
    if (this.disposed) stopTransport();
    else this.unsubscribers.push(stopTransport);
    await listening;
    await Promise.all([this.refresh(), this.refreshHost()]);
  }

  /** The user scope's query (one key per scope); its function reads through the transport. */
  scopeQuery() {
    return {
      queryKey: settingsKeys.scope("user"),
      // A re-read keeps every unchanged row's object, so a change renders only its own rows.
      structuralSharing: (previous: unknown, next: unknown) =>
        shareScope(previous as ScopeData | undefined, next as ScopeData),
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
   * older answer never replaces a newer one. With `revision` (a change the owner announced, or
   * this page's own write) nothing is read when a finished or running read already shows it: each
   * read builds every row on the owner. */
  async refresh(revision?: number): Promise<void> {
    if (this.disposed) return;
    if (revision !== undefined && revision <= this.covered) return;
    // Any read that starts now shows at least `revision`: the owner applied it before saying so.
    if (revision !== undefined) this.covered = revision;
    const { queryKey } = this.scopeQuery();
    await this.queryClient.cancelQueries({ queryKey, exact: true });
    const read = await this.queryClient.fetchQuery({ ...this.scopeQuery(), staleTime: 0 }).catch(() => undefined);
    if (read) this.covered = Math.max(this.covered, read.revision);
    // A failed or cancelled read covers nothing it did not show: the next announcement reads again.
    else this.covered = this.queryClient.getQueryData<ScopeData>(queryKey)?.revision ?? 0;
  }

  /** Re-reads the host lists (after an action, or when the host has no change stream). */
  async refreshHost(): Promise<void> {
    await this.fetchNative(settingsKeys.host);
  }

  /** Reads the Accounts part. */
  async refreshAccounts(): Promise<void> {
    await this.fetchNative(settingsKeys.accounts);
  }

  /** Reads the Devices part (a host without a device hub rejects, and the part stays null). */
  async refreshDevices(): Promise<void> {
    await this.fetchNative(settingsKeys.devices);
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
    await this.trackAppearance(
      [],
      async () => {
        await this.request("cmux.settings.theme.set", { level, spec });
        await this.refreshHost();
      },
      { themes: true },
    );
  }

  /** Save as Ghostty Theme (cx-wqn5.1): the host writes `base` with its edits as the user theme `name`. */
  async saveThemeFile(name: string, base: string, replace: boolean): Promise<Reply<{ name?: string }>> {
    return this.themeFileSaved(await this.request("cmux.settings.theme.save", { name, base, replace }));
  }

  /**
   * Import Theme File: the host asks for the file in the cmux picker (`{}` when the person left it).
   * A name in use answers `cmux.settings.theme.exists` with a `token`; `token` and `replace` retry it.
   */
  async importThemeFile(retry?: { token: string; replace: boolean }): Promise<Reply<{ name?: string }>> {
    return this.themeFileSaved(await this.request("cmux.settings.theme.import", retry ?? {}));
  }

  /**
   * Let Themes Set Colors: the host turns the Ghostty config's own color lines into comments and
   * reloads it, so the theme sets those colors; the host lists then drop the notice.
   */
  async releaseThemeOverrides(): Promise<Reply<{ files: number }>> {
    const reply = await this.request("cmux.settings.theme.overrides.release", {});
    if (reply.ok) await this.refreshHost();
    return reply;
  }

  openThemeOverrides(): void {
    void this.request("cmux.settings.theme.overrides.open", {});
  }

  /** After a theme file lands, the theme names and colors are read again so every picker lists it. */
  private async themeFileSaved(reply: Reply<{ name?: string }>): Promise<Reply<{ name?: string }>> {
    if (reply.ok && reply.value.name) await Promise.all([this.refresh(), this.fetchNative(settingsKeys.themeColors)]);
    return reply;
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

  /** Opens the cmux picker for an image of the person's own; the host copies it into the
   * backgrounds folder and sets it as the background. */
  async chooseBackdropImage(): Promise<void> {
    await this.trackAppearance([BACKGROUND], async () => {
      const reply = await this.request("cmux.settings.backdrop.choose_image", {});
      if (!reply.ok) this.setError(BACKGROUND, rowError(reply.error));
      else await Promise.all([this.refresh(), this.refreshHost()]);
    });
  }

  /** Shuffle a Folder…: the app asks for a folder and shuffles its pictures (`folder:<path>`). */
  async chooseBackdropFolder(): Promise<void> {
    await this.trackAppearance([BACKGROUND], async () => {
      const reply = await this.request("cmux.settings.backdrop.image.folder", {});
      if (!reply.ok) this.setError(BACKGROUND, rowError(reply.error));
      else await Promise.all([this.refresh(), this.refreshHost()]);
    });
  }

  /** Downloads the image or movie at `url` and sets it (backgrounds plan phase 3). Resolves to the
   * refusal code the picker words, or null once it is the background. */
  async addBackdropLink(url: string): Promise<string | null> {
    return this.trackAppearance([BACKGROUND], async () => {
      const reply = await this.request("cmux.settings.backdrop.image.link", { url });
      if (!reply.ok) return reply.error.code || "cmux.settings.backdrop.download_failed";
      await Promise.all([this.refresh(), this.refreshHost()]);
      return null;
    });
  }

  /** Deletes one of the person's own images; resolves to the bytes the rest take, or null. */
  async removeBackdropImage(id: string): Promise<number | null> {
    const reply = await this.request("cmux.settings.backdrop.image.remove", { id });
    if (!reply.ok) return null;
    await this.refreshHost();
    return reply.value.bytes;
  }

  /** Shows one of the person's images, or with no id the backgrounds folder, in Finder. */
  revealBackdropImage(id?: string): void {
    void this.request("cmux.settings.backdrop.image.reveal", id ? { id } : {});
  }

  /** The bytes the person's own images take and their folder; null when the host cannot say. */
  async backdropUsage(): Promise<{ bytes: number; folder: string | null } | null> {
    const reply = await this.request("cmux.settings.backdrop.image.usage", {});
    return reply.ok ? { bytes: reply.value.bytes, folder: reply.value.folder ?? null } : null;
  }

  /** Opens the Wallpaper pane of System Settings, where macOS downloads a wallpaper the picker
   * lists as not downloaded. macOS says nothing when it finishes, so the lists are read again
   * once the person is back in this window. */
  async openWallpaperSettings(): Promise<void> {
    window.addEventListener("focus", () => void this.refreshHost(), { once: true });
    await this.request("cmux.settings.backdrop.wallpaper_settings", {});
  }

  /** The workspace `id`'s own background, or null when the host has none or the workspace is gone. */
  async workspaceBackground(id: string): Promise<WorkspaceBackground | null> {
    const reply = await this.request("cmux.settings.backdrop.workspace", { workspace: id });
    return reply.ok ? reply.value : null;
  }

  /** Saves the workspace `id`'s own background; null follows appearance.background again. */
  async setWorkspaceBackground(id: string, value: string | null): Promise<boolean> {
    const reply = await this.request("cmux.settings.backdrop.workspace.set", {
      workspace: id,
      value,
    });
    if (!reply.ok) this.setError("appearance.background", rowError(reply.error));
    return reply.ok;
  }

  /** Saves the workspace `id`'s own glass tint over art; null follows All Workspaces' opacity. */
  async setWorkspaceOpacity(id: string, opacity: number | null): Promise<boolean> {
    const reply = await this.request("cmux.settings.backdrop.workspace.set", {
      workspace: id,
      opacity,
    });
    if (!reply.ok) this.setError("appearance.backgroundOpacity", rowError(reply.error));
    return reply.ok;
  }

  /** Shows a tint over the workspace `id`'s art without saving it (the slider moving). */
  previewWorkspaceOpacity(id: string, opacity: number): void {
    if (this.ui.connected) void this.request("cmux.settings.backdrop.workspace.preview", { workspace: id, opacity });
  }

  /** Shows `value` in the workspace `id` without saving it; `undefined` ends every preview. */
  previewWorkspaceBackground(id: string, value: string | null | undefined): void {
    if (value === undefined)
      void this.request("cmux.settings.backdrop.workspace.preview", { workspace: id, end: true });
    else if (this.ui.connected) void this.request("cmux.settings.backdrop.workspace.preview", { workspace: id, value });
  }

  /** Browse More Art: the works matching `query`, or null when the host could not search. */
  async searchMuseumArt(query: string): Promise<MuseumArtResult[] | null> {
    const reply = await this.request("cmux.settings.art.search", { query });
    return reply.ok ? reply.value.results : null;
  }

  /** Downloads the work `key` and sets it as the background; false when that failed. */
  async useMuseumArt(key: string): Promise<boolean> {
    return this.trackAppearance([BACKGROUND], async () => {
      const reply = await this.request("cmux.settings.art.use", { key });
      if (reply.ok) await Promise.all([this.refresh(), this.refreshHost()]);
      return reply.ok;
    });
  }

  /** Writes `text` to the pasteboard (a row's Copy Setting Key) through the host. */
  async copy(text: string): Promise<void> {
    await this.request("cmux.app.clipboard.write", { text });
  }

  revealSettingsFile(): void {
    void this.request("cmux.settings.file.reveal", {});
  }

  /** Settings > Mobile: remove one of the account's phones, then re-read the host lists. */
  async removePhone(id: string): Promise<void> {
    await this.request("cmux.settings.mobile.remove_phone", { id });
    await this.refreshHost();
  }

  /** Settings > Devices: remove a device from every store that lets it in, then re-read the host lists. */
  async removeDevice(id: string): Promise<void> {
    await this.request("cmux.settings.devices.remove", { id });
    await this.refreshHost();
  }

  /** Settings > Devices: a paired client machine's Full access on or off, then re-read the host lists. */
  async setDeviceFullAccess(id: string, on: boolean): Promise<void> {
    await this.request("cmux.settings.devices.full_access", { id, on });
    await this.refreshHost();
  }

  /** Settings > Machines: a Cloud machine's "Dedicated agent machine" on or off, then re-read the host lists. */
  async setMachineVmHost(id: string, on: boolean): Promise<void> {
    await this.request("cmux.settings.machines.vm_host", { id, on });
    await this.refreshHost();
  }

  /** Settings > Mobile: answer a phone's pairing request, then re-read the host lists. */
  async answerPair(id: string, allow: boolean): Promise<void> {
    await this.request("cmux.settings.mobile.answer_pair", { id, allow });
    await this.refreshHost();
  }

  /** Settings > Server: Restart… opens the host's confirm for one server; nothing restarts without it. */
  async restartServer(kind: string, host: string | null): Promise<void> {
    await this.request("cmux.settings.server.restart", { kind, host });
  }

  /** Settings > Server: Pair opens the Server panel's pairing card. */
  async pairServer(): Promise<void> {
    await this.request("cmux.settings.server.pair", {});
  }

  /** Settings > Mobile: this Mac was removed; allow iPhone connections again, then re-read the host lists. */
  async allowPhonesAgain(): Promise<void> {
    await this.request("cmux.settings.mobile.allow_again", {});
    await this.refreshHost();
  }

  /** Updates > Web UI: Check Now or Roll Back, then re-read the host lists; false when the host refused. */
  async runWebUpdates(action: "check" | "rollback"): Promise<boolean> {
    const reply = await this.request(`cmux.settings.web_updates.${action}` as const, {});
    await this.refreshHost();
    return reply.ok;
  }

  /** Settings > Chief > Voice input: turn the message box's mic on or off, then re-read the host lists. */
  async setVoiceInput(on: boolean): Promise<void> {
    await this.request("cmux.settings.voice_input.set", { on });
    await this.refreshHost();
  }

  /** One Accounts gesture; answers the failure text of a Keychain save, else null. */
  async runAccounts(run: AccountsRun): Promise<string | null> {
    const reply = await this.request("cmux.settings.accounts.run", run);
    await this.refreshAccounts();
    if (!reply.ok) return reply.error.message;
    return reply.value.error ?? null;
  }

  /** The host's calls for Agents > Chiefs (`cmux.chief.profile.*`, `cmux.chief.backend.*`): the
   * Chief editor reaches the Chief owner through the host's page relay, as Home does. */
  readonly chiefCalls = {
    call: <R>(op: string, params: unknown): Promise<R> => this.client.call<R>(op, params),
  };

  /** Settings > Updates' channels, with the way back to `ring` (the Channel row's value); null
   * when the host has no updater. */
  async channelsState(ring?: string): Promise<ChannelsState | null> {
    const reply = await this.request("cmux.settings.channels.state", ring ? { ring } : {});
    return reply.ok ? reply.value : null;
  }

  /** Settings > Updates' Go Back: the app restarts into the kept build; else the host's reason. */
  async channelsGoBack(ring: string, build: string): Promise<string | null> {
    const reply = await this.request("cmux.settings.channels.go_back", { ring, build });
    return reply.ok ? null : reply.error.message;
  }

  /** The Update button of a machine in Settings > Updates' row of other machines; answers the
   * host's refusal, else null (the row's push then shows it updating). */
  async channelsUpdateMachine(id: string): Promise<string | null> {
    const reply = await this.request("cmux.settings.channels.update_machine", { id });
    return reply.ok ? null : reply.error.message;
  }

  /** Settings > Agents' state; null when the host has no Agents part. */
  async agentsState(): Promise<AgentsState | null> {
    const reply = await this.request("cmux.settings.agents.state", {});
    return reply.ok ? reply.value : null;
  }

  /** One Agents gesture; the error says why the host or the daemon refused. */
  async runAgents(run: AgentsRun): Promise<Reply<unknown>> {
    return this.request("cmux.settings.agents.run", run);
  }

  /** Live Agents state while the card is shown (the host watches acpmux only then). */
  async watchAgents(onState: (state: AgentsState) => void): Promise<() => void> {
    try {
      return await this.client.subscribe<AgentsState>("cmux.settings.agents.changed", (state) => {
        if (!this.disposed) onState(state);
      });
    } catch {
      return () => {};
    }
  }

  /** Settings > Agents > Agent integrations; null when the host has none. */
  async integrationsState(): Promise<IntegrationsState | null> {
    const reply = await this.request("cmux.settings.integrations.state", {});
    return reply.ok ? reply.value : null;
  }

  /** One Agent integrations gesture, then the part as it is after it (null: the host has none). */
  async runIntegrations(run: IntegrationsRun): Promise<IntegrationsState | null> {
    await this.request("cmux.settings.integrations.run", run);
    return this.integrationsState();
  }

  /** One Harnesses gesture (Settings > Agents), then a fresh read of the part. */
  async runHarnesses(run: HarnessesRun): Promise<void> {
    await this.request("cmux.settings.harnesses.run", run);
    await this.fetchNative(settingsKeys.harnesses);
  }

  /** One Devices gesture, then a fresh read of the part; answers the host's result (a refusal
   * as its `error` text). Secrets in a relay draft pass through here and are never kept. */
  async runDevices(run: DevicesRun): Promise<DevicesRunResult> {
    const reply = await this.request("cmux.settings.devices.run", run);
    await this.refreshDevices();
    if (!reply.ok) return { error: reply.error.message, ok: false };
    return reply.value ?? {};
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
      harnesses: this.queryClient.getQueryData<HarnessesData>(settingsKeys.harnesses),
      devices: this.queryClient.getQueryData<DevicesData>(settingsKeys.devices),
      themeColors: this.queryClient.getQueryData<ThemeColorsData>(settingsKeys.themeColors),
    };
  }

  /** The page's state; the same object until the UI state or a cached part changes, so
   * useSyncExternalStore subscribers render only on a real change. */
  getSnapshot = (): SettingsState => {
    const cache = this.cacheView();
    const last = this.composed;
    if (
      last &&
      last.ui === this.ui &&
      last.cache.scope === cache.scope &&
      last.cache.scopeSettled === cache.scopeSettled &&
      last.cache.host === cache.host &&
      last.cache.accounts === cache.accounts &&
      last.cache.harnesses === cache.harnesses &&
      last.cache.devices === cache.devices &&
      last.cache.themeColors === cache.themeColors
    )
      return last.state;
    const state = composeState(this.ui, cache);
    this.composed = { ui: this.ui, cache, state };
    return state;
  };

  /** Dispatcher commands (find, back, forward, reset) for the mounted page. */
  onCommand(listener: (command: PageCommand) => void): () => void {
    this.commandListeners.add(listener);
    return () => this.commandListeners.delete(listener);
  }

  set(key: string, value: unknown): Promise<WriteResult> {
    const write = () => this.write({ kind: "set", key, value });
    return tracksAppearance(key) ? this.trackAppearance([key], write) : write();
  }

  reset(key: string): Promise<WriteResult> {
    const write = () => this.write({ kind: "reset", key });
    return tracksAppearance(key) ? this.trackAppearance([key], write) : write();
  }

  /**
   * Runs `work` (a write, a host op that sets the background, a theme level) as one step of
   * Appearance's undo stack: the states of `keys` (and the keys their writes also change, and with
   * `themes` the theme levels) are read before and after it, and what changed is recorded, named
   * `label` or by the first change ("Background → Shuffle Paintings"). Other parts of Appearance (the
   * Theme pane's rotation) call it to make their changes undoable too.
   */
  async trackAppearance<T>(
    keys: readonly string[],
    work: () => Promise<T>,
    options: { label?: string; themes?: boolean } = {},
  ): Promise<T> {
    // A step inside a step (a preset's writes, the Theme pane's rotation) is part of the outer one.
    if (this.tracking > 0) return work();
    const linked = withLinked(keys);
    const read = () => [
      ...captureKeys(this.getSnapshot(), linked),
      ...(options.themes ? captureThemes(this.getSnapshot()) : []),
    ];
    const before = read();
    this.tracking += 1;
    let result: T;
    try {
      result = await work();
    } finally {
      this.tracking -= 1;
    }
    const changes = diff(before, read());
    if (changes.length > 0)
      this.appearance.record({ label: options.label ?? changeLabel(this.getSnapshot(), changes[0]!.after), changes });
    return result;
  }

  /** Records an appearance step its caller applied itself (states it read before and after). */
  recordAppearanceChange(entry: HistoryEntry): boolean {
    return this.appearance.record(entry);
  }

  /** Undo: puts the last appearance step's earlier states back. False when there was none or the
   * owner refused (the step stays where it was). */
  async undoAppearance(): Promise<boolean> {
    const step = this.appearance.takeUndo();
    if (!step) return false;
    const ok = await this.applyAppearance(step.apply);
    if (!ok) this.appearance.restore("undo", step.entry);
    return ok;
  }

  /** Redo: puts the last undone step's states back. */
  async redoAppearance(): Promise<boolean> {
    const step = this.appearance.takeRedo();
    if (!step) return false;
    const ok = await this.applyAppearance(step.apply);
    if (!ok) this.appearance.restore("redo", step.entry);
    return ok;
  }

  /** Remembers every appearance target the first time Appearance shows in this visit, for
   * Restore How It Was. Later calls keep the first snapshot. */
  noteAppearanceOpened(): void {
    const state = this.getSnapshot();
    if (this.appearanceOpened || !state.readable) return;
    this.appearanceOpened = captureAppearance(state);
  }

  /** Whether Restore How It Was would change anything. */
  appearanceChangedSinceOpened(): boolean {
    return (
      this.appearanceOpened !== null && diff(captureAppearance(this.getSnapshot()), this.appearanceOpened).length > 0
    );
  }

  /** Puts every appearance target back as it was when Appearance first showed: one undoable step. */
  async restoreAppearanceOpened(): Promise<boolean> {
    if (!this.appearanceOpened) return false;
    return this.applyAppearanceStep(t("settingsPage.history.restoreOpened"), this.appearanceOpened);
  }

  /** Whether Reset to Defaults would change anything (an appearance key the person set). */
  appearanceCustomized(): boolean {
    const state = this.getSnapshot();
    return appearanceKeys().some((key) => {
      const row = state.rows.get(key);
      return row !== undefined && row.customized && !row.managed;
    });
  }

  /** Resets every appearance key the person set to its shipped default: one undoable step. */
  async resetAppearanceToDefaults(): Promise<boolean> {
    const state = this.getSnapshot();
    const defaults = captureKeys(state, appearanceKeys())
      .filter((target) => target.customized && !state.rows.get(target.key)?.managed)
      .map((target) => ({ ...target, value: state.rows.get(target.key)?.default, customized: false }));
    return this.applyAppearanceStep(t("settingsPage.history.resetDefaults"), defaults);
  }

  /** Applies `targets` as one recorded step named `label`; true when the owner took every write. */
  private async applyAppearanceStep(label: string, targets: readonly TargetState[]): Promise<boolean> {
    const state = this.getSnapshot();
    const current = [...captureAppearance(state)];
    const changes = diff(current, [...targets]);
    if (changes.length === 0) return true;
    const ok = await this.applyAppearance(changes.map((change) => change.after));
    this.appearance.record({ label, changes });
    return ok;
  }

  /** Writes each state (outside the undo stack): a set, a reset or a theme level. */
  private async applyAppearance(states: readonly TargetState[]): Promise<boolean> {
    let ok = true;
    let themes = false;
    for (const state of states) {
      if (state.kind === "theme") {
        themes = true;
        const reply = await this.request("cmux.settings.theme.set", { level: state.level, spec: state.spec });
        ok &&= reply.ok;
      } else {
        const result = state.customized
          ? await this.write({ kind: "set", key: state.key, value: state.value })
          : await this.write({ kind: "reset", key: state.key });
        ok &&= result.ok;
      }
    }
    if (themes) await this.refreshHost();
    return ok;
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
      return {
        ok: false,
        error: { code: "cmux.page.unavailable", message: "cmux is not connected" },
      };
    }
    const key = settingsKeys.scope("user");
    const queryClient = this.queryClient;
    const observer = new MutationObserver<number | void, TransportError, Write, { previous: ScopeData | undefined }>(
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
        // The owner's revision after the write: its own change event then reads nothing more.
        onSettled: (revision) => this.refresh(revision ?? undefined),
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
