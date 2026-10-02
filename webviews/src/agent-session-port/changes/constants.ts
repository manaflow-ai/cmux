// Static pane copy, layout tables and frames measured from the captures.
import type { ChangesBanner, PaneFrame } from "./types";
import type { ChangeScope, FileHeaderButtonId, ToolbarButtonId } from "./model";

/** Tracked-only card (manual-changes-current.png) for a scan that skipped `count` files. */
export const trackedOnlyBanner = (count: number): ChangesBanner => ({
  title: "Showing tracked changes only",
  body: `The Changes tab skipped ${count.toLocaleString("en-US")} untracked files to stay responsive. If these files are generated, clean them up and refresh`,
  actionLabel: "Copy cleanup command",
  secondaryLabel: "Refresh",
});

/** Centered message in the diff column for non-loaded states. */
export const LOAD_COPY = {
  error: {
    title: "Couldn't load changes",
    body: "Refresh to try loading the changes again",
    action: "Retry",
  },
  empty: { title: "No changes", body: "There is nothing to review in this scope", action: null },
} as const;

/** Text under the tree filter when no row matches. */
export const TREE_EMPTY_TEXT = "No matching files";

/** Pane placement in the 1728x1084 Codex window of the manual captures (CSS px). */
export const MANUAL_FRAME: PaneFrame = { left: 774.5, top: 44, width: 949.5, height: 1036 };

/** Pane placement when the main column keeps its default width (window x 1140.5). */
export const SIDE_FRAME: PaneFrame = { left: 1140.5, top: 44, width: 583.5, height: 1036 };

export const TOOLBAR_LABELS: Record<ToolbarButtonId, string> = {
  options: "Changes options",
  jump: "Jump to file",
  refresh: "Refresh",
  wrap: "Wrap lines",
  collapse: "Collapse all diffs",
  split: "Split diff",
  tree: "Show file tree",
};

export const HEADER_LABELS: Record<FileHeaderButtonId, string> = {
  viewed: "Mark as viewed",
  "open-tab": "Open file in a tab",
  "open-editor": "Open in editor",
  actions: "File actions",
};

/** Full toolbar: button and icon center (CSS px from the toolbar group's left edge). */
export const FULL_TOOLBAR: { id: ToolbarButtonId; x: number }[] = [
  { id: "options", x: 16.25 },
  { id: "jump", x: 46.5 },
  { id: "refresh", x: 76.25 },
  { id: "wrap", x: 110 },
  { id: "collapse", x: 144 },
  { id: "split", x: 178.25 },
  { id: "tree", x: 209 },
];

/** Scope menu order; "-" is a separator. */
export const SCOPE_ORDER: (ChangeScope | "-")[] = [
  "lastTurn",
  "-",
  "uncommitted",
  "unstaged",
  "staged",
  "-",
  "committed",
  "branch",
];
