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
  /**
   * Optional: the action has no keys because the user removed them (cmux.json unbinds it). `key`
   * and `display` are empty; the row stays so the action can get a key again (`set` with no
   * `replaces`), and Reset gives the default back.
   */
  unset?: boolean;
  /** Set on a removed default when the user's Ghostty config claims its key (read-only; no Reset). */
  removedBy?: "ghostty";
  /** Set on a system-wide key (Start Agent from Any App) cmux could not register: another app holds it. */
  heldElsewhere?: boolean;
  /**
   * Optional, on a `conflicts` reply: the new keys' `when` holds wherever this entry runs, so
   * Overwrite removes its keys. False: the new keys win only in their own context, and this entry
   * keeps its keys everywhere else (Overwrite leaves it).
   */
  takesAll?: boolean;
}

export interface BindingListResult {
  bindings: Binding[];
}

/** `cmux.keybindings.conflicts`: the entries the keys would take, and the app's refusal of them
 *  (a key another action always runs), before any write. */
export interface ConflictsResult extends BindingListResult {
  refusal?: string;
  /** The title of the action that holds the refused keys (one that always runs, a numbered
   *  family), when there is one. */
  owner?: string;
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
  /** Optional: the glyphs of the modifiers held now, before a key makes the next stroke ("⇧⌘");
   *  "" on a stroke and when none are held. */
  held?: string;
  /** Optional: every key of the last stroke is up (the recording goes on; the page saves then). */
  released?: boolean;
}

export const KeybindingOps = {
  list: "cmux.keybindings.list",
  set: "cmux.keybindings.set",
  remove: "cmux.keybindings.remove",
  /** `{command, key, when?}`: the entries new keys for `command` would take from other actions
   *  (`{bindings}`): each one's `when` holding means the new entry's holds, and it comes later. */
  conflicts: "cmux.keybindings.conflicts",
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

/** The error code of a write that takes keys another action holds in the same place. */
export const CONFLICT = "cmux.keybindings.conflict";

/** The error code of a write the app cannot do yet (no keybindings.json writer). */
export const UNSUPPORTED = "cmux.keybindings.unsupported";

/** The most strokes one binding has (KeyBindingTable.maxSequenceLength). */
export const MAX_STROKES = 4;
