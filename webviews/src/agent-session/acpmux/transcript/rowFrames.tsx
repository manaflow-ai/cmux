import React from "react";
import { rowMark, MARK_PROMPT, MARK_INDICATOR, ownMessagesJoin } from "../transcriptGrid";
import { LoadFadeWindow } from "../../shared/loadFade";
import {
  type AcpmuxRow,
  isLineRow,
  isLiveStep,
  prevDrawnRow,
  rowFrameKey,
  nextDrawnRow,
  opensBackgroundTurn,
  isBeforeFooter,
  keepsReplyRoom,
  statusEdge,
  isLastFooter,
  isContinuationFooter,
  hasReplyActions,
  rowPropsWindow,
} from "../model";
import { RowFrameCache } from "../conversation/rowFrameCache";
import { type ReferenceScope } from "../conversation/bareReferences";
import { BACKGROUND_TURN } from "../conversation/backgroundTurns";
import { isEditRow } from "../turnChanges/sessionRows";
import { THINKING, WORKED } from "../conversation/turns";
import { type Folds } from "../conversation/viewFolds";
import { SUBAGENT_DONE, SUBAGENT_STARTED, SUBAGENT_ROW, isRunGroup } from "../subagents/subagentRows";
import { SUBAGENTS } from "../subagents/subagentFold";
import { type NativeRegistry, type OpenDiff } from "../rows/rowProps";
import { NoticeRow } from "../rows/NoticeRow";
import { rowKind } from "../virtualTranscriptModel";
import { type QueueDrawn } from "./drawnHeight";
import { OlderRowFade } from "./OlderRowFade";
import { rowDomId, RowFrame, RowContent } from "./RowFrame";
import { entersUnseen, mountsOffscreen, skipsOffscreenRows } from "../conversation/offscreenRows";
import { shelvedHeight } from "../conversation/shelvedRows";

/// A row drawn as tool rows: tool calls and thoughts, a background task's or a subagent's end, a
/// compaction, a failover, a policy the harness cannot keep, and the one-line
/// rows drawn on the tool rows' line (model.ts `isLineRow`: another agent's message, a notice, an
/// inbox notice, a report batch's or the waiting group's head), so they all sit one line apart.
const isStepRow = (row: AcpmuxRow | undefined) =>
  row !== undefined &&
  (isLineRow(row) ||
    row.kind === "backgroundTask" ||
    row.kind === SUBAGENT_DONE ||
    row.kind === SUBAGENT_STARTED ||
    row.kind === SUBAGENT_ROW ||
    (row.kind === SUBAGENTS && !isRunGroup(row)) ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "policyUnenforced" ||
    row.kind === "agentPair" ||
    row.kind === BACKGROUND_TURN ||
    (row.kind === "activity" && !isEditRow(row)));

/// A step row by its layout mark: a step row above, or the running turn's line right under one
/// (model.ts `isLiveStep`, which `layoutConversation` marks MARK_STEP), so the live line and its
/// neighbours carry the after-step and before-step classes the layout implies (#31769).
const isStepAt = (rows: readonly AcpmuxRow[], index: number) => {
  const row = rows[index];
  return isStepRow(row) || (row?.below === true && isLiveStep(row, prevDrawnRow(rows, index)));
};

/// The rows array is immutable. Keep the control list by that array and start index so a divider
/// drag does not rescan every settled row under an open Worked-for disclosure on every frame.
const disclosureControlsByRows = new WeakMap<readonly AcpmuxRow[], Map<number, string | undefined>>();

const disclosureControls = (rows: readonly AcpmuxRow[], after: number): string | undefined => {
  let byStart = disclosureControlsByRows.get(rows);
  if (!byStart) {
    byStart = new Map();
    disclosureControlsByRows.set(rows, byStart);
  }
  if (byStart.has(after)) return byStart.get(after);

  const ids: string[] = [];
  for (let index = after; index < rows.length; index += 1) {
    const row = rows[index]!;
    // turnView marks every row copied under an open Worked-for disclosure as settled. This
    // includes assistant commentary before the tool calls; stopping on kind alone left that
    // first commentary row outside aria-controls and made the disclosure target incomplete.
    if (!row.settled) break;
    ids.push(rowDomId(row.id));
  }
  const controls = ids.length > 0 ? ids.join(" ") : undefined;
  byStart.set(after, controls);
  return controls;
};

/// The transcript's own sets of rows that enter, fade in as the chat loads, or fade in from a late
/// page of older history: read when the frames are drawn, so the render reads no ref itself.
export type RowFrameSources = {
  entering: { readonly current: { has(key: string): boolean } };
  loadFade: LoadFadeWindow;
  older: OlderRowFade;
};

