export type FileTreeRefreshSource = {
  pathCount?: number;
  paths?: readonly string[];
  previousRevision?: number;
  previousSource?: FileTreeRefreshSource;
  revision?: number;
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
  getItem?: (path: string) => { select: () => void; deselect?: () => void } | null;
  getSelectedPaths?: () => readonly string[];
  focusPath?: (path: string) => void;
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
  const sourceFollowsPrevious =
    source.previousSource === previousSource ||
    (previousSource.revision != null && source.previousRevision === previousSource.revision);
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
    // An item handle's select() adds to the selection: drop the row the
    // viewer followed before, so one row stays highlighted.
    for (const path of model.getSelectedPaths?.() ?? []) {
      if (path !== selectedPath) {
        model.getItem?.(path)?.deselect?.();
      }
    }
    model.getItem?.(selectedPath)?.select();
  }
  // The tree's focused row is model state (DOM focus stays where it is): the
  // keyboard starts from the file in view, and the indent guide under its
  // folder shows as in the classic list.
  model.focusPath?.(selectedPath);
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
