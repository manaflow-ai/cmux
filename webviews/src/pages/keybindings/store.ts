// The Keyboard Shortcuts page's state owner on the page side: query state, the loaded table, the
// recording flow and the write intents. The table is a projection of the provider
// (`cmux.keybindings.list`); the page keeps no optimistic copy: a write re-reads after the
// provider confirms. React reads it through `useSyncExternalStore` (no effects).
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import {
  filterBindings,
  identity,
  keyMatches,
  normalizeWhen,
  reconcileSelection,
  resettableCommands,
  sortBindings,
  type KeyFilter,
} from "./model";
import {
  KeybindingOps,
  UNSUPPORTED,
  type Binding,
  type BindingListResult,
  type RecordedEvent,
  type SetParams,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

/** Where recorded strokes go: the search field, or a new key for one row. */
export type Recording = { target: "search" } | { target: "row"; row: string; binding: Binding; display: string };

export type Notice = { kind: "unsupported" } | { kind: "failed"; message: string };

export interface KeybindingsSnapshot {
  /** The whole table, sorted by title then key. */
  bindings: Binding[];
  /** The rows the query shows. */
  rows: Binding[];
  text: string;
  keyFilter?: KeyFilter;
  conflictsOnly: boolean;
  /** Commands that have a user entry or a removed default. */
  resettable: Set<string>;
  /** Row identity (model.ts `identity`). */
  selection?: string;
  /** The row whose `when` is in the inline editor. */
  editing?: string;
  recording?: Recording;
  notice?: Notice;
  /** True until the first reply arrives. */
  loading: boolean;
  connection: Connection;
}

export interface KeybindingsStoreOptions {
  newKey?: () => string;
}

export class KeybindingsStore {
  private snapshot: KeybindingsSnapshot;
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private stops: Array<() => void> = [];
  private started = false;
  /** After a write: select the row it made once the re-read shows it. */
  private pendingSelect?: { command: string; key: string; when: string | null };

  constructor(
    private readonly client: PageClient | null,
    private readonly options: KeybindingsStoreOptions = {},
  ) {
    this.snapshot = {
      bindings: [],
      rows: [],
      text: "",
      conflictsOnly: false,
      resettable: new Set(),
      loading: client !== null,
      connection: client ? "connecting" : "disconnected",
    };
  }

  getSnapshot = (): KeybindingsSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Subscribes to the change and record streams and loads the table. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.started) return;
    this.started = true;
    try {
      await this.tolerate(() => this.client!.subscribe(KeybindingOps.changed, () => void this.reload()));
      await this.tolerate(() =>
        this.client!.subscribe<RecordedEvent>(KeybindingOps.recorded, (event) => this.onRecorded(event)),
      );
      this.stops.push(
        await subscribePageStreams(this.client, { onConnection: (connected) => this.onConnection(connected) }),
      );
    } catch (error) {
      this.set({ loading: false, ...failure(error) });
      return;
    }
    if (!this.started) {
      this.stop();
      return;
    }
    await this.reload();
  }

  stop(): void {
    this.started = false;
    if (this.snapshot.recording) this.endRecording();
    for (const stop of this.stops) stop();
    this.stops = [];
  }

  /** A stream the owner does not serve yet is fine (no live updates); other failures are not. */
  private async tolerate(start: () => Promise<() => void>): Promise<void> {
    try {
      this.stops.push(await start());
    } catch (error) {
      if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op")) throw error;
    }
  }

  private onConnection(connected: boolean): void {
    if (!connected) {
      this.set({ connection: "disconnected", loading: false });
    } else if (this.snapshot.connection === "disconnected") {
      this.set({ connection: "connecting" });
      void this.reload();
    }
  }

  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const result = await this.client.call<BindingListResult>(KeybindingOps.list, {});
      if (generation !== this.generation) return;
      const bindings = sortBindings(result.bindings ?? []);
      let selection = this.snapshot.selection;
      const pending = this.pendingSelect;
      if (pending) {
        const made = bindings.find(
          (b) =>
            b.command === pending.command &&
            b.source === "user" &&
            b.when === pending.when &&
            keyMatches(b.key, { key: pending.key, exact: true }),
        );
        if (made) selection = identity(made);
        this.pendingSelect = undefined;
      }
      this.set({ bindings, resettable: resettableCommands(bindings), loading: false, connection: "connected" });
      this.refilter({ selection });
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
    }
  }

  // Query.

  setText(text: string): void {
    if (text === this.snapshot.text && !this.snapshot.keyFilter) return;
    this.refilter({ text, keyFilter: undefined });
  }

  setConflictsOnly(conflictsOnly: boolean): void {
    this.refilter({ conflictsOnly });
  }

  /** The conflict marker: every entry on the same keys. */
  showSameKeys(binding: Binding): void {
    this.refilter({ text: binding.key, keyFilter: { key: binding.key, exact: true }, conflictsOnly: false });
  }

  /** The `reset` page command: clear search and filters. */
  resetQuery(): void {
    this.refilter({ text: "", keyFilter: undefined, conflictsOnly: false });
  }

  select(selection: string | undefined): void {
    if (selection !== this.snapshot.selection) this.set({ selection });
  }

  dismissNotice(): void {
    if (this.snapshot.notice) this.set({ notice: undefined });
  }

  // Inline `when` editor.

  editWhen(binding: Binding): void {
    if (binding.removed) return;
    this.set({ editing: identity(binding), selection: identity(binding) });
  }

  cancelEdit(): void {
    if (this.snapshot.editing) this.set({ editing: undefined });
  }

  /** Return in the editor: a new user entry with the new `when` replaces the old entry. */
  async commitWhen(binding: Binding, text: string): Promise<void> {
    this.set({ editing: undefined });
    const when = normalizeWhen(text);
    if (when === binding.when) return;
    await this.write(KeybindingOps.set, this.setParams(binding, binding.key, when));
  }

  // Recording.

  /** The "Record keys" toggle: strokes fill the search and filter by key prefix. */
  async toggleSearchRecording(): Promise<void> {
    if (this.snapshot.recording) {
      this.endRecording();
      return;
    }
    await this.beginRecording({ target: "search" });
  }

  /** "Change keybinding": the recorded strokes become this row's new keys. */
  async changeKeybinding(binding: Binding): Promise<void> {
    if (binding.removed) return;
    if (this.snapshot.recording) this.endRecording();
    const row = identity(binding);
    this.set({ editing: undefined, selection: row });
    await this.beginRecording({ target: "row", row, binding, display: "" });
  }

  stopRecording(): void {
    if (this.snapshot.recording) this.endRecording();
  }

  private async beginRecording(recording: Recording): Promise<void> {
    if (!this.client) return;
    this.set({ recording, notice: undefined });
    try {
      await this.client.call(KeybindingOps.recordStart, {});
    } catch (error) {
      this.set({ recording: undefined, ...failure(error) });
    }
  }

  /** The app's dispatcher captured a stroke (the page never reads key events itself). */
  private onRecorded(event: RecordedEvent): void {
    const recording = this.snapshot.recording;
    if (!recording) return;
    const finished = event.done || event.cancelled;
    if (recording.target === "search") {
      if (!event.cancelled && event.key) {
        this.refilter({ text: event.key, keyFilter: { key: event.key, exact: false } });
      }
      if (finished) this.endRecording();
      return;
    }
    if (!finished) {
      this.set({ recording: { ...recording, display: event.display } });
      return;
    }
    this.endRecording();
    if (event.done && event.key && !keyMatches(event.key, { key: recording.binding.key, exact: true })) {
      void this.write(KeybindingOps.set, this.setParams(recording.binding, event.key, recording.binding.when));
    }
  }

  /** Ends the capture on both sides; the app may have ended it already (stop is idempotent). */
  private endRecording(): void {
    this.set({ recording: undefined });
    void this.client?.call(KeybindingOps.recordStop, {}).catch(() => undefined);
  }

  // Writes.

  remove(binding: Binding): Promise<void> {
    if (binding.removed) return Promise.resolve();
    return this.write(KeybindingOps.remove, {
      command: binding.command,
      key: binding.key,
      when: binding.when,
      idempotency_key: this.key(),
    });
  }

  reset(binding: Binding): Promise<void> {
    return this.write(KeybindingOps.reset, { command: binding.command, idempotency_key: this.key() });
  }

  /** Export Keymap…: the host asks where and writes the file. */
  async exportKeymap(): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(KeybindingOps.keymapExport, {});
      if (this.snapshot.notice) this.set({ notice: undefined });
    } catch (error) {
      this.set(failure(error));
    }
  }

  /** Import Keymap…: the host asks for a file and imports it; the table re-lists. */
  async importKeymap(): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(KeybindingOps.keymapImport, {});
    } catch (error) {
      this.set(failure(error));
      return;
    }
    if (this.snapshot.notice) this.set({ notice: undefined });
    await this.reload();
  }

  private setParams(binding: Binding, key: string, when: string | null): SetParams {
    const params: SetParams = {
      command: binding.command,
      key,
      when,
      replaces: { key: binding.key, when: binding.when },
      idempotency_key: this.key(),
    };
    if (binding.args) params.args = binding.args;
    return params;
  }

  private async write(op: string, params: unknown): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(op, params);
    } catch (error) {
      this.set(failure(error));
      return;
    }
    if (op === KeybindingOps.set) {
      const { command, key, when } = params as SetParams;
      this.pendingSelect = { command, key, when: when ?? null };
    }
    if (this.snapshot.notice) this.set({ notice: undefined });
    // The provider also sends `cmux.keybindings.changed`; re-reading here keeps the page correct
    // when the event is late, and the generation check drops the older reply.
    await this.reload();
  }

  private refilter(patch: Partial<KeybindingsSnapshot>): void {
    const next = { ...this.snapshot, ...patch };
    const rows = filterBindings(next.bindings, next);
    this.set({ ...patch, rows, selection: reconcileSelection(rows, next.selection) });
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<KeybindingsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function failure(error: unknown): Partial<KeybindingsSnapshot> {
  if (isPageError(error) && error.code === UNSUPPORTED) return { notice: { kind: "unsupported" } };
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected" };
  return { notice: { kind: "failed", message: error instanceof Error ? error.message : String(error) } };
}
