// Wire types of the `cmux.keybindings` ops (plans/cmux-next/keybindings.md 8). The Swift
// provider in the app serves them; the mock provider (mockProvider.ts) serves the same contract.

/** `ghostty`: a keybind the user's Ghostty config changed (terminal only); `ghostty-fallback`: a
 *  Ghostty default keybind. cmux never writes the Ghostty config, so both are read-only here. */
export type BindingSource = "default" | "app" | "user" | "ghostty" | "ghostty-fallback";

/** One entry of the effective binding table. */
export interface Binding {
  /** Position in the table. A later id wins over an earlier one on the same keys. */
  id: number;
  /** keybindings.json syntax: strokes separated by spaces ("ctrl+k s", "cmd+shift+]"). */
  key: string;
  /** Glyphs of the keys ("⌃K S"), strokes separated by spaces. */
  display: string;
  /** Action id. */
  command: string;
  /** Localized action title. */
  title: string;
  when: string | null;
  args?: Record<string, unknown>;
  source: BindingSource;
  /** Ids of other entries on the same keys whose `when` can hold at the same time. */
  conflicts: number[];
  /**
   * Optional: a default or app entry that a user removal hides. The provider may list it so the
   * page can offer Reset; it is not active.
   */
  removed?: boolean;
  /** Set on a removed default when the user's Ghostty config claims its key (read-only; no Reset). */
  removedBy?: "ghostty";
}

export interface BindingListResult {
  bindings: Binding[];
}

/** The entry a `set` replaces: the old keys and `when` of the same command. */
export interface BindingRef {
  key: string;
  when: string | null;
}

export interface SetParams {
  command: string;
  key: string;
  when?: string | null;
  args?: Record<string, unknown>;
  replaces?: BindingRef;
  idempotency_key: string;
}

export interface RemoveParams {
  command: string;
  key: string;
  when: string | null;
  idempotency_key: string;
}

export interface ResetParams {
  command: string;
  idempotency_key: string;
}

/** One recorded stroke from the app's key dispatcher. */
export interface RecordedEvent {
  /** All strokes so far, keybindings.json syntax. */
  key: string;
  display: string;
  /** Return or the fourth stroke ended the recording. */
  done: boolean;
  /** Escape ended the recording; `key` holds no new stroke. */
  cancelled: boolean;
}

export const KeybindingOps = {
  list: "cmux.keybindings.list",
  set: "cmux.keybindings.set",
  remove: "cmux.keybindings.remove",
  reset: "cmux.keybindings.reset",
  recordStart: "cmux.keybindings.record.start",
  recordStop: "cmux.keybindings.record.stop",
  recorded: "cmux.keybindings.recorded",
  changed: "cmux.keybindings.changed",
  /** Shows a save panel and writes the `shortcuts` object to the chosen file. */
  keymapExport: "cmux.keybindings.keymap.export",
  /** Shows an open panel and imports the chosen keymap file into cmux-next.json. */
  keymapImport: "cmux.keybindings.keymap.import",
} as const;

/** The error code of a write the app cannot do yet (no keybindings.json writer). */
export const UNSUPPORTED = "cmux.keybindings.unsupported";

/** The most strokes one binding has (KeyBindingTable.maxSequenceLength). */
export const MAX_STROKES = 4;
