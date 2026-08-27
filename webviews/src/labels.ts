const DEFAULT_DIFF_VIEWER_LABELS = {
  additions: "Additions",
  bars: "Bars",
  binaryFile: "Binary file",
  branchBase: "Branch base",
  branchPickerCurrent: "current",
  branchPickerBasePrefix: "Base:",
  branchPickerComparing: "Comparing {head} against {base}",
  branchPickerFilterPlaceholder: "Filter branches",
  branchPickerGenerateFailed: "Could not generate the diff. Choose a branch to retry.",
  branchPickerGenerating: "Generating diff against {ref}...",
  branchPickerGroupBranches: "Branches",
  branchPickerGroupRecent: "Recent",
  branchPickerGroupRemotes: "Remotes",
  branchPickerGroupSuggested: "Suggested",
  branchPickerGroupWorktrees: "Worktrees",
  branchPickerLoadFailed: "Could not load branches.",
  branchPickerMore: "{count} more, type to filter",
  branchPickerLoading: "Loading branches...",
  branchPickerNoMatches: "No matching branches",
  branchPickerOpen: "Change diff base",
  branchPickerUseRaw: 'Use "{ref}" (raw)',
  changedFiles: "Changed files",
  classic: "Classic",
  close: "Close",
  collapseAllDiffs: "Collapse all diffs",
  collapseUnchangedContext: "Collapse unchanged context",
  commit: "Commit",
  compare: "Compare",
  copyFailedGitApplyCommand: "Could not copy git apply command.",
  copiedGitApplyCommand: "Copied git apply command",
  copyGitApplyCommand: "Copy git apply command",
  deletions: "Deletions",
  diffStats: "Diff stats",
  diffTarget: "Diff target",
  diffViewer: "Diff viewer",
  disableEditing: "Disable editing",
  disableWordDiffs: "Disable word diffs",
  disableWordWrap: "Disable word wrap",
  enableWordDiffs: "Enable word diffs",
  enableWordWrap: "Enable word wrap",
  enableEditing: "Enable editing",
  editConflict: "Failed to save '{path}': The file changed on disk. Compare your version or overwrite the file.",
  editConflictDisk: "On disk",
  editConflictDraft: "Your edits",
  editConflictTitle: "Resolve save conflict",
  editFileSaved: "Saved '{path}'. Other edits are still unsaved.",
  editLoadFailed: "Could not load this file for editing.",
  editOverwriteFailed: "Could not overwrite '{path}'. Your edits are still available.",
  editingUnavailable: "Editing is unavailable for this diff.",
  editsSaved: "Edits saved",
  editSaveFailed: "Could not save your edits. They are still available.",
  expandAllDiffs: "Expand all diffs",
  expandUnchangedContext: "Expand unchanged context",
  files: "Files",
  hideBackgrounds: "Hide backgrounds",
  hideFiles: "Hide files",
  hideFileSearch: "Hide file search",
  hideLineNumbers: "Hide line numbers",
  indicatorStyle: "Indicator style",
  jumpToFile: "Jump to file",
  loadingDiff: "Loading diff...",
  loadingRenderer: "Loading renderer...",
  modeChange: "Mode {old} → {new}",
  noFileDiffs: "No file diffs found in patch input.",
  none: "None",
  openSourceURL: "Open source URL",
  options: "Options",
  overwrite: "Overwrite",
  parsingDiff: "Parsing diff...",
  refresh: "Refresh",
  renderFailed: "Could not render this diff. Check the patch input and try again.",
  renderingDiff: "Rendering diff...",
  repoPath: "Repository path",
  retry: "Retry",
  saveEdits: "Save edits",
  saveOrDiscardEdits: "Save or discard edits before changing the diff.",
  discardEdits: "Discard edits",
  showBackgrounds: "Show backgrounds",
  showFiles: "Show files",
  showFileSearch: "Show file search",
  showLineNumbers: "Show line numbers",
  switchToSplitDiff: "Switch to split diff",
  switchToUnifiedDiff: "Switch to unified diff",
  untitled: "Untitled",
} as const;

export type DiffViewerLabelKey = keyof typeof DEFAULT_DIFF_VIEWER_LABELS;
export type DiffViewerLabelResolver = (key: DiffViewerLabelKey) => string;

type LabelResolverOptions = {
  assertMissing?: boolean;
};

export function shouldAssertMissingLabels(): boolean {
  return Boolean(import.meta.env?.DEV);
}

export function createDiffViewerLabelResolver(
  labels: Record<string, string> | undefined,
  options: LabelResolverOptions = {}
): DiffViewerLabelResolver {
  const missingKeys = new Set<DiffViewerLabelKey>();
  return (key) => {
    const localizedValue = labels?.[key];
    if (typeof localizedValue === "string" && localizedValue.trim() !== "") {
      return localizedValue;
    }

    if (options.assertMissing && !missingKeys.has(key)) {
      missingKeys.add(key);
      throw new Error(`Missing cmux diff viewer label: ${key}`);
    }

    return DEFAULT_DIFF_VIEWER_LABELS[key];
  };
}
