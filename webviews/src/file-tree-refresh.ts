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

type PathFolder = { entries: (PathFolder | string)[]; folders: Map<string, PathFolder> };

/**
 * `paths` in folder order: each folder's files and subfolders together, in the order each first
 * appears, so the list stays as close to the diff's order as a tree allows. The tree's presorted
 * input (`preparePresortedFileTreeInput`) needs this: it starts a folder anew wherever its path
 * shows up again after another folder, so the diff's order (tracked edits, then new files) gave
 * `src/server/` twice, and the tree could not find the files under either copy.
 * A row the tree appends later (`model.batch` add) lands in the same place.
 */
export function folderOrderedPaths(paths: readonly string[]): string[] {
  const root: PathFolder = { entries: [], folders: new Map() };
  for (const path of paths) {
    let folder = root;
    let start = 0;
    for (let slash = path.indexOf("/"); slash >= 0; slash = path.indexOf("/", start)) {
      const name = path.slice(start, slash);
      start = slash + 1;
      let next = folder.folders.get(name);
      if (next == null) {
        next = { entries: [], folders: new Map() };
        folder.folders.set(name, next);
        folder.entries.push(next);
      }
      folder = next;
    }
    folder.entries.push(path);
  }
  const ordered: string[] = [];
  const visit = (folder: PathFolder) => {
    for (const entry of folder.entries) {
      if (typeof entry === "string") ordered.push(entry);
      else visit(entry);
    }
  };
  visit(root);
  return ordered;
}

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
  selectOnlyPierreFileTreePath(model, selectedPath);
  // The tree's focused row is model state (DOM focus stays where it is): the
  // keyboard starts from the file in view, and the indent guide under its
  // folder shows as in the classic list.
  model.focusPath?.(selectedPath);
  model.scrollToPath(selectedPath, { focus: false, offset: "nearest" });
}

/**
 * Makes `selectedPath` the tree's only selected row (none when it is empty), without moving the
 * tree's focus or scrolling it. A folder row's click selects the folder as it toggles it; the
 * diff tab puts the highlight back on the file the viewer shows, so a folder never keeps one.
 */
export function selectOnlyPierreFileTreePath(model: PierreFileTreeSelectionModel, selectedPath: string): void {
  if (selectedPath && typeof model.selectOnlyPath === "function") {
    model.selectOnlyPath(selectedPath);
    return;
  }
  // An item handle's select() adds to the selection: drop the rows selected before, so one row
  // stays highlighted.
  for (const path of model.getSelectedPaths?.() ?? []) {
    if (path !== selectedPath) {
      model.getItem?.(path)?.deselect?.();
    }
  }
  if (selectedPath) {
    model.getItem?.(selectedPath)?.select();
  }
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
