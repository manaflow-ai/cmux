const DEFAULT_DIFF_VIEWER_LABELS = {
  additions: "Additions",
  bars: "Bars",
  branchBase: "Branch base",
  branchPickerCurrent: "current",
  branchPickerBasePrefix: "Base:",
  branchPickerComparing: "Comparing {head} against {base}",
  branchPickerFilterPlaceholder: "Filter branches",
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
  collapseAllDiffs: "Collapse all diffs",
  collapseUnchangedContext: "Collapse unchanged context",
  commitMessage: "Commit message",
  commit: "Commit",
  copyFailedGitApplyCommand: "Could not copy git apply command.",
  copyFailedStageCommitCommand: "Could not copy stage & commit command.",
  copiedGitApplyCommand: "Copied git apply command",
  copiedStageCommitCommand: "Copied stage & commit command",
  copyGitApplyCommand: "Copy git apply command",
  copyStageCommitCommand: "Copy stage & commit command",
  deletions: "Deletions",
  diffStats: "Diff stats",
  diffTarget: "Diff target",
  diffViewer: "Diff viewer",
  disableWordDiffs: "Disable word diffs",
  disableWordWrap: "Disable word wrap",
  enableWordDiffs: "Enable word diffs",
  enableWordWrap: "Enable word wrap",
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
  noFileDiffs: "No file diffs found in patch input.",
  none: "None",
  openSourceURL: "Open source URL",
  options: "Options",
  parsingDiff: "Parsing diff...",
  refresh: "Refresh",
  renderFailed: "Could not render this diff. Check the patch input and try again.",
  renderingDiff: "Rendering diff...",
  repoPath: "Repository path",
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
