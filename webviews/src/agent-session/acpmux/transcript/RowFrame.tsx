import React, { useLayoutEffect, useRef, useState, useEffectEvent, useCallback } from "react";
import { LOAD_FADE_CLASS } from "../../shared/loadFade";
import { sendPopEnabled } from "../chatDisplay";
import { holdEntranceForFirstFrame } from "../conversation/entranceClock";
import { markRecapEntrance } from "../conversation/turnEndFold";
import { NEXT_STEP } from "../conversation/turns";
import { type AcpmuxRow, type StatusEdge, rowFrameKey, isLineRow, SINCE_DIVIDER } from "../model";
import { acpmuxPerf } from "../perf";
import { useLiveToolRow } from "../liveToolOutput";
import { noteMounted, noteUnmounted } from "../flickerLog";
import { useT, type Translate } from "../i18n";
import { type ReferenceScope, ReferenceScopeContext } from "../conversation/bareReferences";
import { DisclosureRow } from "../conversation/transcriptDisclosureModel";
import { rovingTabStopProps } from "../../../ui/listRowKeyboard";
import { playSendMorph } from "../conversation/sendMorph";
import { type RowProps, type OpenDiff } from "../rows/rowProps";
import { sameReferenceScope, sameRowFrame } from "../virtualTranscriptModel";
import { isRunPart } from "../conversation/runPartId";
import { type QueueDrawn } from "./drawnHeight";
import { OlderRowFade } from "./OlderRowFade";
import { OFFSCREEN_ROW_CLASS, onceRendered } from "../conversation/offscreenRows";

/// What a row's content draws from (the registry component's props, and the component).
/// `liveTools`: the pane's live transcript, whose rows draw a running command's newer output ahead
/// of the pane's snapshot (liveToolOutput.ts).
type RowContentProps = {
  Component: React.ComponentType<RowProps>;
  liveTools?: boolean;
} & RowProps;

/// A row's content, drawn again only when what it draws from changes: never for its frame's place
/// (`top`, `index`, `gapBelow`), focus (`tabStop`, `active`, `selected`) or entrance flags. A scroll
/// moves every mounted frame each time a row above is measured or an older page lands, and the
/// roving tab stop follows the first row in view; with the content drawn inside the frame, each such
/// change drew every mounted row's whole content again (Leo, 2026-11-06: "Still seeing the flicker
/// re-render. Sometimes when I scroll up").
///
/// The row is compared by object, not by `sameRowDraw`: a renderer may draw from fields its row's
/// version does not cover (ActivityLineRow's `doingSendTo`), and only its own comparator knows
/// which. A new row object reaches the renderer, whose memo decides; a history row keeps its object
/// across snapshots, so a scroll still draws none of them again.
export const RowContent = React.memo(
  function RowContent({ Component, liveTools = false, ...props }: RowContentProps) {
    // Counted when committed: a render React set aside (an interrupted concurrent pass) drew nothing.
    useLayoutEffect(() => {
      if (acpmuxPerf.enabled) acpmuxPerf.render(`content:${props.row.id}`);
    });
    // A running command's output that moved on without the pane: this row alone draws it.
    const row = useLiveToolRow(props.row, liveTools);
    return <Component {...props} row={row} />;
  },
  (previous, next) => {
    const keys = Object.keys(next) as (keyof RowContentProps)[];
    if (keys.length !== Object.keys(previous).length) return false;
    return keys.every((key) => Object.is(previous[key], next[key]));
  },
);

