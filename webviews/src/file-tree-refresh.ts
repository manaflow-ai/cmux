export type FileTreeRefreshSource = {
  pathCount?: number;
  paths?: readonly string[];
  previousSource?: FileTreeRefreshSource;
};

export type FileTreeRefreshPlan =
  | {
      addedPaths: string[];
      requiresFullGitStatus: boolean;
      sourceFollowsPrevious: boolean;
      kind: "append";
    }
  | {
      kind: "reset";
    };

export type FileTreeGitStatusSource = {
  gitStatus: readonly unknown[];
  gitStatusPatch?: unknown;
  statsChanged?: boolean;
};

export type PierreFileTreeGitStatusModel = {
  applyGitStatusPatch?: (patch: unknown) => void;
  setGitStatus: (gitStatus: readonly unknown[]) => void;
};

export type PierreFileTreeSelectionModel = {
  getItem?: (path: string) => { select: () => void } | null;
  scrollToPath: (path: string, options: { focus: boolean; offset: "nearest" }) => void;
  selectOnlyPath?: (path: string) => void;
};

export function planPierreFileTreeRefresh(
  previousSource: FileTreeRefreshSource | null | undefined,
  source: FileTreeRefreshSource,
  paths: readonly string[],
): FileTreeRefreshPlan {
  if (!previousSource) {
    return { kind: "reset" };
  }

  const previousPathCount = previousSource.pathCount ?? previousSource.paths?.length ?? 0;
  const sourcePathCount = source.pathCount ?? paths.length;
  const sourceFollowsPrevious = source.previousSource === previousSource;
  const canAppend = sourceFollowsPrevious || isPathPrefix(previousSource, source);

  if (!canAppend || sourcePathCount < previousPathCount) {
    return { kind: "reset" };
  }

  return {
    addedPaths: paths.slice(previousPathCount, sourcePathCount),
    requiresFullGitStatus: !sourceFollowsPrevious,
    sourceFollowsPrevious,
    kind: "append",
  };
}

export function applyPierreFileTreeGitStatus(
  model: PierreFileTreeGitStatusModel,
  source: FileTreeGitStatusSource,
  resetTree: boolean,
): void {
  if (resetTree) {
    model.setGitStatus(source.gitStatus);
    return;
  }
  if (source.gitStatusPatch && typeof model.applyGitStatusPatch === "function") {
    model.applyGitStatusPatch(source.gitStatusPatch);
    return;
  }
  if (source.statsChanged === true || source.gitStatusPatch) {
    model.setGitStatus(source.gitStatus);
  }
}

export function selectPierreFileTreePath(model: PierreFileTreeSelectionModel, selectedPath: string): void {
  if (!selectedPath) {
    return;
  }
  if (typeof model.selectOnlyPath === "function") {
    model.selectOnlyPath(selectedPath);
  } else {
    model.getItem?.(selectedPath)?.select();
  }
  model.scrollToPath(selectedPath, { focus: false, offset: "nearest" });
}

function isPathPrefix(previousSource: FileTreeRefreshSource, nextSource: FileTreeRefreshSource): boolean {
  const previousPaths = previousSource.paths;
  const nextPaths = nextSource.paths;
  const previousCount = previousSource.pathCount ?? previousPaths?.length ?? 0;
  const nextCount = nextSource.pathCount ?? nextPaths?.length ?? 0;
  if (!Array.isArray(previousPaths) || !Array.isArray(nextPaths) || previousCount > nextCount) {
    return false;
  }
  for (let index = 0; index < previousCount; index += 1) {
    if (previousPaths[index] !== nextPaths[index]) {
      return false;
    }
  }
  return true;
}
