export const DEFAULT_DIFF_VIEWER_LABELS = {
  additions: "Additions",
  bars: "Bars",
  binaryFile: "Binary file",
  branchBase: "Branch base",
  branchPickerBasePrefix: "Base:",
  branchPickerComparing: "Comparing {head} against {base}",
  branchPickerCurrent: "current",
  branchPickerFilterPlaceholder: "Search branches",
  branchPickerGenerateFailed: "Could not generate the diff. Choose a branch to retry.",
  branchPickerGenerating: "Generating diff against {ref}...",
  branchPickerGroupBranches: "Branches",
  branchPickerGroupRecent: "Recent",
  branchPickerGroupRemotes: "Remotes",
  branchPickerGroupSuggested: "Suggested",
  branchPickerGroupWorktrees: "Worktrees",
  branchPickerLoadFailed: "Could not load branches.",
  branchPickerLoading: "Loading branches...",
  branchPickerMore: "{count} more, type to filter",
  branchPickerNoMatches: "No matching branches",
  branchPickerOpen: "Change diff base",
  branchPickerUseRaw: 'Use "{ref}" (raw)',
  changedFiles: "Changed files",
  changedSinceViewed: "Changed since viewed",
  classic: "Classic",
  clearFileFilter: "Clear filter",
  collapseAllDiffs: "Collapse all diffs",
  collapseFile: "Collapse {file}",
  collapseUnchangedContext: "Collapse unchanged context",
  commit: "Commit",
  copiedGitApplyCommand: "Copied git apply command",
  copyFailedGitApplyCommand: "Could not copy git apply command.",
  copyGitApplyCommand: "Copy git apply command",
  deletions: "Deletions",
  diffStats: "Diff stats",
  diffTarget: "Diff target",
  diffToolbar: "Diff toolbar",
  diffViewer: "Diff viewer",
  disableWordDiffs: "Disable word diffs",
  disableWordWrap: "Disable word wrap",
  enableWordDiffs: "Enable word diffs",
  enableWordWrap: "Enable word wrap",
  expandAllDiffs: "Expand all diffs",
  expandFile: "Expand {file}",
  expandUnchangedContext: "Expand unchanged context",
  files: "Files",
  filesViewedProgress: "{viewed} of {total} files viewed",
  filterAddedFiles: "Added",
  filterDeletedFiles: "Deleted",
  filterFiles: "Filter files",
  filterModifiedFiles: "Modified",
  filterRenamedFiles: "Renamed",
  findClose: "Close find",
  findInDiff: "Find in diff",
  findNextMatch: "Next match",
  findPreviousMatch: "Previous match",
  generatedFile: "Generated file",
  hideBackgrounds: "Hide backgrounds",
  hideFiles: "Hide files",
  hideFileSearch: "Hide file search",
  hideImports: "Hide imports",
  hideLineNumbers: "Hide line numbers",
  hideViewedFiles: "Hide viewed files",
  hideWhitespace: "Hide white space",
  indicatorStyle: "Indicator style",
  jumpToFile: "Jump to file",
  jumpToFileMore: "{count} more, type to filter",
  jumpToFileNoMatches: "No matching files",
  largeDiff: "Large diff",
  loadDiff: "Load diff",
  loadFullFiles: "Load full files",
  loadingDiff: "Loading diff...",
  loadingRenderer: "Loading renderer...",
  markNotViewed: "Mark as not viewed",
  markViewed: "Mark as viewed",
  modeChange: "Mode {old} → {new}",
  noFileDiffs: "No file diffs found in patch input.",
  noFilesMatchFilter: "No files match the filter.",
  none: "None",
  openSourceURL: "Open source URL",
  optionNeedsHostSupport: "Not available yet: cmux does not support this option",
  options: "Options",
  parsingDiff: "Parsing diff...",
  refresh: "Refresh",
  renderFailed: "Could not render this diff. Check the patch input and try again.",
  renderingDiff: "Rendering diff...",
  repoPath: "Repository path",
  richPreview: "Rich preview",
  showBackgrounds: "Show backgrounds",
  showFiles: "Show files",
  showFileSearch: "Show file search",
  showLineNumbers: "Show line numbers",
  showViewedFiles: "Show viewed files",
  sourceBranch: "Branch",
  sourceCommitted: "Committed",
  sourceLastTurn: "Last Turn",
  sourceNoCommits: "No commits to show",
  sourceStaged: "Staged",
  sourceUncommitted: "Uncommitted",
  sourceUnstaged: "Unstaged",
  switchToSplitDiff: "Switch to split diff",
  switchToUnifiedDiff: "Switch to unified diff",
  untitled: "Untitled",
  viewed: "Viewed",
  wordDiffs: "Word diffs",
  wordWrap: "Word wrap",
} as const;

