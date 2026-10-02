// Data model and state machine of the Changes pane.
//
//   ChangeSet          what changed (one scope of one repository)
//   ChangesLoad        load state of a scope: loading / error / empty / loaded
//   ChangesSource      the loads the pane can switch between, by scope
//   ChangesPaneState   the pane's own UI state (scope, collapse, viewed, filter, menus, …)
//   changesReducer     every interaction as an action on ChangesPaneState
//
// The pane renders (ChangesSource, ChangesPaneState). A capture is just an initial state.

/* ---------------- Domain ---------------- */

export type ChangeScope = "lastTurn" | "uncommitted" | "unstaged" | "staged" | "committed" | "branch";

export const SCOPE_LABELS: Record<ChangeScope, string> = {
  lastTurn: "Last Turn",
  uncommitted: "Uncommitted",
  unstaged: "Unstaged",
  staged: "Staged",
  committed: "Committed",
  branch: "Branch",
};

/** `untracked` is an added file git does not track yet (live git data, src/server). */
export type FileChangeStatus = "added" | "modified" | "deleted" | "renamed" | "untracked";

/** One changed file: either both full texts (Pierre computes hunks) or a unified patch. */
export interface ChangedFile {
  path: string;
  /** Path before a rename. */
  previousPath?: string;
  status: FileChangeStatus;
  additions: number;
  deletions: number;
  /** Full text of each side; null when the side does not exist (added/deleted). */
  oldContents?: string | null;
  newContents?: string | null;
  /** Unified diff for this file, when full texts are not available. */
  patch?: string;
  /** Shiki language override; inferred from the extension when omitted. */
  lang?: string;
  /** Marked as viewed (initial value; the pane's state owns it afterwards). */
  viewed?: boolean;
  /** Binary on either side (shown as a header with `note`). */
  binary?: boolean;
  /** A symbolic link on either side; contents are the link targets. */
  symlink?: boolean;
  /** A submodule (gitlink); contents are `Subproject commit <sha>`. */
  submodule?: boolean;
  /** File modes when they changed (e.g. 100644 → 100755). */
  oldMode?: string;
  newMode?: string;
  /** One line under the file header: why the diff is not shown in full, or a mode change. */
  note?: string;
}

export interface ChangeSet {
  scope: ChangeScope;
  /** Branch comparison (`head → base`); branch scope only. */
  head?: string;
  base?: string;
  files: ChangedFile[];
  /** Totals; default sums `files`. */
  additions?: number;
  deletions?: number;
  /** Untracked files the scan skipped; shows the tracked-only banner when > 0. */
  untrackedSkipped?: number;
  /** Every changed file the scope has, and how many past the listing limit were left out. */
  totalFiles?: number;
  filesOmitted?: number;
}

export type ChangesLoad =
  | { status: "loading" }
  | { status: "error"; message?: string }
  | { status: "empty" }
  | { status: "loaded"; changeSet: ChangeSet };

/** Loads by scope. A scope without an entry renders as empty. */
export type ChangesSource = Partial<Record<ChangeScope, ChangesLoad>>;

export const loaded = (changeSet: ChangeSet): ChangesSource => ({
  [changeSet.scope]: { status: "loaded", changeSet },
});

export function totals(cs: ChangeSet) {
  return {
    additions: cs.additions ?? cs.files.reduce((n, f) => n + f.additions, 0),
    deletions: cs.deletions ?? cs.files.reduce((n, f) => n + f.deletions, 0),
  };
}

/* ---------------- UI state ---------------- */

/** Ids of the round buttons in the pane toolbar, left to right. */
export type ToolbarButtonId =
  | "options" // … Changes options
  | "jump" // file with magnifier: Jump to file
  | "refresh"
  | "wrap" // ↩| toggle line wrapping
  | "collapse" // +-= Collapse all diffs
  | "split" // red/green: split vs unified
  | "tree"; // two stacked squares: show the file tree

/** Ids of the per-file header buttons, left to right. */
export type FileHeaderButtonId = "viewed" | "open-tab" | "open-editor" | "actions";

/** Open popover menu. Opening a menu also draws its trigger pressed. */
export type ChangesMenu =
  | { kind: "scope" } // Last Turn … Branch ✓ (scope button)
  | { kind: "options" } // Refresh … Copy git apply command (toolbar ⋯)
  | { kind: "file"; path: string }; // Copy path, Open file in a tab, Collapse file (header ⋯)

/** Pointer target. Hovering a button shows its tooltip; hovering a header shows its chevron. */
export type ChangesHover =
  | { kind: "toolbar"; button: ToolbarButtonId }
  | { kind: "file"; path: string; button?: FileHeaderButtonId };

