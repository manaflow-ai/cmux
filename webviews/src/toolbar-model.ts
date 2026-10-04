// Pure models for the diff toolbar: the source menu, the "..." options menu, the
// floating toolbar pill and the jump-to-file palette. Components in DiffToolbar.tsx
// render these; tests cover them without a DOM.
import type { DiffSource } from "./diff/generated/protocol";
import type { DiffItem } from "./diff-stream";
import { fileName } from "./diff-stream";
import type { IconName } from "./icons";
import type { DiffViewerLabelKey } from "./labels";
import type { DiffViewerOptions } from "./pierre-options";

// ---------------------------------------------------------------------------
// Source menu
// ---------------------------------------------------------------------------

/**
 * Uncommitted changes are a branch session against HEAD: the sidecar diffs the
 * working tree against `merge-base(HEAD, base)`, which for `HEAD` is `git diff HEAD`
 * (staged and unstaged tracked changes).
 */
export const UNCOMMITTED_BASE_REF = "HEAD";

export type SourceMenuId = "last-turn" | "uncommitted" | "unstaged" | "staged" | "committed" | "branch";

/** Where choosing an entry goes: a typed session source, or (older pages) a URL. */
export type SourceTarget = { kind: "session"; source: DiffSource } | { kind: "url"; url: string };

export type SourceMenuEntry = {
  id: string;
  /** Shipped label for the fixed rows; commit rows carry host text in `text`. */
  labelKey?: DiffViewerLabelKey;
  text?: string;
  /** Null when this diff cannot open the entry (no host option and no typed session). */
  target: SourceTarget | null;
  checked: boolean;
  /** Committed's submenu rows. */
  children?: SourceMenuEntry[];
};

export type SourceMenuModel = {
  sections: SourceMenuEntry[][];
  selected: SourceMenuEntry | null;
};

/** One row of `payload.sourceOptions`, the host's list of diff sources. */
export type SourceOption = {
  value?: unknown;
  label?: unknown;
  selected?: unknown;
  disabled?: unknown;
  url?: unknown;
  sessionSource?: unknown;
  group?: unknown;
};

const SOURCE_LABELS: Record<Exclude<SourceMenuId, "committed">, DiffViewerLabelKey> = {
  "last-turn": "sourceLastTurn",
  uncommitted: "sourceUncommitted",
  unstaged: "sourceUnstaged",
  staged: "sourceStaged",
  branch: "sourceBranch",
};

/** Whether `option` is a commit row of the Committed submenu (`commit:<sha>` or group "committed"). */
export function isCommitOption(option: SourceOption): boolean {
  return (typeof option.value === "string" && option.value.startsWith("commit:")) || option.group === "committed";
}

/** The session source the active diff represents, as a menu id. */
export function activeSourceMenuId(source: DiffSource | null): SourceMenuId | null {
  switch (source?.kind) {
    case "patch":
      return "last-turn";
    case "unstaged":
      return "unstaged";
    case "staged":
      return "staged";
    case "branch":
      return source.baseRef === UNCOMMITTED_BASE_REF ? "uncommitted" : "branch";
    default:
      return null;
  }
}

/**
 * Builds the source menu: Last Turn | Uncommitted, Unstaged, Staged | Committed >,
 * Branch. Host `sourceOptions` win; with a typed transport and a repository, the
 * git sources the sidecar supports are offered even when the host lists none.
 * Last Turn and Committed exist only when the host supplies them.
 */
