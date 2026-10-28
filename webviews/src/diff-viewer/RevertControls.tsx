// The diff tab's Revert and hunk Stage (D3, the Codex Review pane's): a file header's Revert, a
// hunk's Stage and Revert on hover, and the floating Stage all / Revert all bar at the bottom of
// the diff. The host asks before a file loses its changes (a native sheet); a hunk reverts at once
// and the bar offers Undo, which the host can always do (it keeps the hunk's patch).
import { useImperativeHandle, useRef, useState, type Ref } from "react";
import type { ChangesSource } from "../agent-session/acpmux/changes/model";
import type { DiffSource } from "../diff/generated/protocol";
import { fileName, type DiffItem } from "../diff-stream";
import { Icon } from "../icons";
import type { DiffViewerLabelKey, DiffViewerLabelResolver } from "../labels";
import { isPageError } from "../pages/shared/pageClient";
import {
  allPaths,
  chunked,
  filePaths,
  hunkAnchorRow,
  hunkIndexAt,
  hunkLines,
  hunksActionable,
  hunkStageModeOf,
  MAX_REQUEST_PATHS,
  renameSources,
  revertScopeOf,
  type DiffRevertSource,
} from "./revert";
import { useSyncedRef } from "./useSyncedRef";

/** Host refusals whose own message (already in the person's language) says what to do. */
const HOST_REASONS = new Set(["git.failed", "git.busy", "transport.gesture_required"]);

/** The page's message for a failed write: the host's own reason, else `fallback`; nothing when
 * the person declined the host's sheet. */
export function revertFailureMessage(error: unknown, fallback: string): string | undefined {
  if (isPageError(error) && error.code === "cmux.page.cancelled") return undefined;
  if (isPageError(error) && HOST_REASONS.has(error.code) && error.message.trim() !== "") return error.message;
  return fallback;
}

/** How long a failure stays in the bar, in ms (a one-shot timer; the next write clears it too). */
export const REVERT_NOTICE_MS = 8000;

export type DiffRevert = {
  /** A file header's Revert; undefined where the scope has no work-tree changes. */
  revertFile?: { label: string; run: (path: string, previousPath: string | null) => void };
  /** The hunk hover's buttons for an item, or undefined for a file whose hunks go whole. */
  hunkActions: (item: DiffItem) => HunkActions | undefined;
  stageAll?: () => void;
  revertAll?: () => void;
  /** Set while hunks reverted in this scope can come back: Undo puts the newest back. */
  undo?: () => void;
  /** Why the last write failed, shown in the bar until the next write. */
  notice?: string;
  busy: boolean;
};

export type HunkActions = {
  /** `unstage`: the Staged scope's Unstage, drawn as a minus beside Revert's arrow. */
  stage?: { label: string; run: (index: number) => void; unstage?: boolean };
  revert?: { label: string; run: (index: number) => void };
};

/** Which diff a source shows, so Undo stays with the scope and repository it came from. */
function sourceKey(source: DiffSource | null): string {
  if (!source) return "";
  return source.kind === "patch"
    ? `patch:${source.path}`
    : `${source.kind}:${source.repoRoot}:${source.kind === "branch" ? (source.baseRef ?? "") : ""}`;
}

/**
 * The viewer's Revert and hunk Stage over the host's ops. `stage` is the changes view's file
 * Stage (diff-viewer/git.ts), which Stage all reuses. Each write refreshes the diff when it ends,
 * also after a failure (a file revert may have done part of its work); a declined sheet changes
 * nothing and refreshes nothing. One write runs at a time. Stage all and Revert all wait for the
 * whole diff (`complete`), so they never act on part of it.
 */
