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
  type ConflictsResult,
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
      /** Why the recorded keys were not saved (the app's refusal: a key another action always
       *  runs); the next key clears it. */
      refusal?: string;
      /** The action that holds the refused keys, when the app names one. */
      refusalOwner?: string;
      /** Counts the times the recorder said keys are taken (its red light plays on each). */
      warned: number;
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
    // The saved row can carry another `when` (a default's own conditions, not cmux.json's).
    const same = (binding: Binding) =>
      !binding.removed &&
      binding.command === command &&
      (key ? keyMatches(binding.key, { key, exact: true }) : binding.unset === true);
    const row =
      bindings.find((binding) => identity(binding) === recording.row) ??
      bindings.find((binding) => same(binding) && binding.when === when) ??
      bindings.find(same);
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
    await this.beginRecording({
      target: "row",
      row,
      binding,
      key: "",
      display: "",
      held: "",
      confirmed: 0,
      warned: 0,
    });
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

  /** The recorder's answer to keys another action has: `overwrite` takes them from the other
   *  actions first, then saves them (a key that action always runs is free then); `close` saves
   *  nothing and closes. A new shortcut instead drops the question (onRecorded). */
  async resolveConflict(choice: "overwrite" | "close"): Promise<void> {
    const recording = this.snapshot.recording;
    if (recording?.target !== "row" || !recording.prompt) return;
    const { prompt } = recording;
    if (choice === "close") {
      this.endRecording();
      return;
    }
    const asked = {
      ...recording,
      prompt: undefined,
      refusal: undefined,
      key: prompt.key,
      display: prompt.display,
      held: "",
    };
    this.set({ recording: asked });
    for (const other of prompt.conflicts) {
      try {
        await this.client?.call(KeybindingOps.remove, {
          command: other.command,
          key: other.key,
          when: other.when,
          idempotency_key: this.key(),
        });
      } catch (error) {
        // The keys stay the other action's: the recorder says why and saves nothing.
        const current = this.snapshot.recording;
        const shown = failure(error);
        if (current?.target === "row" && shown.notice?.kind === "failed") {
          this.set({ recording: { ...current, refusal: shown.notice.message, warned: current.warned + 1 } });
        } else this.set(shown);
        await this.reload();
        return;
      }
    }
    await this.save(asked);
    const current = this.snapshot.recording;
    // Another row's recorder took over while the writes ran: it stays as it is.
    if (current?.target !== "row" || current.binding.command !== recording.binding.command) return;
    if (prompt.after === "close" && !current.refusal) this.endRecording();
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
      await this.client.call(KeybindingOps.recordStart, { target: recording.target });
    } catch (error) {
      this.set({ recording: undefined, ...failure(error) });
    }
  }

  /** The app's dispatcher captured a stroke (the page never reads key events itself). */
  private onRecorded(event: RecordedEvent): void {
    let recording = this.snapshot.recording;
    if (!recording) return;
    // A refusal shows until the next key goes down (the next shortcut).
    if (recording.target === "row" && recording.refusal && (event.key || event.held) && !event.released) {
      recording = { ...recording, refusal: undefined, refusalOwner: undefined };
      this.set({ recording });
    }
    // The recorder asks about a conflict: Return overwrites, Escape cancels, a new stroke drops
    // the question and records new keys; modifiers alone change nothing.
    if (recording.target === "row" && recording.prompt) {
      const only = strokes(event.key);
      if (event.cancelled) {
        void this.resolveConflict("close");
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
      // Nothing down and no stroke (a modifier change after a release): the keys shown stay; a
      // new modifier or key going down starts the next shortcut.
      if (!event.key && !event.held) {
        if (recording.held) this.set({ recording: { ...recording, held: "" } });
        return;
      }
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
    const { conflicts, refusal, owner } = same ? { conflicts: [] } : await this.conflictsOf(binding, key);
    const current = this.snapshot.recording;
    // Newer keys went down (or another row records) while the app answered: they decide.
    if (current?.target !== "row" || current.row !== recording.row || current.key !== key || current.prompt) return;
    const warned = current.warned + 1;
    if (conflicts.length) {
      // Taken: the recorder asks (Overwrite, or record a new shortcut); Overwrite also frees a
      // key the other action always runs.
      await this.recapture({ ...current, key, display, held: "", warned, prompt: { key, display, conflicts, after } });
      return;
    }
    if (refusal) {
      // Never saved: the recorder says why and records the next shortcut.
      await this.recapture({ ...current, key, display, held: "", warned, refusal, refusalOwner: owner });
      return;
    }
    const saved = await this.save({ ...current, key, display });
    const now = this.snapshot.recording;
    if (now?.target !== "row" || now.binding.command !== binding.command) return;
    // A refused save keeps the recorder open on why, recording the next shortcut.
    if (!saved && now.refusal) await this.recapture(now);
    else if (after === "close") this.endRecording();
  }

  /** The entries `key` would take from other actions, and the app's refusal of the keys; none
   *  when the app cannot say. */
  private async conflictsOf(
    binding: Binding,
    key: string,
  ): Promise<{ conflicts: Binding[]; refusal?: string; owner?: string }> {
    try {
      const result = await this.client?.call<ConflictsResult>(KeybindingOps.conflicts, {
        command: binding.command,
        key,
        when: binding.when,
      });
      return { conflicts: result?.bindings ?? [], refusal: result?.refusal, owner: result?.owner };
    } catch {
      return { conflicts: [] };
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
        const shown = failure(error);
        // A refused save shows in the recorder (its keys and why), not in the page's notice.
        if (current?.target === "row" && current.row === recording.row) {
          if (shown.notice?.kind === "failed") {
            this.set({ recording: { ...current, binding, refusal: shown.notice.message, warned: current.warned + 1 } });
            return false;
          }
          this.set({ recording: { ...current, binding } });
        }
        this.set(shown);
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
