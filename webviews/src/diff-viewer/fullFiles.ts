// Load full files ("..." menu, Codex parity): a git diff's patch has only a few lines of context
// around each hunk, so Pierre can not show the rest of a file. With the option on, the viewer asks
// the host for each shown file's two sides (`fileContents`, Native/DiffSidecar file_contents.rs)
// and parses the file's own patch again with them: the hunks stay git's (hunk Stage and Revert
// still match the host's), and the unchanged lines between them can expand. The option off parses
// the patch alone again.
import { processFile } from "@pierre/diffs";
import { useCallback, useEffect, useRef } from "react";
import type { DiffTransport } from "../diff/transport";
import type { DiffItem } from "../diff-stream";
import { fileContentsAvailable, loadFileContents, type ActiveDiffSession, type FileContents } from "./session";
import type { AppAction } from "./state";
import { resolveDiffItemLanguage } from "./item-languages";
import { PATCH_TEXT_KEY } from "../kept-patch-text";

/** Whether Load full files can apply to `source` (session.ts `fileContentsAvailable`). */
export const fullFilesAvailable = fileContentsAvailable;

/** Set on a diff parsed with both sides. */
export const FULL_FILES_KEY = "cmuxFullFiles";
/** The partial parse's base cache key, kept on a full parse so the option off gets it back. */
const PARTIAL_BASE_KEY = "cmuxPartialBaseCacheKey";
/** Requests at a time. */
const CONCURRENT_READS = 4;

type ProcessFile = (
  patchText: string,
  options: {
    cacheKey: string;
    isGitDiff: boolean;
    oldFile?: { name: string; contents: string };
    newFile?: { name: string; contents: string };
  },
) => any;

/** The paths to read for a diff that has lines to expand; null when it has none to load. */
export function fullFileRequest(fileDiff: any): { path: string; previousPath?: string } | null {
  if (
    fileDiff == null ||
    typeof fileDiff[PATCH_TEXT_KEY] !== "string" ||
    fileDiff[FULL_FILES_KEY] === true ||
    !Array.isArray(fileDiff.hunks) ||
    fileDiff.hunks.length === 0 ||
    // An added or deleted file is all in its patch; a pure rename or binary file has no lines.
    (fileDiff.type !== "change" && fileDiff.type !== "rename-changed") ||
    typeof fileDiff.name !== "string"
  ) {
    return null;
  }
  const previous = typeof fileDiff.prevName === "string" && fileDiff.prevName !== fileDiff.name;
  return previous ? { path: fileDiff.name, previousPath: fileDiff.prevName } : { path: fileDiff.name };
}

/** The fields a parse sets; the rest of a diff (the stream's and viewer's marks) carries over. */
function identityOf(fileDiff: any): Record<string, unknown> {
  const {
    hunks: _hunks,
    additionLines: _additionLines,
    deletionLines: _deletionLines,
    isPartial: _isPartial,
    splitLineCount: _splitLineCount,
    unifiedLineCount: _unifiedLineCount,
    cacheKey: _cacheKey,
    [FULL_FILES_KEY]: _full,
    ...identity
  } = fileDiff;
  return identity;
}

function partialBaseKey(fileDiff: any): string {
  return fileDiff[PARTIAL_BASE_KEY] ?? fileDiff.cmuxBaseCacheKey ?? fileDiff.cacheKey;
}

function sameLines(a: readonly string[], aStart: number, b: readonly string[], bStart: number, count: number) {
  if (aStart + count > a.length || bStart + count > b.length) return false;
  for (let index = 0; index < count; index += 1) {
    if (a[aStart + index] !== b[bStart + index]) return false;
  }
  return true;
}

/**
 * Whether a full parse shows the patch's own changes: each hunk's lines are the patch's, and each
 * run of lines between hunks is the same on both sides. The sides are read when the option turns
 * on, so a file changed after the diff loaded fails this; and so does a patch Hide imports took
 * hunks out of, whose dropped changes would show as unchanged lines.
 */
