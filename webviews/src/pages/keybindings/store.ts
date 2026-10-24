// The Keyboard Shortcuts page's state owner on the page side: query state, the loaded table, the
// recording flow and the write intents. The table is a projection of the provider
// (`cmux.keybindings.list`); the page keeps no optimistic copy: a write re-reads after the
// provider confirms. React reads it through `useSyncExternalStore` (no effects).
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import {
  canEditWhen,
  filterBindings,
  identity,
  isReadOnly,
  keyMatches,
  normalizeWhen,
  reconcileSelection,
  resettableCommands,
  sortBindings,
  strokes,
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
export type Recording =
  | { target: "search" }
  | {
      target: "row";
      row: string;
      /** The row as it is now; after a save, the keys it was saved with. */
      binding: Binding;
      key: string;
      display: string;
      held: string;
      /** Counts the saves of this recording (the recorder's confirm light plays on each). */
      confirmed: number;
      /** Set while the recorder asks about new keys that take other actions' keys. */
      prompt?: ConflictPrompt;
    };

/** New keys that take other actions' keys, waiting for Overwrite, Ignore or Cancel. */
export interface ConflictPrompt {
  key: string;
  display: string;
  /** The entries the keys would take (`cmux.keybindings.conflicts`). */
  conflicts: Binding[];
  /** After the answer: the recording goes on (a release asked), or closes (Close or Return). */
  after: "continue" | "close";
}

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
      this.followRecording(bindings);
      this.refilter({ selection });
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
    }
  }

  /** A recording row whose keys a save changed has a new identity after the re-read: the recorder
   *  stays on it. A row that is gone (another edit took it) ends the recording. */
  private followRecording(bindings: readonly Binding[]): void {
    const recording = this.snapshot.recording;
    if (recording?.target !== "row") return;
    const { command, key, when } = recording.binding;
    const row =
      bindings.find((binding) => identity(binding) === recording.row) ??
      bindings.find(
        (binding) =>
          !binding.removed &&
          binding.command === command &&
          binding.when === when &&
          (key ? keyMatches(binding.key, { key, exact: true }) : binding.unset === true),
      );
    if (!row) this.endRecording();
    else if (identity(row) !== recording.row)
      this.set({ recording: { ...recording, row: identity(row), binding: row } });
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
    if (!canEditWhen(binding)) return;
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

  /** "Change keybinding" (a click on the keys): the recorded strokes become this row's new keys. */
  async changeKeybinding(binding: Binding): Promise<void> {
    if (isReadOnly(binding)) return;
    if (this.snapshot.recording) this.endRecording();
    const row = identity(binding);
    this.set({ editing: undefined, selection: row });
    await this.beginRecording({ target: "row", row, binding, key: "", display: "", held: "", confirmed: 0 });
  }

  stopRecording(): void {
    if (this.snapshot.recording) this.endRecording();
  }

  /** The recorder's Close button, as Return: keys recorded so far become the row's keys (asking
   *  first when they take another action's); with none, it only closes. */
  closeRecording(): void {
    const recording = this.snapshot.recording;
    if (recording?.target !== "row") return;
    if (recording.prompt) {
      this.endRecording();
      return;
    }
    if (recording.key) void this.commit(recording, "close");
    else this.endRecording();
  }

  /** The recorder's answer to new keys that take another action's: `overwrite` saves them and
   *  removes them from the other actions, `ignore` saves them and leaves both, `cancel` saves
   *  nothing. The recording then goes on (or closes, when Close or Return asked). */
  async resolveConflict(choice: "overwrite" | "ignore" | "cancel"): Promise<void> {
    const recording = this.snapshot.recording;
    if (recording?.target !== "row" || !recording.prompt) return;
    const { prompt } = recording;
    const asked = { ...recording, prompt: undefined, key: prompt.key, display: prompt.display, held: "" };
    if (choice === "cancel") {
      if (prompt.after === "close") this.endRecording();
      else await this.recapture({ ...asked, key: "", display: "" });
      return;
    }
    this.set({ recording: asked });
    const saved = await this.save(asked);
    if (saved && choice === "overwrite") {
      for (const other of prompt.conflicts) {
        try {
          await this.client?.call(KeybindingOps.remove, {
            command: other.command,
            key: other.key,
            when: other.when,
            idempotency_key: this.key(),
          });
        } catch (error) {
          this.set(failure(error));
        }
      }
      await this.reload();
    }
    const current = this.snapshot.recording;
    if (prompt.after === "close" || current?.target !== "row") this.endRecording();
    else await this.recapture(current);
  }

  /** A click on the recorder's keys: start over from no keys ("edit further"). */
  async restartRecording(): Promise<void> {
    const recording = this.snapshot.recording;
    if (recording?.target !== "row") return;
    await this.recapture({ ...recording, prompt: undefined, key: "", display: "", held: "" });
  }

  /** The recorder stays open with `recording`; only the app's capture starts over. */
  private async recapture(recording: Extract<Recording, { target: "row" }>): Promise<void> {
    if (!this.client) return;
    this.set({ recording });
    await this.client.call(KeybindingOps.recordStop, {}).catch(() => undefined);
    const current = this.snapshot.recording;
    if (current?.target === "row" && current.row === recording.row) await this.beginRecording(current);
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
    let recording = this.snapshot.recording;
    if (!recording) return;
    // The recorder asks about a conflict: Return overwrites, Escape cancels, a new stroke drops
    // the question and records new keys; modifiers alone change nothing.
    if (recording.target === "row" && recording.prompt) {
      const only = strokes(event.key);
      if (event.cancelled) {
        void this.resolveConflict("cancel");
        return;
      }
      if (only.length === 1 && (only[0] === "return" || only[0] === "enter")) {
        void this.resolveConflict("overwrite");
        return;
      }
      if (event.released || !event.key) return;
      recording = { ...recording, prompt: undefined };
      this.set({ recording });
    }
    if (event.released) {
      if (recording.target !== "row") return;
      // Every key is up: no modifier is held any more.
      const released = { ...recording, held: "" };
      this.set({ recording: released });
      if (released.key) void this.commit(released, "continue");
      return;
    }
    const finished = event.done || event.cancelled;
    if (recording.target === "search") {
      if (!event.cancelled && event.key && event.key !== this.snapshot.keyFilter?.key) {
        this.refilter({ text: event.key, keyFilter: { key: event.key, exact: false } });
      }
      if (finished) this.endRecording();
      return;
    }
    // The first key of a shortcut (at the start, or after a release saved one): a bare Delete
    // removes the row's keys, a bare Return (the app's recorder records it as a stroke when no
    // key came first) closes the recorder.
    if (!event.cancelled && strokes(event.key).length === 1) {
      const first = strokes(event.key)[0];
      if (first === "delete" || first === "backspace") {
        this.endRecording();
        void this.remove(recording.binding);
        return;
      }
      if (first === "return" || first === "enter") {
        this.endRecording();
        return;
      }
    }
    if (!finished) {
      this.set({ recording: { ...recording, key: event.key, display: event.display, held: event.held ?? "" } });
      return;
    }
    if (event.done && event.key) void this.commit({ ...recording, key: event.key, display: event.display }, "close");
    else this.endRecording();
  }

  /** New keys for the recording row: saved at once, unless they take another action's keys
   *  (`cmux.keybindings.conflicts`); then the recorder asks (Overwrite, Ignore, Cancel) and the
   *  app's capture stays on for its Return and Escape. `after`: the recording goes on (a release),
   *  or closes (Close, Return, a press outside). */
  private async commit(recording: Extract<Recording, { target: "row" }>, after: "continue" | "close"): Promise<void> {
    const { binding, key, display } = recording;
    const same = !binding.unset && keyMatches(key, { key: binding.key, exact: true });
    const conflicts = same ? [] : await this.conflictsOf(binding, key);
    const current = this.snapshot.recording;
    if (current?.target !== "row" || current.row !== recording.row) return;
    if (conflicts.length) {
      await this.recapture({ ...current, key, display, held: "", prompt: { key, display, conflicts, after } });
      return;
    }
    await this.save({ ...current, key, display });
    if (after === "close") this.endRecording();
  }

  /** The entries `key` would take from other actions; none when the app cannot say. */
  private async conflictsOf(binding: Binding, key: string): Promise<Binding[]> {
    try {
      const result = await this.client?.call<BindingListResult>(KeybindingOps.conflicts, {
        command: binding.command,
        key,
        when: binding.when,
      });
      return result?.bindings ?? [];
    } catch {
      return [];
    }
  }

  /** Saves the recording's keys as its row's (the shortcut so far, a release or a confirmed
   *  conflict); the recording goes on, its light confirming. False when the write failed. */
  private async save(recording: Extract<Recording, { target: "row" }>): Promise<boolean> {
    const { binding, key, display } = recording;
    const same = !binding.unset && keyMatches(key, { key: binding.key, exact: true });
    // The recorder follows the new keys before the write: the provider's `changed` re-read can
    // land before the write's reply, and must find the row by them.
    const saved: Binding = { ...binding, key, display, unset: false };
    this.set({ recording: { ...recording, binding: saved }, notice: undefined });
    if (!same) {
      const params = this.setParams(binding, key, binding.when);
      try {
        await this.client?.call(KeybindingOps.set, params);
      } catch (error) {
        const current = this.snapshot.recording;
        if (current?.target === "row" && current.row === recording.row)
          this.set({ recording: { ...current, binding } });
        this.set(failure(error));
        return false;
      }
      this.pendingSelect = { command: params.command, key, when: params.when ?? null };
    }
    const current = this.snapshot.recording;
    // Still this row on these keys (a re-read may have put the listed row in its place).
    if (
      current?.target === "row" &&
      current.binding.command === binding.command &&
      keyMatches(current.binding.key, { key, exact: true })
    ) {
      this.set({ recording: { ...current, confirmed: current.confirmed + 1 } });
    }
    if (!same) await this.reload();
    return true;
  }

  /** Ends the capture on both sides; the app may have ended it already (stop is idempotent). */
  private endRecording(): void {
    this.set({ recording: undefined });
    void this.client?.call(KeybindingOps.recordStop, {}).catch(() => undefined);
  }

  // Writes.

  remove(binding: Binding): Promise<void> {
    if (isReadOnly(binding) || binding.unset) return Promise.resolve();
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
      idempotency_key: this.key(),
    };
    // An unset row has no entry to replace: the new keys bind the action again.
    if (!binding.unset) params.replaces = { key: binding.key, when: binding.when };
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
