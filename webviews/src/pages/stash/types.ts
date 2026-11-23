// Wire types of the Stashed Tabs page (`stash-v1`, cmux-tui/spec/resource-operations-v2.json
// `stash.*`). The daemon's stash store (cmux-tui-core state/stash_store.rs) is the source of truth.

/** One tab of a stashed workspace, for display. */
export interface StashWorkspaceTab {
  kind?: string;
  title?: string;
  /** Only for a web page, with secret-looking query keys stripped. */
  url?: string;
}

/** One stashed member: a page, or a whole workspace. */
export interface StashMember {
  /** Stable while the member stays stashed; restore and delete name it. */
  id: string;
  /** `tab` when absent (a `stash-v1` daemon lists only pages). */
  kind?: "tab" | "workspace";
  url?: string;
  title?: string;
  /** A workspace's name. */
  name?: string;
  browser_profile_id?: string;
  tab_count?: number;
  tabs?: StashWorkspaceTab[];
}

/** One stash (`stash.list`, newest first). */
export interface StashRecord {
  id: string;
  name?: string;
  /** Unix ms; `cmux.protocol/2` may send it as a decimal string. */
  created_at_ms: number | string;
  members: StashMember[];
}

/** A stash as the page holds it (`created_at_ms` a number). */
export interface StashGroup extends Omit<StashRecord, "created_at_ms"> {
  created_at_ms: number;
}

export interface StashImportTab {
  url: string;
  title?: string;
}

export interface StashImportGroup {
  tabs: StashImportTab[];
}

/** A daemon mutation's reply (`mutation_result`): the op's own answer under `value`. */
export interface StashMutation<T> {
  value: T;
  generation?: number;
  revision: string;
  replayed: boolean;
}

export interface StashImported {
  stash_ids?: string[];
  imported_tabs?: number;
  skipped_tabs?: number;
}

/** `cmux.stash.delete`'s answer: false when the person pressed Undo on the app's toast. */
export interface StashDeleted {
  deleted: boolean;
}

export const StashOps = {
  /** The daemon's `stash.list`. */
  list: "cmux.stash.list",
  /** The daemon's `stash.import {source, groups}`; the app adds its browser engine. */
  import: "cmux.stash.import",
  /** The app: reopens `{stash, members?, new_workspace?}` and shows it. */
  restore: "cmux.stash.restore",
  /** The app: hides nothing itself; shows its Undo toast, then deletes `{stash, members?}`. */
  delete: "cmux.stash.delete",
  /** The daemon's `stash-changed` (a stash saved, restored or deleted anywhere). */
  changed: "cmux.stash.changed",
} as const;