export function sourceMenuModel(input: {
  sourceOptions: unknown;
  repoRoot: string | null;
  activeSource: DiffSource | null;
  /** The last branch session per repository, so Branch reopens its base. */
  rememberedBranch?: Extract<DiffSource, { kind: "branch" }> | null;
  branchBaseRef?: string | null;
  typedTransport: boolean;
  isValidSource: (value: unknown) => value is DiffSource;
}): SourceMenuModel {
  const options = Array.isArray(input.sourceOptions)
    ? (input.sourceOptions as SourceOption[]).filter((option) => option && typeof option === "object")
    : [];
  const byValue = new Map<string, SourceOption>();
  for (const option of options) {
    if (typeof option.value === "string" && !isCommitOption(option)) {
      byValue.set(option.value, option);
    }
  }
  const optionTarget = (option: SourceOption | undefined): SourceTarget | null => {
    if (!option || option.disabled === true) return null;
    if (input.isValidSource(option.sessionSource)) return { kind: "session", source: option.sessionSource };
    if (typeof option.url === "string" && option.url !== "") return { kind: "url", url: option.url };
    return null;
  };
  const synthesize = (id: SourceMenuId): SourceTarget | null => {
    const repoRoot = input.repoRoot;
    if (!input.typedTransport || !repoRoot) return null;
    switch (id) {
      case "unstaged":
      case "staged":
        return { kind: "session", source: { kind: id, repoRoot } };
      case "uncommitted":
        return { kind: "session", source: { kind: "branch", repoRoot, baseRef: UNCOMMITTED_BASE_REF } };
      case "branch": {
        const remembered =
          input.rememberedBranch && input.rememberedBranch.baseRef !== UNCOMMITTED_BASE_REF
            ? input.rememberedBranch.baseRef
            : undefined;
        const baseRef = remembered ?? input.branchBaseRef ?? undefined;
        return {
          kind: "session",
          source: baseRef ? { kind: "branch", repoRoot, baseRef } : { kind: "branch", repoRoot },
        };
      }
      default:
        return null;
    }
  };

  const activeId = activeSourceMenuId(input.activeSource);
  const selectedValue =
    activeId ??
    (typeof options.find((option) => option.selected === true)?.value === "string"
      ? (options.find((option) => option.selected === true)?.value as string)
      : null);

  const commitChildren: SourceMenuEntry[] = options.filter(isCommitOption).map((option) => ({
    id: String(option.value ?? option.label ?? ""),
    text: typeof option.label === "string" ? option.label : String(option.value ?? ""),
    target: optionTarget(option),
    checked: option.selected === true && activeId !== "branch" && activeId !== "uncommitted",
  }));
  const commitChecked = commitChildren.some((child) => child.checked);

  const fixed = (id: Exclude<SourceMenuId, "committed">): SourceMenuEntry => ({
    id,
    labelKey: SOURCE_LABELS[id],
    target: optionTarget(byValue.get(id)) ?? synthesize(id),
    checked: !commitChecked && selectedValue === id,
  });
  const committed: SourceMenuEntry = {
    id: "committed",
    labelKey: "sourceCommitted",
    target: null,
    checked: commitChecked,
    children: commitChildren,
  };
  const sections = [
    [fixed("last-turn")],
    [fixed("uncommitted"), fixed("unstaged"), fixed("staged")],
    [committed, fixed("branch")],
  ];
  const selected =
    sections.flat().find((entry) => entry.checked && entry.id !== "committed") ??
    commitChildren.find((child) => child.checked) ??
    null;
  return { sections, selected };
}

// ---------------------------------------------------------------------------
// Diff totals
// ---------------------------------------------------------------------------

/** Added and removed line totals across every file, from the parsed hunks. */
export function diffLineTotals(items: readonly DiffItem[]): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;
  for (const item of items) {
    const hunks = item.fileDiff?.hunks;
    if (!Array.isArray(hunks)) continue;
    for (const hunk of hunks) {
      additions += typeof hunk?.additionLines === "number" ? hunk.additionLines : 0;
      deletions += typeof hunk?.deletionLines === "number" ? hunk.deletionLines : 0;
    }
  }
  return { additions, deletions };
}

// ---------------------------------------------------------------------------
// "..." options menu
// ---------------------------------------------------------------------------

export type OverflowMenuItemId =
  | "load-full-files"
  | "rich-preview"
  | "word-diffs"
  | "hide-whitespace"
  | "hide-imports"
  | "copy-git-apply";

export type OverflowMenuItem = {
  id: OverflowMenuItemId;
  icon: IconName;
  labelKey: DiffViewerLabelKey;
  /** Undefined for actions; a boolean for toggles. */
  checked?: boolean;
  /** False when nothing in this build can apply the option; the row explains why. */
  available: boolean;
};

/**
 * What the viewer can apply. `fullFiles` needs a `loadDiffFiles` source of file
 * contents (expandUnchanged on a patch-parsed diff needs both sides of the file);
 * the others need the sidecar to diff with those flags. None exists yet.
 */
export type OverflowCapabilities = {
  fullFiles: boolean;
  richPreview: boolean;
  hideWhitespace: boolean;
  hideImports: boolean;
};

export const NO_HOST_CAPABILITIES: OverflowCapabilities = {
  fullFiles: false,
  richPreview: false,
  hideWhitespace: false,
  hideImports: false,
};

export function overflowMenuItems(
  options: Pick<DiffViewerOptions, "expandUnchanged" | "wordDiffs">,
  capabilities: OverflowCapabilities,
): OverflowMenuItem[] {
  return [
    {
      id: "load-full-files",
      icon: "file",
      labelKey: "loadFullFiles",
      checked: capabilities.fullFiles && options.expandUnchanged,
      available: capabilities.fullFiles,
    },
    { id: "rich-preview", icon: "image", labelKey: "richPreview", checked: false, available: capabilities.richPreview },
    { id: "word-diffs", icon: "plusMinus", labelKey: "wordDiffs", checked: options.wordDiffs, available: true },
    {
      id: "hide-whitespace",
      icon: "eye",
      labelKey: "hideWhitespace",
      checked: false,
      available: capabilities.hideWhitespace,
    },
    {
      id: "hide-imports",
      icon: "package",
      labelKey: "hideImports",
      checked: false,
      available: capabilities.hideImports,
    },
    { id: "copy-git-apply", icon: "clipboard", labelKey: "copyGitApplyCommand", available: true },
  ];
}