export function useDiffRevert({
  source,
  stage,
  shown,
  items,
  complete,
  label,
  refresh,
  hidesChanges = false,
}: {
  source: DiffRevertSource | undefined;
  stage: ChangesSource["stage"];
  shown: DiffSource | null;
  items: readonly DiffItem[];
  /** Every file of the diff has arrived. */
  complete: boolean;
  label: DiffViewerLabelResolver;
  refresh: () => void;
  /**
   * The diff leaves some changes out (Hide white space, Hide imports). A file revert, Revert all
   * and Stage all would act on those too, and a file that only has hidden changes is not listed,
   * so they are not offered; a hunk's Stage and Revert act on exactly the hunk shown.
   */
  hidesChanges?: boolean;
}): DiffRevert {
  const [busy, setBusy] = useState(false);
  const [undos, setUndos] = useState<{ key: string; tokens: string[] }>({ key: "", tokens: [] });
  const [notice, setNotice] = useState<string>();
  const running = useRef(false);
  const latest = useSyncedRef({ refresh, label });
  // Unstaged and Uncommitted show the work tree: Stage all works there, and Revert too when the
  // host serves it.
  const workTree = source ? revertScopeOf(shown) : undefined;
  const reverter = source?.revert;
  const scope = reverter ? workTree : undefined;
  const stageMode = source?.stageHunk ? hunkStageModeOf(shown) : undefined;
  const key = sourceKey(shown);
  const pathOf = (item: DiffItem) => fileName(item.fileDiff ?? {}, label("untitled"));

  /** Runs one write, then refreshes; a failure says why in the bar. */
  const write = (work: () => Promise<unknown>, failed: DiffViewerLabelKey) => {
    if (running.current) return;
    running.current = true;
    setBusy(true);
    setNotice(undefined);
    work()
      .then(
        () => latest.current.refresh(),
        (error: unknown) => {
          const message = revertFailureMessage(error, latest.current.label(failed));
          if (!message) return;
          setNotice(message);
          setTimeout(() => setNotice((current) => (current === message ? undefined : current)), REVERT_NOTICE_MS);
          latest.current.refresh();
        },
      )
      .finally(() => {
        running.current = false;
        setBusy(false);
      });
  };

  const hunkActions = (item: DiffItem): HunkActions | undefined => {
    const fileDiff = item.fileDiff;
    if (!source || !hunksActionable(fileDiff, workTree) || (!scope && !stageMode)) return undefined;
    const paths = filePaths(pathOf(item), typeof fileDiff.prevName === "string" ? fileDiff.prevName : null);
    const lines = (index: number) => hunkLines(fileDiff, index);
    return {
      ...(stageMode && source.stageHunk
        ? {
            stage: {
              label: label(stageMode === "unstage" ? "hunkUnstage" : "hunkStage"),
              unstage: stageMode === "unstage",
              run: (index: number) => {
                const hunk = lines(index);
                if (hunk) write(() => source.stageHunk!(paths, hunk, stageMode === "unstage"), "stageFailed");
              },
            },
          }
        : {}),
      ...(reverter && scope
        ? {
            revert: {
              label: label("hunkRevert"),
              run: (index: number) => {
                const hunk = lines(index);
                if (!hunk) return;
                write(
                  () =>
                    reverter.discardHunk(paths, hunk, scope).then((token) => {
                      if (!token) return;
                      setUndos((current) => ({
                        key,
                        tokens: [...(current.key === key ? current.tokens : []), token],
                      }));
                    }),
                  "revertFailed",
                );
              },
            },
          }
        : {}),
    };
  };

  const stagePaths = allPaths(items, pathOf, false);
  const revertPaths = allPaths(items, pathOf, true);
  const whole = complete && items.length > 0;
  const tokens = scope && undos.key === key ? undos.tokens : [];
  const newest = tokens[tokens.length - 1];
  return {
    busy,
    hunkActions,
    ...(notice ? { notice } : {}),
    ...(reverter && scope && !hidesChanges
      ? {
          revertFile: {
            label: label("revertFile"),
            run: (path: string, previousPath: string | null) =>
              write(
                () =>
                  reverter.discard(
                    filePaths(path, previousPath),
                    scope,
                    previousPath && previousPath !== path ? [previousPath] : [],
                  ),
                "revertFailed",
              ),
          },
        }
      : {}),
    ...(source && workTree && stage && whole && !hidesChanges && stagePaths.length > 0
      ? {
          stageAll: () =>
            write(async () => {
              for (const run of chunked(stagePaths, MAX_REQUEST_PATHS)) await stage(run, false);
            }, "stageFailed"),
        }
      : {}),
    // One request, so the host asks once and lists every file it reverts.
    ...(reverter && scope && whole && !hidesChanges && revertPaths.length > 0 && revertPaths.length <= MAX_REQUEST_PATHS
      ? {
          revertAll: () =>
            write(() => reverter.discard(revertPaths, scope, renameSources(items, pathOf)), "revertFailed"),
        }
      : {}),
    ...(reverter && newest
      ? {
          // The host spends a token once it tries it, so an Undo that fails there (`git.failed`)
          // drops it too: the error shows once, and Undo moves to the hunk before. A busy host
          // or a missing gesture spends nothing.
          undo: () => {
            const spend = () =>
              setUndos((current) => ({
                key: current.key,
                tokens: current.tokens.filter((each) => each !== newest),
              }));
            write(
              () =>
                reverter.undo(newest).then(spend, (error: unknown) => {
                  if (isPageError(error) && error.code === "git.failed") spend();
                  throw error;
                }),
              "revertFailed",
            );
          },
        }
      : {}),
  };
}