function sidesMatchPatch(partial: any, full: any): boolean {
  const hunks: any[] = full.hunks;
  const shown: any[] = partial.hunks;
  if (!Array.isArray(hunks) || !Array.isArray(shown) || hunks.length !== shown.length) return false;
  const old: string[] = full.deletionLines;
  const next: string[] = full.additionLines;
  let oldEnd = 0;
  let newEnd = 0;
  for (let index = 0; index < hunks.length; index += 1) {
    const hunk = hunks[index];
    const patch = shown[index];
    const gap = hunk.deletionLineIndex - oldEnd;
    if (gap !== hunk.additionLineIndex - newEnd || !sameLines(old, oldEnd, next, newEnd, gap)) return false;
    if (
      !sameLines(old, hunk.deletionLineIndex, partial.deletionLines, patch.deletionLineIndex, hunk.deletionCount) ||
      !sameLines(next, hunk.additionLineIndex, partial.additionLines, patch.additionLineIndex, hunk.additionCount)
    ) {
      return false;
    }
    oldEnd = hunk.deletionLineIndex + hunk.deletionCount;
    newEnd = hunk.additionLineIndex + hunk.additionCount;
  }
  const tail = old.length - oldEnd;
  return tail === next.length - newEnd && sameLines(old, oldEnd, next, newEnd, tail);
}

/**
 * `fileDiff` parsed again with its two sides, so its unchanged lines can expand; null when the
 * answer has no use (a side is missing or too large, the parse fails, or the sides do not match
 * the patch: `sidesMatchPatch`). Its cache key is new: Pierre keeps a highlight by key, and the
 * partial parse's has fewer lines.
 */
export function withFullFiles(fileDiff: any, sides: FileContents, process: ProcessFile): any | null {
  const text = fileDiff?.[PATCH_TEXT_KEY];
  if (
    typeof text !== "string" ||
    sides.tooLarge === true ||
    sides.old?.encoding !== "text" ||
    sides.new?.encoding !== "text"
  ) {
    return null;
  }
  const base = partialBaseKey(fileDiff);
  const cacheKey = `${base}:full`;
  let parsed: any;
  let partial: any;
  try {
    parsed = process(text, {
      cacheKey,
      isGitDiff: true,
      oldFile: { name: fileDiff.prevName ?? fileDiff.name, contents: sides.old.contents },
      newFile: { name: fileDiff.name, contents: sides.new.contents },
    });
    partial = process(text, { cacheKey: base, isGitDiff: true });
  } catch {
    return null;
  }
  if (parsed == null || typeof parsed !== "object" || parsed.isPartial !== false) {
    return null;
  }
  if (partial == null || typeof partial !== "object" || !sidesMatchPatch(partial, parsed)) {
    return null;
  }
  const next = {
    ...parsed,
    ...identityOf(fileDiff),
    hunks: parsed.hunks,
    additionLines: parsed.additionLines,
    deletionLines: parsed.deletionLines,
    isPartial: false,
    cacheKey,
    cmuxBaseCacheKey: cacheKey,
    [PARTIAL_BASE_KEY]: base,
    [FULL_FILES_KEY]: true,
  };
  return next;
}

/** A full parse back to the patch alone (the option off); null for a diff that is not one. */
export function withoutFullFiles(fileDiff: any, process: ProcessFile): any | null {
  const text = fileDiff?.[PATCH_TEXT_KEY];
  if (fileDiff?.[FULL_FILES_KEY] !== true || typeof text !== "string") {
    return null;
  }
  const base = partialBaseKey(fileDiff);
  let parsed: any;
  try {
    parsed = process(text, { cacheKey: base, isGitDiff: true });
  } catch {
    return null;
  }
  if (parsed == null || typeof parsed !== "object") {
    return null;
  }
  const { [PARTIAL_BASE_KEY]: _base, ...identity } = identityOf(fileDiff);
  return {
    ...parsed,
    ...identity,
    hunks: parsed.hunks,
    additionLines: parsed.additionLines,
    deletionLines: parsed.deletionLines,
    isPartial: parsed.isPartial,
    cacheKey: base,
    cmuxBaseCacheKey: base,
  };
}