/// One transcript row. It reports its drawn height before the frame paints whenever it mounts or
/// its content, width or expansion changes; the transcript's ResizeObserver reports later changes
/// (a font that loads, a custom renderer that grows).
export const RowFrame = React.memo(function RowFrame({
  row,
  kind,
  joinsPrevious,
  joinsNext,
  opensTurn,
  beforeFooter,
  beforeIndicator,
  replyActions,
  status,
  lastFooter,
  finalFooter,
  continuationFooter,
  lastTurn,
  index,
  setSizeRef,
  top,
  rowWidth,
  expanded,
  observer,
  queueDrawn,
  sendThinking,
  enter,
  onEntered,
  loadFade,
  onLoadFaded,
  older,
  onOlderShown,
  active,
  selected,
  tabStop,
  onFocus,
  onRowKeyDown,
  referenceScope,
  gapBelow,
  offscreen,
  placedHeight,
  children,
}: {
  row: AcpmuxRow;
  kind: string;
  /// The placed gap under the row (grid.md 5.5: the stack owns it, the row has no padding): the row's
  /// gap target spans it, so a drag from between two rows starts a selection.
  gapBelow: number;
  /// Whether the row mounts away from the view (conversation/offscreenRows.ts): read at its first
  /// mount only, so a row never changes whether its contents may be skipped.
  offscreen: boolean;
  /// The row's height as the transcript places it (measured, or the estimate): a skipped row's box
  /// is this high. Read at its first mount only, with `offscreen`.
  placedHeight: number;
  /// A step row (tool calls, thoughts, a background task's end) after another: no gap above it.
  joinsPrevious: boolean;
  /// A step row before another: no gap below it, so steps keep one 26px rhythm across rows.
  joinsNext: boolean;
  /// The first row of a turn the agent ran on its own, drawn as its own turn (model.ts
  /// `opensBackgroundTurn`): the turn gap over it is the stack's (MARK_OPENS_TURN); the row says so
  /// as `data-opens-turn`, the turn's boundary, so nothing reads it as the row above's tail.
  opensTurn: boolean;
  /// A reply right over its turn's footer: the footer hugs it (`--cv-meta-gap`), as a meta row.
  beforeFooter: boolean;
  /// A prompt right over the live line (transcriptGrid.ts waiting rule): the gap under it is the block
  /// gap, not the turn gap, so its action row is laid centred in that (conversation.css).
  beforeIndicator: boolean;
  /// Whether the row (a reply) keeps its action row's room (model.ts `keepsReplyRoom`): its height
  /// depends on it, so the frame redraws and measures again when it changes.
  replyActions: boolean;
  /// Next to a status row (model.ts `statusEdge`): the room between the row and the next one is the
  /// status gap, so a status line between two replies sits in the middle of it.
  status: StatusEdge | undefined;
  /// The chat's last footer: it ends at the message gap, so no band sits over the composer.
  lastFooter: boolean;
  /// The footer that ends the chat (nothing drawn after it): its turn has ended, so its Copy row
  /// shows without a hover (Leo, 2026-11-02: "i should be able to see the copy buttons on your
  /// responses when your things end").
  finalFooter: boolean;
  /// The next drawn turn belongs to this same assistant: half the normal turn gap.
  continuationFooter: boolean;
  /// The final row of a latest turn without a footer: preserve the normal turn gap at the composer.
  lastTurn: boolean;
  index: number;
  /// The list's length for `aria-setsize`, held in a ref so a row that arrives changes no prop here
  /// (TranscriptView, `setSize`). The row writes the attribute on the mount that puts it in the list.
  setSizeRef: React.MutableRefObject<string>;
  top: number;
  rowWidth: number;
  expanded: boolean;
  observer: ResizeObserver | undefined;
  queueDrawn: QueueDrawn;
  /// This thinking row belongs to a prompt that entered on the current send. It may be separated
  /// from that prompt by finished activity rows, so the style cannot rely on adjacent siblings.
  sendThinking: boolean;
  /// The row arrived live: it enters with the shared motion on this, its first mount.
  enter: boolean;
  onEntered: (id: string) => void;
  /// The row arrived while the chat loaded and mounts now, its first time: it fades in once.
  loadFade: boolean;
  onLoadFaded: (id: string) => void;
  /// The row came in on a late page of older history and has never mounted: its first copy fades once.
  older: OlderRowFade | undefined;
  onOlderShown: (id: string) => void;
  active: boolean;
  selected: boolean;
  tabStop: boolean;
  onFocus: (id: string) => void;
  onRowKeyDown: (index: number, event: React.KeyboardEvent<HTMLElement>) => void;
  /// What the child row draws from, compared instead of `children` (a new element every render).
  contentType: unknown;
  controls?: string;
  onToggleActivity: (id: string) => void;
  onOpenDiff?: OpenDiff;
  githubRepository?: string;
  /// Which repository the row's bare `#N` names (conversation/bareReferences.ts).
  referenceScope?: ReferenceScope;
  children: React.ReactNode;
}) {
  acpmuxPerf.span("row.renders", 1);
  if (acpmuxPerf.enabled) acpmuxPerf.render(`row:${row.id}`);
  const t = useT();
  const ref = useRef<HTMLElement>(null);
  const [entering] = useState(enter);
  // Prompts and replies get the message-specific entrance. Tool/status rows keep the existing
  // generic rise, while the row's reserved height and absolute placement stay unchanged.
  // Hidden user rows render no content and keep the empty-row geometry. Notice rows are user-kind
  // status lines whose `.cv-tools` strip row CSS targets as the article's direct child, so they keep
  // the generic entrance too. Only real prompts and replies get the presentation wrapper.
  const messageEntering =
    entering &&
    (row.kind === "assistant" ||
      (row.kind === "user" && row.incoming?.kind !== "hidden" && row.incoming?.kind !== "notice"));
  const [olderFade] = useState(older);
  const [loadFading] = useState(loadFade);
  // The height a skipped row is placed at, from its first mount; once it renders the browser keeps
  // its rendered height instead (`auto`), which the row's observer has measured by then.
  const [skipHeight] = useState(() => (offscreen ? `auto ${placedHeight}px` : undefined));
  const observerRef = useRef(observer);
  useLayoutEffect(() => {
    observerRef.current = observer;
  });
  // A row mounted away from the view is marked in its mount's commit, before the page styles or lays
  // it out, by the row's own DOM writes rather than its rendered class and style: a later render then
  // never puts the mark back once it is dropped. (A render that changes the row's class list before
  // then clears it early; the row is then laid out and measured like any other.)
  // Once the page renders it (still a window or more from the view), the row draws like any other:
  // the paint containment content-visibility brings snaps its contents to whole pixels, a pixel off
  // the subpixel place (`marginTop`) an unmarked row draws its text at. The drop is the row's own DOM
  // write, no render. Observed afresh, the row reports its rendered height in the next frame even
  // when its observer saw it render first, while it still counted as skipped (drawnHeightOf).
  useLayoutEffect(() => {
    const node = ref.current;
    if (!skipHeight || !node) return undefined;
    node.classList.add(OFFSCREEN_ROW_CLASS);
    node.style.containIntrinsicHeight = skipHeight;
    return onceRendered(node, () => {
      node.classList.remove(OFFSCREEN_ROW_CLASS);
      node.style.containIntrinsicHeight = "";
      const rows = observerRef.current;
      if (rows) {
        rows.unobserve(node);
        rows.observe(node);
      }
    });
    // `skipHeight` is state from the frame's first mount: this runs on that mount only.
  }, [skipHeight]);
  // A prompt sent from the latest row: what the composer drew of it moves into this row's bubble and
  // previews, as its entrance (conversation/sendMorph.ts). Its first mount only, before it paints.
  const morphOnMount = useEffectEvent(() => {
    if (messageEntering && row.kind === "user" && ref.current) playSendMorph(ref.current);
  });
  useLayoutEffect(() => morphOnMount(), []);
  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLElement>) => onRowKeyDown(index, event),
    [index, onRowKeyDown],
  );
  const rowTabStop = rovingTabStopProps(tabStop, handleKeyDown);
  // A frame drawn again for its place hands down the scope object it had while that names the same
  // repositories (sameRowFrame compares it so): a new object would redraw its content's chips.
  const [scope, setScope] = useState(referenceScope);
  if (scope !== referenceScope && !sameReferenceScope(scope, referenceScope)) setScope(referenceScope);
  // The row a disclosure inside it is drawn in: its toggle's transition anchors on it (useDisclosure.ts).
  const content = (
    <DisclosureRow.Provider value={row.id}>
      <ReferenceScopeContext.Provider value={scope ?? null}>{children}</ReferenceScopeContext.Provider>
    </DisclosureRow.Provider>
  );
  useLayoutEffect(() => {
    if (acpmuxPerf.enabled) acpmuxPerf.render(`frame:${row.id}`);
  });
  const countMount = useEffectEvent(() => {
    // Mounts and same-commit remounts, counted only while measuring (loadDebug.ts `loadTick`).
    const id = row.id;
    acpmuxPerf.rowMounted(id);
    // Always on: a remount in place goes to the flicker detector's ring file (flickerLog.ts).
    noteMounted(`row:${id}`, "row", row.kind);
    return () => {
      acpmuxPerf.rowUnmounted(id);
      noteUnmounted(`row:${id}`);
    };
  });
  // The id the frame mounted with: a message run's line can take over its first row's frame
  // (model.ts `rowFrameKey`), so the count is closed under the id it opened with.
  useLayoutEffect(() => countMount(), []);
  // Only the first mount fades.
  const fadeInOnMount = useEffectEvent(() => {
    if (loadFading) onLoadFaded(row.id);
  });
  useLayoutEffect(() => fadeInOnMount(), []);
  // Only the first mount enters.
  const enterOnMount = useEffectEvent(() => {
    if (entering) onEntered(rowFrameKey(row));
  });
  useLayoutEffect(() => enterOnMount(), []);
  // A generic row's entrance starts on the frame that first draws it, not at this commit: WebKit
  // starts its clock here, and a busy main thread drew the row only after its fade had ended, whole
  // at once (conversation/entranceClock.ts). A sent prompt's pop (conversation.css SEND-POP, when
  // Pop In Sent Prompts is on) waits for its first frame the same way; other messages keep their own send clock.
  const holdEntranceOnMount = useEffectEvent(() => {
    if (!entering || !ref.current) return undefined;
    if (messageEntering)
      return row.kind === "user" && sendPopEnabled()
        ? holdEntranceForFirstFrame(ref.current, undefined, true)
        : undefined;
    // Only the recap card has an entrance to mark: no other entering row reads the DOM for it.
    if (row.kind === NEXT_STEP) markRecapEntrance(ref.current);
    return holdEntranceForFirstFrame(ref.current);
  });
  useLayoutEffect(() => holdEntranceOnMount(), []);
  const olderFadeOnMount = useEffectEvent(() => {
    const node = ref.current;
    if (!node || !olderFade) return;
    // A warm-window copy has rendered too: consume eligibility and start its fade before paint,
    // even offscreen. Neither a later intersection nor a remount may defer or replay it.
    onOlderShown(row.id);
    node.dataset.olderShown = "true";
    return olderFade.watch(node, () => onOlderShown(row.id));
  });
  // Only the first mount fades.
  useLayoutEffect(() => olderFadeOnMount(), []);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !observer) return;
    observer.observe(node);
    return () => observer.unobserve(node);
  }, [observer]);
  // What the last queue was for, but the version: a commit that changed only the version (a streamed
  // token) is one the row's observer reports when it changed the row's size (queueDrawn).
  const queuedFor = useRef<readonly unknown[] | undefined>(undefined);
  const writeSetSizeOnMount = useEffectEvent(() => {
    // The mount that puts this row in the list writes its `aria-setsize`. A later length is written
    // by the transcript's own sweep, which runs only when the length changed, so a streamed token
    // reads no mounted row at all.
    ref.current?.setAttribute("aria-setsize", setSizeRef.current);
  });
  // Only this mount: the ref holds the length, so a changed one re-runs nothing here.
  useLayoutEffect(() => writeSetSizeOnMount(), []);
  // The row as of this commit, for its open state (`queueDrawn` below), written before it reads it.
  const drawnRow = useRef(row);
  useLayoutEffect(() => {
    drawnRow.current = row;
  });
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const was = queuedFor.current;
    const now = [
      row.id,
      replyActions,
      status,
      rowWidth,
      expanded,
      joinsPrevious,
      joinsNext,
      beforeFooter,
      lastFooter,
      continuationFooter,
      lastTurn,
      queueDrawn,
      // The observer sees the content box: a class that moves the padding is read here.
      node.className,
    ];
    queuedFor.current = now;
    const versionOnly = was !== undefined && now.every((value, at) => value === was[at]);
    // The row is read for its open state; its id and version say when that changed, so a new object
    // with the same version queues nothing again (a toggle inside it is its observer's report).
    return queueDrawn(node, row.id, row.version, replyActions, status, versionOnly, drawnRow.current);
  }, [
    row.id,
    row.version,
    replyActions,
    status,
    rowWidth,
    expanded,
    joinsPrevious,
    joinsNext,
    beforeFooter,
    lastFooter,
    continuationFooter,
    lastTurn,
    queueDrawn,
  ]);
  const placedTop = top + THREAD_TOP;
  const integralTop = Math.floor(placedTop);
  return (
    <article
      ref={ref}
      id={rowDomId(row.id)}
      data-row-id={row.id}
      data-row-card={row.ended ? "true" : undefined}
      data-opens-turn={opensTurn ? "true" : undefined}
      data-send-thinking={sendThinking ? "true" : undefined}
      className={`acpmux-row acpmux-${kind}${isLineRow(row) ? " acpmux-row--line" : ""}${isRunPart(row) ? " acpmux-row--run-part" : ""}${row.below ? " acpmux-row--below" : ""}${joinsPrevious ? " acpmux-row--after-step" : ""}${joinsNext ? " acpmux-row--before-step" : ""}${beforeFooter ? " acpmux-row--before-footer" : ""}${beforeIndicator ? " acpmux-row--before-indicator" : ""}${replyActions ? " acpmux-row--reply-room" : ""}${status ? ` acpmux-row--${status}` : ""}${lastFooter ? " acpmux-row--last-footer" : ""}${finalFooter ? " acpmux-row--final-footer" : ""}${continuationFooter ? " acpmux-row--continuation-footer" : ""}${lastTurn ? " acpmux-row--last-turn" : ""}${messageEntering ? " acpmux-row--message-enter" : entering ? " acpmux-row--enter" : ""}${olderFade ? " acpmux-row--older" : ""}${loadFading ? ` ${LOAD_FADE_CLASS}` : ""}`}
      data-transcript-active={active ? "true" : undefined}
      data-transcript-selected={selected ? "true" : undefined}
      aria-current={active ? "true" : undefined}
      {...rowTabStop}
      aria-label={speaker(kind, t)}
      aria-posinset={index + 1}
      // `aria-setsize` is not here: the transcript writes it to the mounted nodes, so a row that arrives
      // does not change a prop on every other one (TranscriptView, `setSize`).
      // `top`, not a transform: in the app (the page at its UI-scale zoom) a drag over a row placed
      // by `translateY` selected the line above the pointer (user 2026-10-21). A set `top` counts
      // from the thread's padding edge, not where an unset one sat, so it adds the padding.
      // Large CSS numeric offsets lose fractional bits in WebKit. Keep the integer offset and
      // its subpixel remainder separate so animated row heights remain adjacent in long chats.
      // The unread line's row takes no height and draws its mark over the gap under it
      // (conversation/unread.css), so it reads the gap's length.
      style={
        row.kind === SINCE_DIVIDER
          ? ({
              top: integralTop,
              marginTop: placedTop - integralTop,
              "--cv-since-gap": `${gapBelow}px`,
            } as React.CSSProperties)
          : { top: integralTop, marginTop: placedTop - integralTop }
      }
      onFocus={() => onFocus(row.id)}
    >
      {/* The row's own trailing gap is the only row-local empty surface owned by transcript selection.
          Keeping it as a separate hit target means content controls (including native media) never
          need to be enumerated by the gap handler. On the grid the stack places the gap under the row
          (design/grid.md 5.5), so the target spans the row's own bottom padding (inherited) and that
          placed gap under it, down to the next row. It comes first: the action rows
          laid in the same gap are positioned later in the row and stay over it, with their clicks. */}
      <span
        className="acpmux-row__gap"
        data-transcript-gap="row"
        aria-hidden="true"
        style={gapBelow > 0 ? { bottom: -gapBelow, height: gapBelow, boxSizing: "content-box" } : undefined}
      />
      {messageEntering ? (
        // The article is the virtualizer's measured box. Animate only this presentation wrapper:
        // compositor scale/opacity cannot change drawnHeightOf(article) while the entrance runs.
        <div className="acpmux-row__message-presentation">{content}</div>
      ) : (
        content
      )}
    </article>
  );
}, sameRowFrame);

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string, t: Translate) =>
  kind === "user" ? t("transcript.you") : kind === "assistant" ? t("transcript.agent") : undefined;

export const rowDomId = (id: string) => `acpmux-row-${encodeURIComponent(id)}`;

/// The thread's top padding (styles.css `.acpmux-thread`): rows draw this far below their places
/// (each row's `top` adds it), so the transcript ends this far past their total height.
export const THREAD_TOP = 16;