/**
 * Pierre's line callbacks for the hunk hover. CodeView calls each shared callback with its own
 * arguments, then the item's record (`{type, item, instance, ...}`), not the item itself.
 */
export function hunkHoverCallbacks(hover: { current: HunkHoverHandle | null }) {
  return {
    onLineEnter: (line: HoveredLine, record: { item: DiffItem }) => hover.current?.enter(line, record.item),
    onLineLeave: () => hover.current?.leave(),
  };
}

/** What the viewer tells the hover about a line the pointer entered (Pierre's onLineEnter). */
export type HoveredLine = {
  lineNumber: number;
  annotationSide: "additions" | "deletions";
  lineType: string;
  lineElement: HTMLElement;
};

export type HunkHoverHandle = {
  enter: (line: HoveredLine, item: DiffItem) => void;
  leave: () => void;
  hide: () => void;
};

/** Room under the diff's last line for the floating bar (its height and its bottom gap), in px. */
export const DIFF_BULK_BAR_ROOM = 56;

/** How long the hover stays after the pointer leaves the hunk's line, so it can reach the buttons. */
export const HUNK_HOVER_GRACE_MS = 150;

/**
 * A hunk's Revert and Stage, two icon buttons at the right end of the hunk's first changed line
 * (the Codex Review pane's), shown while the pointer is on any line of the hunk: they stay in
 * one place per hunk and do not follow the pointer from line to line. The viewer passes Pierre's
 * line events through `handle`; the hover keeps its own state, so moving across lines repaints
 * only it.
 */