export type DiffViewerLabelKey = keyof typeof DEFAULT_DIFF_VIEWER_LABELS;
export type DiffViewerLabelResolver = (key: DiffViewerLabelKey) => string;

/**
 * Japanese strings. The page has no string catalog from the host yet (cmux-next sends no
 * `payload.labels`), so the resolver picks this table when the app's preferred language
 * (`navigator.languages`, which WebKit derives from the app's localizations) is Japanese.
 * Host-supplied `payload.labels` still win over both tables.
 */
export const JAPANESE_DIFF_VIEWER_LABELS: Record<DiffViewerLabelKey, string> = {
  additions: "追加",
  bars: "バー",
  binaryFile: "バイナリファイル",
  branchBase: "比較元ブランチ",
  branchPickerBasePrefix: "比較元:",
  branchPickerComparing: "{head} を {base} と比較",
  branchPickerCurrent: "現在",
  branchPickerFilterPlaceholder: "ブランチを検索",
  branchPickerGenerateFailed: "差分を生成できませんでした。ブランチを選び直してください。",
  branchPickerGenerating: "{ref} との差分を生成中...",
  branchPickerGroupBranches: "ブランチ",
  branchPickerGroupRecent: "最近",
  branchPickerGroupRemotes: "リモート",
  branchPickerGroupSuggested: "候補",
  branchPickerGroupWorktrees: "ワークツリー",
  branchPickerLoadFailed: "ブランチを読み込めませんでした。",
  branchPickerLoading: "ブランチを読み込み中...",
  branchPickerMore: "ほか {count} 件。入力して絞り込み",
  branchPickerNoMatches: "一致するブランチがありません",
  branchPickerOpen: "比較元を変更",
  branchPickerUseRaw: "「{ref}」をそのまま使用",
  changedFiles: "変更されたファイル",
  changedSinceViewed: "確認後に変更あり",
  classic: "クラシック",
  clearFileFilter: "フィルタをクリア",
  collapseAllDiffs: "すべての差分を折りたたむ",
  collapseFile: "{file} を折りたたむ",
  collapseUnchangedContext: "変更のない行を折りたたむ",
  commit: "コミット",
  copiedGitApplyCommand: "git apply コマンドをコピーしました",
  copyFailedGitApplyCommand: "git apply コマンドをコピーできませんでした。",
  copyGitApplyCommand: "git apply コマンドをコピー",
  deletions: "削除",
  diffStats: "差分の統計",
  diffTarget: "差分の対象",
  diffToolbar: "差分ツールバー",
  diffViewer: "差分ビューア",
  disableWordDiffs: "単語単位の差分をオフ",
  disableWordWrap: "折り返しをオフ",
  enableWordDiffs: "単語単位の差分をオン",
  enableWordWrap: "折り返しをオン",
  expandAllDiffs: "すべての差分を展開",
  expandFile: "{file} を展開",
  expandUnchangedContext: "変更のない行を展開",
  files: "ファイル",
  filesViewedProgress: "{total} 件中 {viewed} 件を確認済み",
  filterAddedFiles: "追加",
  filterDeletedFiles: "削除",
  filterFiles: "ファイルを絞り込む",
  filterModifiedFiles: "変更",
  filterRenamedFiles: "名前変更",
  findClose: "検索を閉じる",
  findInDiff: "差分内を検索",
  findNextMatch: "次の一致",
  findPreviousMatch: "前の一致",
  generatedFile: "生成ファイル",
  hideBackgrounds: "背景色を隠す",
  hideFiles: "ファイルを隠す",
  hideFileSearch: "ファイル検索を隠す",
  hideImports: "インポートを隠す",
  hideLineNumbers: "行番号を隠す",
  hideViewedFiles: "確認済みファイルを隠す",
  hideWhitespace: "空白の変更を隠す",
  indicatorStyle: "インジケータの形式",
  jumpToFile: "ファイルへ移動",
  jumpToFileMore: "ほか {count} 件。入力して絞り込み",
  jumpToFileNoMatches: "一致するファイルがありません",
  largeDiff: "大きな差分",
  loadDiff: "差分を読み込む",
  loadFullFiles: "ファイル全体を読み込む",
  loadingDiff: "差分を読み込み中...",
  loadingRenderer: "レンダラを読み込み中...",
  markNotViewed: "未確認にする",
  markViewed: "確認済みにする",
  modeChange: "モード {old} → {new}",
  noFileDiffs: "パッチにファイルの差分がありません。",
  noFilesMatchFilter: "フィルタに一致するファイルがありません。",
  none: "なし",
  openSourceURL: "ソース URL を開く",
  optionNeedsHostSupport: "まだ使用できません: cmux がこのオプションに対応していません",
  options: "オプション",
  parsingDiff: "差分を解析中...",
  refresh: "更新",
  renderFailed: "この差分を表示できませんでした。パッチの入力を確認してもう一度お試しください。",
  renderingDiff: "差分を描画中...",
  repoPath: "リポジトリのパス",
  richPreview: "リッチプレビュー",
  showBackgrounds: "背景色を表示",
  showFiles: "ファイルを表示",
  showFileSearch: "ファイル検索を表示",
  showLineNumbers: "行番号を表示",
  showViewedFiles: "確認済みファイルを表示",
  sourceBranch: "ブランチ",
  sourceCommitted: "コミット済み",
  sourceLastTurn: "直前のターン",
  sourceNoCommits: "表示するコミットがありません",
  sourceStaged: "ステージ済み",
  sourceUncommitted: "未コミット",
  sourceUnstaged: "未ステージ",
  switchToSplitDiff: "分割表示に切り替え",
  switchToUnifiedDiff: "統合表示に切り替え",
  untitled: "無題",
  viewed: "確認済み",
  wordDiffs: "単語単位の差分",
  wordWrap: "折り返し",
};

