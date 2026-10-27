// An in-memory `cmux.keybindings` provider for the browser dev loop and tests. It is not the
// backend: the app's binding table (KeyBindingLoader, KeyBindingTable) owns layers, validation
// and dispatch. The mock keeps default/app entries, user entries and removals, and the same op
// contract, so the page can run without the app.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { LINK_CLOSED, MockPageStreams } from "../shared/pageStreams";
import {
  KeybindingOps,
  MAX_STROKES,
  UNSUPPORTED,
  type Binding,
  type BindingListResult,
  type ConflictsResult,
  type RecordedEvent,
  type RemoveParams,
  type ResetParams,
  type SetParams,
} from "./types";

export interface MockEntry {
  command: string;
  key: string;
  when: string | null;
  args?: Record<string, unknown>;
}

export interface MockLayers {
  /** Default and app entries, in table order. */
  base: Array<MockEntry & { source: "default" | "app" }>;
  user: MockEntry[];
  removals: Array<Pick<MockEntry, "command" | "key" | "when">>;
  /** Commands cmux.json unbinds (`shortcuts.bindings.<id>: null`): no default keys, one unset row. */
  unbound?: string[];
}

export interface MockCall {
  op: string;
  params: unknown;
}

const MOD_GLYPHS: Array<[string, string]> = [
  ["ctrl", "⌃"],
  ["alt", "⌥"],
  ["shift", "⇧"],
  ["cmd", "⌘"],
];

const KEY_GLYPHS: Record<string, string> = {
  tab: "⇥",
  enter: "↩",
  escape: "⎋",
  space: "Space",
  backspace: "⌫",
  delete: "⌦",
  left: "←",
  right: "→",
  up: "↑",
  down: "↓",
};

/** Glyphs for a key text: "ctrl+k s" -> "⌃K S". */
export function displayFor(key: string): string {
  return key
    .trim()
    .split(/\s+/)
    .map((stroke) => {
      const parts = stroke.toLowerCase().split("+");
      const base = parts.pop() ?? "";
      const mods = MOD_GLYPHS.filter(([name]) => parts.includes(name)).map(([, glyph]) => glyph);
      return mods.join("") + (KEY_GLYPHS[base] ?? base.toUpperCase());
    })
    .join(" ");
}

const normalized = (key: string) => key.trim().toLowerCase().split(/\s+/).join(" ");
const sameEntry = (a: Pick<MockEntry, "command" | "key" | "when">, b: Pick<MockEntry, "command" | "key" | "when">) =>
  a.command === b.command && normalized(a.key) === normalized(b.key) && (a.when ?? null) === (b.when ?? null);

export class MockKeybindingsProvider implements PageClient {
  layers: MockLayers;
  readonly calls: MockCall[] = [];
  /** Set to make every write fail with `cmux.keybindings.unsupported`. */
  unsupported = false;
  /** Set to make every call reject as if the host went away. */
  offline = false;
  /** Set to make keymap import and export fail (a broken file). */
  keymapFails = false;
  recording = false;
  /** Commands whose system-wide key another app holds (GlobalHotKeyService conflicts). */
  heldElsewhere = new Set<string>();
  readonly page = new MockPageStreams();
  private readonly titles: Record<string, string>;
  private readonly changed = new Set<(data: unknown, seq: number) => void>();
  private readonly recorded = new Set<(data: unknown, seq: number) => void>();
  private readonly handlers = new Map<string, PageHandler>();
  private seq = 0;
  private strokesSoFar: string[] = [];
  /** A stroke was recorded and its keys are not all up yet. */
  private awaitingRelease = false;
  private detachDom?: () => void;

