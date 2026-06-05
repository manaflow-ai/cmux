export type FileTreeRefreshSource = {
  pathCount?: number;
  paths?: readonly string[];
  previousSource?: FileTreeRefreshSource;
};

export type FileTreeRefreshPlan =
  | {
      addedPaths: string[];
      kind: "append";
    }
  | {
      kind: "reset";
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
  const canAppend = source.previousSource === previousSource || isPathPrefix(previousSource, source);

  if (!canAppend || sourcePathCount < previousPathCount) {
    return { kind: "reset" };
  }

  return {
    addedPaths: paths.slice(previousPathCount, sourcePathCount),
    kind: "append",
  };
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