/// What `drawRowFrames` draws the mounted rows' frames from: one object a transcript render hands it.
type RowFramesView = {
  rows: readonly AcpmuxRow[];
  mountedRanges: readonly { first: number; last: number }[];
  geometry: { topAt(index: number): number; gapAt(index: number): number; heightAt(index: number): number };
  /// The content in view, in the geometry's offsets: rows mounted far from it skip their contents
  /// (conversation/offscreenRows.ts). `viewHeight` 0 skips none.
  viewTop: number;
  viewHeight: number;
  /// Rows that end above this offset (the geometry's) are shelved (conversation/shelvedRows.ts);
  /// -Infinity shelves none.
  shelfAbove: number;
  frameKey: string;
  registry: NativeRegistry;
  setSizeRef: React.MutableRefObject<string>;
  rowWidth: number;
  expanded: Folds;
  observer: ResizeObserver | undefined;
  queueDrawn: QueueDrawn;
  sentPromptIds: ReadonlySet<string>;
  /// Rows may enter (`RowFrameSources.entering`): not while a session switch loads.
  enters: boolean;
  onEntered: (id: string) => void;
  /// Rows may fade in as the chat loads (`RowFrameSources.loadFade`): not while a session switch loads.
  loadFades: boolean;
  onLoadFaded: (id: string) => void;
  onOlderShown: (id: string) => void;
  activeRowId: string | undefined;
  selectedRows: ReadonlySet<number>;
  tabStopId: string | undefined;
  finalFooter: string | undefined;
  onFocus: (id: string) => void;
  onRowKeyDown: (index: number, event: React.KeyboardEvent<HTMLElement>) => void;
  onToggleActivity: (id: string) => void;
  onLoadFold?: (fold: number) => Promise<void>;
  onOpenDiff: OpenDiff | undefined;
  streams: boolean | undefined;
  sessionId: string | undefined;
  githubRepository: string | undefined;
  rowRepositories: ((index: number) => string | undefined) | undefined;
  scopeAt: (index: number) => ReferenceScope | undefined;
};

/// The stand-ins' elements (conversation/standIns.ts): no class and no children, only the row's box.
export function standInElements(
  rows: readonly AcpmuxRow[],
  ranges: readonly { first: number; last: number }[],
  geometry: { topAt(index: number): number; heightAt(index: number): number },
  frameKey: string,
): React.ReactElement[] {
  const out: React.ReactElement[] = [];
  for (const { first, last } of ranges)
    for (let index = first; index < last && index < rows.length; index += 1)
      out.push(
        <div
          key={`${frameKey}:${rows[index]!.id}`}
          style={{
            position: "absolute",
            left: "var(--cv-inset)",
            right: "var(--cv-inset-end, var(--cv-inset))",
            top: geometry.topAt(index),
            height: geometry.heightAt(index),
          }}
        />,
      );
  return out;
}