export interface ChangesPaneState {
  scope: ChangeScope;
  /** Collapsed diffs (header only); "all" after Collapse all. */
  collapsed: readonly string[] | "all";
  viewed: readonly string[];
  /** Tree filter text. */
  filter: string;
  /** Selected tree row. null selects the first file. */
  selectedPath: string | null;
  showTree: boolean;
  wrap: boolean;
  split: boolean;
  menu: ChangesMenu | null;
  hover: ChangesHover | null;
  /** Toolbar button with the keyboard focus ring. */
  focus: ToolbarButtonId | null;
  /** Scroll offsets of the real scrollers, CSS px: the diff list and each diff's code area. */
  scroll: { diffTop: number; diffLeft: Readonly<Record<string, number>> };
}

export const INITIAL_PANE_STATE: ChangesPaneState = {
  scope: "branch",
  collapsed: [],
  viewed: [],
  filter: "",
  selectedPath: null,
  showTree: true,
  wrap: false,
  split: false,
  menu: null,
  hover: null,
  focus: null,
  scroll: { diffTop: 0, diffLeft: {} },
};

export function initPaneState(initial?: Partial<ChangesPaneState>, source?: ChangesSource): ChangesPaneState {
  const s = {
    ...INITIAL_PANE_STATE,
    ...initial,
    scroll: { ...INITIAL_PANE_STATE.scroll, ...initial?.scroll },
  };
  const load = source?.[s.scope];
  if (initial?.viewed === undefined && load?.status === "loaded") {
    s.viewed = load.changeSet.files.filter((f) => f.viewed).map((f) => f.path);
  }
  return s;
}

export const isCollapsed = (s: ChangesPaneState, path: string) =>
  s.collapsed === "all" || s.collapsed.includes(path) || s.viewed.includes(path);

/* ---------------- Actions ---------------- */

export type ChangesAction =
  | { type: "toggleMenu"; menu: ChangesMenu }
  | { type: "closeMenu" }
  | { type: "selectScope"; scope: ChangeScope }
  | { type: "toggleCollapseAll"; paths: readonly string[] }
  | { type: "toggleCollapsed"; path: string; paths: readonly string[] }
  | { type: "toggleViewed"; path: string }
  | { type: "setFilter"; filter: string }
  | { type: "selectFile"; path: string }
  | { type: "toggle"; flag: "showTree" | "wrap" | "split" }
  | { type: "hover"; target: ChangesHover | null }
  | { type: "focus"; button: ToolbarButtonId | null };

const sameMenu = (a: ChangesMenu | null, b: ChangesMenu) =>
  a?.kind === b.kind && (a.kind !== "file" || (b.kind === "file" && a.path === b.path));

export function changesReducer(s: ChangesPaneState, a: ChangesAction): ChangesPaneState {
  switch (a.type) {
    case "toggleMenu":
      return { ...s, menu: sameMenu(s.menu, a.menu) ? null : a.menu, hover: null };
    case "closeMenu":
      return s.menu ? { ...s, menu: null } : s;
    case "selectScope":
      return {
        ...s,
        scope: a.scope,
        menu: null,
        selectedPath: null,
        scroll: { diffTop: 0, diffLeft: {} },
      };
    case "toggleCollapseAll": {
      const all = s.collapsed === "all" || a.paths.every((p) => s.collapsed.includes(p));
      return { ...s, collapsed: all ? [] : "all", menu: null };
    }
    case "toggleCollapsed": {
      const list = s.collapsed === "all" ? a.paths : s.collapsed;
      const next = list.includes(a.path) ? list.filter((p) => p !== a.path) : [...list, a.path];
      return { ...s, collapsed: next, menu: null };
    }
    case "toggleViewed":
      return {
        ...s,
        viewed: s.viewed.includes(a.path) ? s.viewed.filter((p) => p !== a.path) : [...s.viewed, a.path],
      };
    case "setFilter":
      return { ...s, filter: a.filter };
    case "selectFile":
      return { ...s, selectedPath: a.path };
    case "toggle":
      return { ...s, [a.flag]: !s[a.flag], menu: null };
    case "hover":
      return sameHover(s.hover, a.target) ? s : { ...s, hover: a.target };
    case "focus":
      return s.focus === a.button ? s : { ...s, focus: a.button };
  }
}

function sameHover(a: ChangesHover | null, b: ChangesHover | null) {
  if (a === b) return true;
  if (!a || !b || a.kind !== b.kind) return false;
  return a.kind === "toolbar"
    ? a.button === (b as typeof a).button
    : a.path === (b as typeof a).path && a.button === (b as typeof a).button;
}