export type ReadFileSides = (request: {
  path: string;
  previousPath?: string;
  /** Base64 for bytes (Rich preview's images); text by default. */
  encoding?: "text" | "base64";
}) => Promise<FileContents>;

/** Reads a file's sides in the shown session (session.ts `loadFileContents`); null with no transport. */
export function useFileSidesReader(
  transport: DiffTransport | null,
  activeSession: React.MutableRefObject<ActiveDiffSession | null>,
): ReadFileSides | null {
  const read = useCallback<ReadFileSides>(
    (request) => {
      const session = activeSession.current;
      if (!transport || !session) return Promise.reject(new Error("No diff session is open"));
      return loadFileContents(transport, session, request);
    },
    [activeSession, transport],
  );
  return transport ? read : null;
}

/**
 * Loads both sides of each shown file while `enabled` (Load full files on, and the host can),
 * `CONCURRENT_READS` at a time, and swaps each item for its full parse. With `enabled` off, every
 * full parse goes back to the patch alone. A file whose sides can not be used stays as it is and
 * is not asked again for this session (`sessionKey`).
 */
export function useFullFiles({
  items,
  enabled,
  sessionKey,
  read,
  process = processFile,
  dispatch,
}: {
  items: readonly DiffItem[];
  enabled: boolean;
  /** The shown session: a new one asks again. */
  sessionKey: string | null;
  read: ReadFileSides | null;
  /** Pierre's parse; tests pass their own. */
  process?: ProcessFile;
  dispatch: React.Dispatch<AppAction>;
}) {
  const asked = useRef<{ session: string | null; ids: Set<string> }>({ session: null, ids: new Set() });
  const running = useRef(0);
  // The newest effect's queue: a read that ends starts the next one from it, also a read an
  // earlier effect started.
  const pump = useRef<() => void>(() => {});
  const latest = useRef({ enabled, sessionKey, read });
  latest.current = { enabled, sessionKey, read };
  useEffect(() => {
    if (asked.current.session !== sessionKey) {
      asked.current = { session: sessionKey, ids: new Set() };
    }
    if (!enabled || !read) {
      pump.current = () => {};
      for (const item of items) {
        const fileDiff = withoutFullFiles(item.fileDiff, process);
        if (fileDiff == null) continue;
        resolveDiffItemLanguage({ ...item, fileDiff } as DiffItem);
        dispatch({ type: "hydrate-item", itemId: item.id, fileDiff, expectedFileDiff: item.fileDiff });
      }
      asked.current.ids.clear();
      return;
    }
    const queue = items.filter(
      (item) => !item.collapsed && !asked.current.ids.has(item.id) && fullFileRequest(item.fileDiff) != null,
    );
    const next = () => {
      while (running.current < CONCURRENT_READS && queue.length > 0) {
        const item = queue.shift()!;
        const request = fullFileRequest(item.fileDiff);
        if (request == null || asked.current.ids.has(item.id)) continue;
        asked.current.ids.add(item.id);
        running.current += 1;
        const session = sessionKey;
        read(request)
          .then(
            (sides) => {
              const now = latest.current;
              if (!now.enabled || now.sessionKey !== session) return;
              const fileDiff = withFullFiles(item.fileDiff, sides, process);
              if (fileDiff == null) return;
              resolveDiffItemLanguage({ ...item, fileDiff } as DiffItem);
              dispatch({ type: "hydrate-item", itemId: item.id, fileDiff, expectedFileDiff: item.fileDiff });
            },
            () => {},
          )
          .finally(() => {
            running.current -= 1;
            pump.current();
          });
      }
    };
    pump.current = next;
    next();
  }, [dispatch, enabled, items, process, read, sessionKey]);
}