/// Each mounted row's frame, its props worked out again only when its rows or inputs changed
/// (conversation/rowFrameCache.ts): a streamed token redoes the live row's alone, and React skips
/// every other frame on the element `cache` kept, whatever the rows in view.
export function drawRowFrames(
  cache: RowFrameCache,
  sources: RowFrameSources,
  view: RowFramesView,
): React.ReactElement[] {
  const { rows, geometry } = view;
  const entering = view.enters ? sources.entering.current : undefined;
  const loadFade = view.loadFades ? sources.loadFade : undefined;
  const older = sources.older;
  const skips = view.viewHeight > 0 && skipsOffscreenRows();
  // The screen's height bounds the window's, and reading it forces no layout (innerHeight may).
  const windowHeight = skips ? (window.screen?.height ?? 0) : 0;
  cache.begin([
    view.frameKey,
    view.registry,
    view.rowWidth,
    view.observer,
    view.queueDrawn,
    view.onEntered,
    view.onLoadFaded,
    view.onOlderShown,
    view.onFocus,
    view.onRowKeyDown,
    view.onToggleActivity,
    view.onLoadFold,
    view.onOpenDiff,
    view.streams,
    view.sessionId,
  ]);
  const rowFrames: React.ReactElement[] = [];
  for (const { first, last } of view.mountedRanges)
    for (let absoluteIndex = first; absoluteIndex < last && absoluteIndex < rows.length; absoluteIndex += 1) {
      const row = rows[absoluteIndex]!;
      const isExpanded = row.foldOpen ?? view.expanded.has(row.id);
      const frameId = rowFrameKey(row);
      const inputs = cache.scratch;
      inputs.index = absoluteIndex;
      inputs.top = geometry.topAt(absoluteIndex);
      inputs.gapBelow = absoluteIndex + 1 < rows.length ? geometry.gapAt(absoluteIndex + 1) : 0;
      inputs.expanded = isExpanded;
      inputs.active = view.activeRowId === row.id;
      inputs.selected = view.selectedRows.has(absoluteIndex);
      inputs.tabStop = view.tabStopId === row.id;
      inputs.finalFooter = row.id === view.finalFooter;
      inputs.sendThinking = row.kind === THINKING && row.verbKey !== undefined && view.sentPromptIds.has(row.verbKey);
      inputs.enter = entering?.has(frameId) ?? false;
      inputs.loadFade = loadFade?.fades(row.id) ?? false;
      inputs.shelved = shelvedHeight(inputs.top, geometry.heightAt(absoluteIndex), view.shelfAbove);
      inputs.older = older?.has(row.id) ? older : undefined;
      inputs.repository = view.githubRepository ?? view.rowRepositories?.(absoluteIndex);
      inputs.scope = view.scopeAt(absoluteIndex);
      // An open Worked-for row names every row under it (`disclosureControls`), cached by rows.
      const opensDisclosure = row.kind === WORKED && isExpanded;
      // Kept by frame id: the session's `frameKey` is in what every frame shares (`begin`).
      const keptFrame = opensDisclosure ? undefined : cache.take(frameId, rows);
      if (keptFrame) {
        rowFrames.push(keptFrame);
        continue;
      }
      const next = nextDrawnRow(rows, absoluteIndex);
      const prev = prevDrawnRow(rows, absoluteIndex);
      const kind = rowKind(row);
      const Component = view.registry[kind] ?? NoticeRow;
      const controls = opensDisclosure ? disclosureControls(rows, absoluteIndex + 1) : undefined;
      const stepHere = isStepAt(rows, absoluteIndex);
      const element = (
        <RowFrame
          // Session-list metadata can arrive after cached rows paint. It must not change their keys
          // (nor a new chat taking its session: `frameSession`); reply bodies fence their own identity
          // and timestamp.
          key={`${view.frameKey}:${frameId}`}
          row={row}
          kind={kind}
          joinsPrevious={(stepHere && isStepAt(rows, absoluteIndex - 1)) || isLiveStep(row, prev)}
          joinsNext={stepHere && isStepAt(rows, absoluteIndex + 1)}
          opensTurn={opensBackgroundTurn(row, prev)}
          beforeFooter={isBeforeFooter(row, next)}
          beforeIndicator={next !== undefined && rowMark(row) === MARK_PROMPT && rowMark(next) === MARK_INDICATOR}
          beforeOwnMessage={
            next !== undefined && rowMark(row) === MARK_PROMPT && rowMark(next) === MARK_PROMPT && ownMessagesJoin()
          }
          replyActions={keepsReplyRoom(row, next)}
          status={statusEdge(row, next, prev)}
          lastFooter={isLastFooter(row, next)}
          finalFooter={inputs.finalFooter}
          continuationFooter={isContinuationFooter(row, next)}
          lastTurn={row.lastTurn === true}
          index={absoluteIndex}
          setSizeRef={view.setSizeRef}
          top={inputs.top}
          gapBelow={inputs.gapBelow}
          rowWidth={view.rowWidth}
          expanded={isExpanded}
          observer={view.observer}
          queueDrawn={view.queueDrawn}
          sendThinking={inputs.sendThinking}
          enter={inputs.enter}
          onEntered={view.onEntered}
          loadFade={inputs.loadFade}
          shelved={inputs.shelved}
          onLoadFaded={view.onLoadFaded}
          older={inputs.older as OlderRowFade | undefined}
          onOlderShown={view.onOlderShown}
          active={inputs.active}
          selected={inputs.selected}
          tabStop={inputs.tabStop}
          onFocus={view.onFocus}
          onRowKeyDown={view.onRowKeyDown}
          contentType={Component}
          controls={controls}
          onToggleActivity={view.onToggleActivity}
          onOpenDiff={view.onOpenDiff}
          githubRepository={inputs.repository}
          referenceScope={inputs.scope as ReferenceScope | undefined}
          // Read by the frame's first mount only, and not compared (sameRowFrame): no frame draws again
          // for them, and a kept frame's values are the ones it mounted with.
          offscreen={
            skips &&
            mountsOffscreen(inputs.top, geometry.heightAt(absoluteIndex), view.viewTop, view.viewHeight, windowHeight)
          }
          placedHeight={geometry.heightAt(absoluteIndex)}
          // An arrival out of view draws in place (read on the first mount only, like `offscreen`).
          enterUnseen={
            inputs.enter && entersUnseen(inputs.top, geometry.heightAt(absoluteIndex), view.viewTop, view.viewHeight)
          }
        >
          <RowContent
            Component={Component}
            liveTools={view.streams}
            row={row}
            replyActions={hasReplyActions(row, next)}
            sessionId={view.sessionId}
            onToggleActivity={view.onToggleActivity}
            onLoadFold={view.onLoadFold}
            onOpenDiff={view.onOpenDiff}
            expanded={isExpanded}
            controls={controls}
            githubRepository={inputs.repository}
          />
        </RowFrame>
      );
      const span = rowPropsWindow(rows, absoluteIndex);
      rowFrames.push(cache.put(frameId, rows, span.first, span.last, element));
    }
  cache.end();
  return rowFrames;
}