  constructor(
    layers: MockLayers = sampleLayers(),
    titles: Record<string, string> = SAMPLE_TITLES,
    private readonly options: { captureDom?: boolean } = {},
  ) {
    this.layers = layers;
    this.titles = titles;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    switch (op) {
      case KeybindingOps.list:
        return this.list() as R;
      case KeybindingOps.set:
        this.write(() => this.set(params as SetParams));
        return {} as R;
      case KeybindingOps.remove:
        // A keybindings.json remove goes through the home daemon: a test can make it wait.
        if (this.removeGate) await this.removeGate;
        this.write(() => this.remove(params as RemoveParams));
        return {} as R;
      case KeybindingOps.reset:
        this.write(() => this.reset(params as ResetParams));
        return {} as R;
      case KeybindingOps.conflicts:
        return this.conflicts(params as { command: string; key: string; when?: string | null }) as R;
      case KeybindingOps.recordStart:
        this.startRecording();
        return {} as R;
      case KeybindingOps.recordStop:
        this.stopRecording();
        return {} as R;
      case KeybindingOps.keymapExport:
      case KeybindingOps.keymapImport:
        if (this.keymapFails) throw pageError("cmux.keybindings.keymap_failed", "the keymap file does not parse");
        return { path: "/tmp/cmux-next-keymap.json" } as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const listener = onEvent as (data: unknown, seq: number) => void;
    const pageStream = this.page.subscribe(stream, listener);
    if (pageStream) return pageStream;
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    const set =
      stream === KeybindingOps.changed ? this.changed : stream === KeybindingOps.recorded ? this.recorded : undefined;
    if (!set) throw pageError("cmux.protocol.unknown_op", stream);
    set.add(listener);
    return () => void set.delete(listener);
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => this.handlers.delete(op);
  }

  get subscriberCount(): number {
    return this.changed.size;
  }

  /** The dispatcher records one stroke ("cmd+k"); the fourth stroke ends the recording. */
  press(stroke: string): void {
    if (!this.recording) return;
    this.strokesSoFar.push(stroke.toLowerCase());
    this.awaitingRelease = true;
    const done = this.strokesSoFar.length >= MAX_STROKES;
    this.emitRecorded(done, false);
  }

  /** The dispatcher saw Return: the recorded strokes are final. */
  finish(): void {
    if (this.recording) this.emitRecorded(true, false);
  }

  /** The dispatcher saw Escape. */
  cancel(): void {
    if (this.recording) this.emitRecorded(false, true);
  }

  /** The owner's table changed outside the page (keybindings.json edited, for example). */
  notifyChanged(): void {
    for (const listener of this.changed) listener({}, ++this.seq);
  }

  /** The dispatcher saw the held modifiers change ("⇧⌘"; "" when none are held). */
  hold(held: string): void {
    if (this.recording) this.emitRecorded(false, false, held);
  }

  /** The dispatcher saw every key of the last stroke go up. */
  release(): void {
    if (!this.recording || !this.awaitingRelease) return;
    this.awaitingRelease = false;
    this.emitRecorded(false, false, "", true);
    // As the app: every key up ends the shortcut; the next stroke starts a new one.
    this.strokesSoFar = [];
  }

  private emitRecorded(done: boolean, cancelled: boolean, held = "", released = false): void {
    const key = this.strokesSoFar.join(" ");
    const event: RecordedEvent = { key, display: displayFor(key), done, cancelled, held, released };
    if (done || cancelled) this.stopRecording();
    for (const listener of this.recorded) listener(event, ++this.seq);
  }

  private startRecording(): void {
    this.recording = true;
    this.strokesSoFar = [];
    if (this.options.captureDom && typeof window !== "undefined" && !this.detachDom) {
      // Dev loop only: the browser stands in for the app's key dispatcher.
      const onKey = (event: KeyboardEvent) => {
        event.preventDefault();
        event.stopPropagation();
        if (["Meta", "Control", "Shift", "Alt"].includes(event.key)) this.hold(heldFor(event));
        else if (event.key === "Escape") this.cancel();
        else if (event.key === "Enter" && this.strokesSoFar.length) this.finish();
        else {
          const stroke = strokeFor(event);
          if (stroke) this.press(stroke);
        }
      };
      const onKeyUp = (event: KeyboardEvent) => {
        const held = heldFor(event);
        if (!held) this.release();
        else if (["Meta", "Control", "Shift", "Alt"].includes(event.key)) this.hold(held);
      };
      window.addEventListener("keydown", onKey, true);
      window.addEventListener("keyup", onKeyUp, true);
      this.detachDom = () => {
        window.removeEventListener("keydown", onKey, true);
        window.removeEventListener("keyup", onKeyUp, true);
      };
    }
  }

  private stopRecording(): void {
    this.recording = false;
    this.detachDom?.();
    this.detachDom = undefined;
  }

  private write(apply: () => void): void {
    if (this.unsupported) throw pageError(UNSUPPORTED, "keybindings.json writing is not supported yet");
    apply();
    this.notifyChanged();
  }

  private set(params: SetParams): void {
    // As the app (KeybindingPageWrites.verdict): another action's keys in the same place are a
    // refusal (Overwrite takes them from it first).
    const taken = this.active().some(
      (entry) =>
        entry.command !== params.command &&
        normalized(entry.key) === normalized(params.key) &&
        (entry.when ?? null) === (params.when ?? null),
    );
    if (taken) throw pageError("cmux.keybindings.conflict", "another action has these keys");
    // An unbound command stays unbound: its new key is a cmux.json override, the defaults stay out.
    if (params.replaces) {
      this.removeEntry({ command: params.command, key: params.replaces.key, when: params.replaces.when });
    }
    const entry: MockEntry = { command: params.command, key: normalized(params.key), when: params.when ?? null };
    if (params.args) entry.args = params.args;
    this.layers.user.push(entry);
  }

  /** The command's only active key: cmux.json unbinds the action (KeybindingPageWrites.remove). */
  private remove(params: RemoveParams): void {
    const others = this.active().filter((entry) => entry.command === params.command && !sameEntry(entry, params));
    if (others.length > 0) {
      this.removeEntry(params);
      return;
    }
    this.layers.user = this.layers.user.filter((entry) => entry.command !== params.command);
    this.layers.unbound = [...(this.layers.unbound ?? []), params.command];
  }

  /** The entries that run: defaults and app entries not removed or unbound, then user entries. */
  private active(): MockEntry[] {
    const unbound = new Set(this.layers.unbound);
    const base = this.layers.base.filter(
      (entry) => !unbound.has(entry.command) && !this.layers.removals.some((removal) => sameEntry(removal, entry)),
    );
    return [...base, ...this.layers.user];
  }

  /** A user entry is deleted; a default or app entry gets a removal. */
  private removeEntry(target: Pick<MockEntry, "command" | "key" | "when">): void {
    const index = this.layers.user.findIndex((entry) => sameEntry(entry, target));
    if (index >= 0) {
      this.layers.user.splice(index, 1);
      return;
    }
    if (this.layers.base.some((entry) => sameEntry(entry, target)))
      this.layers.removals.push({ command: target.command, key: normalized(target.key), when: target.when ?? null });
  }

  private reset(params: ResetParams): void {
    this.layers.user = this.layers.user.filter((entry) => entry.command !== params.command);
    this.layers.removals = this.layers.removals.filter((entry) => entry.command !== params.command);
    this.layers.unbound = this.layers.unbound?.filter((command) => command !== params.command);
  }

  private list(): BindingListResult {
    const rows: Array<Omit<Binding, "id" | "conflicts">> = [];
    const unbound = new Set(this.layers.unbound);
    for (const entry of this.layers.base) {
      if (unbound.has(entry.command)) continue;
      const removed = this.layers.removals.some((removal) => sameEntry(removal, entry));
      rows.push({ ...this.row(entry), source: entry.source, ...(removed ? { removed: true } : {}) });
    }
    for (const entry of this.layers.user) rows.push({ ...this.row(entry), source: "user" });
    for (const command of unbound) {
      if (rows.some((row) => row.command === command && !row.removed)) continue;
      const title = this.titles[command] ?? command;
      rows.push({ key: "", display: "", command, title, when: null, source: "user", unset: true });
    }
    const bindings: Binding[] = rows.map((row, id) => ({
      ...row,
      id,
      conflicts: [],
      ...(!row.removed && this.heldElsewhere.has(row.command) ? { heldElsewhere: true } : {}),
    }));
    // As the app: two actions whose `when` can hold at once, one of them not a shipped default.
    for (const a of bindings) {
      if (a.removed || a.unset) continue;
      a.conflicts = bindings
        .filter(
          (b) =>
            b.id !== a.id &&
            b.command !== a.command &&
            !(a.source === "default" && b.source === "default") &&
            !b.removed &&
            !b.unset &&
            normalized(b.key) === normalized(a.key) &&
            whenOverlaps(a.when, b.when),
        )
        .map((b) => b.id);
    }
    return { bindings };
  }

  /** Set to hold every remove until it resolves (a slow keybindings.json write). */
  removeGate?: Promise<void>;

  /** Keys the mock refuses for any other action, as the app refuses a key another action always
   *  runs (`refused`: key -> that action's title). */
  refused = new Map<string, string>();

  /** `cmux.keybindings.conflicts`: the active entries of other commands new keys would take, and
   *  the refusal of the keys. */
  private conflicts(params: { command: string; key: string; when?: string | null }): ConflictsResult {
    const { bindings } = this.list();
    const owner = this.refused.get(normalized(params.key));
    const taken = bindings.filter(
      (b) =>
        !b.removed &&
        !b.unset &&
        b.command !== params.command &&
        normalized(b.key) === normalized(params.key) &&
        whenOverlaps(b.when, params.when ?? null),
    );
    return {
      ...(owner
        ? { refusal: `${displayFor(params.key)} is ${owner}, which always runs. Choose another shortcut.`, owner }
        : {}),
      // As the app (`WhenClause.implies`): the new keys' `when` holds wherever the entry runs.
      bindings: taken.map((b) => ({ ...b, takesAll: (params.when ?? null) === null || b.when === params.when })),
    };
  }

  private row(entry: MockEntry): Omit<Binding, "id" | "conflicts" | "source"> {
    const row: Omit<Binding, "id" | "conflicts" | "source"> = {
      key: normalized(entry.key),
      display: displayFor(entry.key),
      command: entry.command,
      title: this.titles[entry.command] ?? entry.command,
      when: entry.when,
    };
    if (entry.args) row.args = entry.args;
    return row;
  }
}

/** Whether two `when` texts can hold at once (the app's `WhenClause.canOverlap`, read simply: no
 *  condition on either side, or the same one). */
function whenOverlaps(a: string | null, b: string | null): boolean {
  return a === null || b === null || a === b;
}

/** The held modifiers of a key event as glyphs (⌃⌥⇧⌘), for the dev loop's stand-in dispatcher. */
function heldFor(event: KeyboardEvent): string {
  const held: Array<[boolean, string]> = [
    [event.ctrlKey, "⌃"],
    [event.altKey, "⌥"],
    [event.shiftKey, "⇧"],
    [event.metaKey, "⌘"],
  ];
  return held
    .filter(([down]) => down)
    .map(([, glyph]) => glyph)
    .join("");
}

/** A key event as one stroke, for the dev loop's stand-in dispatcher. */
function strokeFor(event: KeyboardEvent): string | undefined {
  if (["Meta", "Control", "Shift", "Alt"].includes(event.key)) return undefined;
  const named: Record<string, string> = {
    ArrowLeft: "left",
    ArrowRight: "right",
    ArrowUp: "up",
    ArrowDown: "down",
    " ": "space",
    Tab: "tab",
    Backspace: "backspace",
    Delete: "delete",
    Enter: "enter",
  };
  const base = named[event.key] ?? (event.code.startsWith("Key") ? event.code.slice(3) : event.key).toLowerCase();
  const mods = [event.ctrlKey && "ctrl", event.altKey && "alt", event.shiftKey && "shift", event.metaKey && "cmd"];
  return [...mods.filter(Boolean), base].join("+");
}

export const SAMPLE_TITLES: Record<string, string> = {
  "palette.open": "Open Command Palette",
  "palette.files": "Go to File",
  "tab.new": "New Tab",
  "tab.close": "Close Tab",
  "tab.next": "Next Tab",
  "tab.previous": "Previous Tab",
  "tab.select": "Select Tab",
  "workspace.new": "New Workspace",
  "settings.open": "Open Settings",
  "keybindings.open": "Open Keyboard Shortcuts",
  "split.right": "Split Right",
  "split.down": "Split Down",
  "find.open": "Find",
  "history.open": "Show History",
};

/** Sample layers for the dev loop and tests: chords, an app entry, a user entry, a removed
 *  default, an action whose keys were removed, and two conflicts. */
export function sampleLayers(): MockLayers {
  return {
    base: [
      { command: "palette.open", key: "cmd+shift+p", when: null, source: "default" },
      { command: "palette.files", key: "cmd+p", when: null, source: "default" },
      { command: "tab.new", key: "cmd+t", when: null, source: "default" },
      { command: "tab.close", key: "cmd+w", when: null, source: "default" },
      { command: "tab.next", key: "ctrl+tab", when: null, source: "default" },
      { command: "tab.previous", key: "ctrl+shift+tab", when: null, source: "default" },
      { command: "tab.select", key: "cmd+1", when: null, args: { index: 1 }, source: "default" },
      { command: "workspace.new", key: "cmd+n", when: null, source: "default" },
      { command: "settings.open", key: "cmd+,", when: null, source: "default" },
      { command: "keybindings.open", key: "cmd+k cmd+s", when: null, source: "default" },
      { command: "split.right", key: "cmd+d", when: null, source: "default" },
      { command: "split.down", key: "cmd+shift+d", when: null, source: "default" },
      { command: "find.open", key: "cmd+f", when: "surface.kind == 'terminal'", source: "default" },
      { command: "history.open", key: "cmd+y", when: null, source: "app" },
    ],
    user: [
      { command: "history.open", key: "cmd+shift+p", when: "surface.kind == 'browser'" },
      { command: "split.down", key: "cmd+k cmd+d", when: null },
    ],
    removals: [{ command: "split.down", key: "cmd+shift+d", when: null }],
    unbound: ["workspace.new"],
  };
}