export type DiffViewerLanguage = "en" | "ja";

/** The first of the app's preferred languages the viewer has strings for, else English. */
export function diffViewerLanguage(
  languages: readonly string[] = globalThis.navigator?.languages ?? [],
): DiffViewerLanguage {
  for (const language of languages) {
    const base = language.toLowerCase().split("-")[0];
    if (base === "ja") return "ja";
    if (base === "en") return "en";
  }
  return "en";
}

/** The shipped label table for `language`. */
export function diffViewerLabelsFor(language: DiffViewerLanguage): Record<DiffViewerLabelKey, string> {
  return language === "ja" ? JAPANESE_DIFF_VIEWER_LABELS : DEFAULT_DIFF_VIEWER_LABELS;
}

type LabelResolverOptions = {
  assertMissing?: boolean;
  /** Overrides the language read from `navigator.languages` (tests). */
  language?: DiffViewerLanguage;
};

export function shouldAssertMissingLabels(): boolean {
  return Boolean(import.meta.env?.DEV);
}

export function createDiffViewerLabelResolver(
  labels: Record<string, string> | undefined,
  options: LabelResolverOptions = {},
): DiffViewerLabelResolver {
  const missingKeys = new Set<DiffViewerLabelKey>();
  const language = options.language ?? diffViewerLanguage();
  return (key) => {
    const localizedValue = labels?.[key];
    if (typeof localizedValue === "string" && localizedValue.trim() !== "") {
      return localizedValue;
    }
    if (language === "ja") {
      return JAPANESE_DIFF_VIEWER_LABELS[key];
    }

    if (options.assertMissing && !missingKeys.has(key)) {
      missingKeys.add(key);
      throw new Error(`Missing cmux diff viewer label: ${key}`);
    }

    return DEFAULT_DIFF_VIEWER_LABELS[key];
  };
}