// ---------------------------------------------------------------------------
// Floating toolbar pill
// ---------------------------------------------------------------------------

export type PillButtonId = "options" | "find" | "refresh" | "wrap" | "expand" | "layout" | "files";

export type PillButton = {
  id: PillButtonId;
  /** DOM id; existing ids are kept for the options, layout and files buttons. */
  domId: string;
  icon: IconName;
  /** Tooltip and accessible name. */
  labelKey: DiffViewerLabelKey;
  pressed?: boolean;
  expanded?: boolean;
};

export function toolbarPillButtons(state: {
  options: Pick<DiffViewerOptions, "collapsed" | "layout" | "wordWrap">;
  filesVisible: boolean;
  optionsOpen: boolean;
  findOpen: boolean;
}): PillButton[] {
  const { options } = state;
  return [
    { id: "options", domId: "options-button", icon: "dots", labelKey: "options", expanded: state.optionsOpen },
    { id: "find", domId: "find-toggle", icon: "fileSearch", labelKey: "findInDiff", pressed: state.findOpen },
    { id: "refresh", domId: "refresh-button", icon: "refresh", labelKey: "refresh" },
    { id: "wrap", domId: "wrap-toggle", icon: "wrap", labelKey: "wordWrap", pressed: options.wordWrap },
    {
      id: "expand",
      domId: "expand-toggle",
      icon: options.collapsed ? "expand" : "collapse",
      labelKey: options.collapsed ? "expandAllDiffs" : "collapseAllDiffs",
    },
    {
      id: "layout",
      domId: "layout-toggle",
      icon: options.layout,
      labelKey: options.layout === "split" ? "switchToUnifiedDiff" : "switchToSplitDiff",
    },
    {
      id: "files",
      domId: "files-toggle",
      icon: "files",
      labelKey: state.filesVisible ? "hideFiles" : "showFiles",
      pressed: state.filesVisible,
    },
  ];
}

/** Roving focus inside a toolbar or menu: the index `key` moves to, or null. */
export function rovingIndex(
  key: string,
  current: number,
  count: number,
  axis: "horizontal" | "vertical",
): number | null {
  if (count === 0) return null;
  const next = axis === "horizontal" ? "ArrowRight" : "ArrowDown";
  const previous = axis === "horizontal" ? "ArrowLeft" : "ArrowUp";
  if (key === next) return (current + 1 + count) % count;
  if (key === previous) return (current - 1 + count) % count;
  if (key === "Home") return 0;
  if (key === "End") return count - 1;
  return null;
}

// ---------------------------------------------------------------------------
// Jump to file palette
// ---------------------------------------------------------------------------

export type JumpRow = { id: string; name: string; directory: string };

/** Rendered rows are capped so a 10k-file diff stays a small DOM. */
export const JUMP_ROW_CAP = 200;

export function splitPath(path: string): { name: string; directory: string } {
  const slash = path.lastIndexOf("/");
  return slash < 0 ? { name: path, directory: "" } : { name: path.slice(slash + 1), directory: path.slice(0, slash) };
}

/**
 * Files for the palette, sorted by file name. A query keeps files whose path
 * contains it (case-insensitive), ranking name-prefix, then name, then path matches.
 */
export function jumpToFileRows(
  items: readonly DiffItem[],
  query: string,
  fallbackName: string,
  cap = JUMP_ROW_CAP,
): { rows: JumpRow[]; hidden: number } {
  const needle = query.trim().toLowerCase();
  const ranked: { row: JumpRow; rank: number; key: string }[] = [];
  for (const item of items) {
    const path = item.fileDiff ? fileName(item.fileDiff, fallbackName) : item.id;
    const { name, directory } = splitPath(path);
    const lowerName = name.toLowerCase();
    let rank = 0;
    if (needle !== "") {
      if (lowerName.startsWith(needle)) rank = 0;
      else if (lowerName.includes(needle)) rank = 1;
      else if (path.toLowerCase().includes(needle)) rank = 2;
      else continue;
    }
    ranked.push({ row: { id: item.id, name, directory }, rank, key: `${lowerName}\u0000${directory.toLowerCase()}` });
  }
  ranked.sort((a, b) => a.rank - b.rank || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const rows = ranked.slice(0, cap).map((entry) => entry.row);
  return { rows, hidden: ranked.length - rows.length };
}