export function HunkHoverActions({
  handle,
  viewer,
  actionsFor,
  busy,
  label,
}: {
  handle: Ref<HunkHoverHandle>;
  viewer: React.RefObject<HTMLElement | null>;
  actionsFor: (item: DiffItem) => HunkActions | undefined;
  busy: boolean;
  label: DiffViewerLabelResolver;
}) {
  const [hover, setHover] = useState<{ item: DiffItem; index: number; top: number }>();
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  // The pointer is on the pill. The viewer still reports each move there as leaving the line, and
  // a hide then would flicker the pill (hidden, the line under it shows it again): only leaving
  // the pill hides it.
  const onPill = useRef(false);
  const latest = useSyncedRef(actionsFor);
  const cancelHide = () => {
    if (timer.current !== undefined) clearTimeout(timer.current);
    timer.current = undefined;
  };
  const hide = () => {
    cancelHide();
    onPill.current = false;
    setHover(undefined);
  };
  const scheduleHide = () => {
    cancelHide();
    timer.current = setTimeout(hide, HUNK_HOVER_GRACE_MS);
  };
  const leaveLine = () => {
    if (!onPill.current) scheduleHide();
  };
  useImperativeHandle(handle, () => ({
    enter: (line, item) => {
      const index =
        line.lineType === "context-expanded" || !item.fileDiff?.hunks
          ? undefined
          : hunkIndexAt(item.fileDiff, line.annotationSide, line.lineNumber);
      const box = viewer.current?.getBoundingClientRect();
      if (index === undefined || !box || !latest.current(item)) return leaveLine();
      cancelHide();
      // The hunk's first changed row, or the hovered one when that row is scrolled out of view.
      const row = (hunkAnchorRow(line.lineElement, item.fileDiff, index) ?? line.lineElement).getBoundingClientRect();
      const top = Math.round(row.top - box.top + row.height / 2);
      setHover((current) =>
        current?.item === item && current.index === index && current.top === top ? current : { item, index, top },
      );
    },
    leave: leaveLine,
    hide,
  }));
  const actions = hover ? actionsFor(hover.item) : undefined;
  if (!hover || !actions || (!actions.stage && !actions.revert)) return null;
  const press = (run: (index: number) => void) => {
    run(hover.index);
    hide();
  };
  return (
    <div
      className="diff-hunk-actions"
      role="toolbar"
      aria-label={label("hunkActions")}
      style={{ top: hover.top }}
      onPointerEnter={() => {
        onPill.current = true;
        cancelHide();
      }}
      onPointerLeave={() => {
        onPill.current = false;
        scheduleHide();
      }}
    >
      {actions.revert ? (
        <button
          type="button"
          className="diff-hunk-action"
          data-kind="revert"
          aria-label={actions.revert.label}
          title={actions.revert.label}
          disabled={busy}
          onClick={() => press(actions.revert!.run)}
        >
          <span className="diff-hunk-action-icon" aria-hidden="true">
            <Icon name="revert" />
          </span>
        </button>
      ) : null}
      {actions.stage ? (
        <button
          type="button"
          className="diff-hunk-action"
          aria-label={actions.stage.label}
          title={actions.stage.label}
          disabled={busy}
          onClick={() => press(actions.stage!.run)}
        >
          <span className="diff-hunk-action-icon" aria-hidden="true">
            <Icon name={actions.stage.unstage ? "minus" : "plus"} />
          </span>
        </button>
      ) : null}
    </div>
  );
}

/**
 * Stage all and Revert all, floating at the bottom center of the diff (the Codex Review pane's
 * bar), Undo after a hunk revert, and why the last write failed (a status the reader sees and a
 * screen reader announces). Hidden when there is none of them.
 */
export function DiffBulkBar({
  revert,
  label,
  showActions = true,
}: {
  revert: DiffRevert;
  label: DiffViewerLabelResolver;
  /** Stage all and Revert all (`diff.showBulkActions`); off, the bar shows only Undo and notices. */
  showActions?: boolean;
}) {
  const stageAll = showActions ? revert.stageAll : undefined;
  const revertAll = showActions ? revert.revertAll : undefined;
  if (!stageAll && !revertAll && !revert.undo && !revert.notice) return null;
  const actions = Boolean(stageAll || revertAll);
  return (
    <div className="diff-bulk-bar" role="toolbar" aria-label={label("bulkActions")}>
      {revert.notice ? (
        <output className="diff-bulk-note" data-kind="error">
          {revert.notice}
        </output>
      ) : revert.undo ? (
        <output className="diff-bulk-note">{label("hunkReverted")}</output>
      ) : null}
      {revert.undo ? (
        <button type="button" className="diff-bulk-action" disabled={revert.busy} onClick={revert.undo}>
          {label("undo")}
        </button>
      ) : null}
      {(revert.notice || revert.undo) && actions ? <span className="diff-bulk-divider" aria-hidden="true" /> : null}
      {revertAll ? (
        <button
          type="button"
          className="diff-bulk-action"
          data-kind="revert"
          disabled={revert.busy}
          onClick={revertAll}
        >
          {label("revertAll")}
        </button>
      ) : null}
      {stageAll ? (
        <button type="button" className="diff-bulk-action" disabled={revert.busy} onClick={stageAll}>
          {label("stageAll")}
        </button>
      ) : null}
    </div>
  );
}
