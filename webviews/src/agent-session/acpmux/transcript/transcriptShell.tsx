import React from "react";
import { transcriptLiveVars } from "../transcriptGrid";
import { type AcpmuxRow, type PlacedLayout } from "../model";
import { ThreadMinimap } from "../threadMinimap/ThreadMinimap";
import { transcriptFadeReach, type RowsChange } from "../threadMinimap/model";
import { ChatMinimap } from "../chatMinimap/ChatMinimap";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { fadesBelow } from "../conversation/scrollAnchor";
import { RetryTargetContext } from "../conversation/turnActions";
import { GuestActionsBoundary } from "../conversation/GuestActionsBoundary";
import { FindReveal, type ChatFind } from "../conversation/chatFind";
import { ChatFindBar } from "../conversation/ChatFindBar";
import { LiveLinePulseContext } from "../conversation/liveLinePulse";
import { type TranscriptNeedsYou } from "../needsYou/JumpPill";
import { SubagentOfRow } from "../subagents/SubagentGroup";
import { SUBAGENT_OF_HEIGHT } from "../rows/SubagentOfPillRow";
import { UnreadBanner } from "../conversation/SinceDivider";
import { topZoneOffset } from "../overlayLayout";
// The jump pair's styles, before JumpButtons' own (the order VirtualTranscript.tsx loaded them in).
import "../jumpPair.css";
import "../jumpPlace.css";
import type { useT } from "../i18n";
import { SHOWN_SCROLLER_ATTRIBUTE } from "../../../scrollers";
import { WEB_SWAP_KEPT_SCROLL } from "../../../pages/shared/webSwap";
import { FOLLOW_BOTTOM_DEADBAND_PX } from "../virtualTranscriptModel";
import { standInElements } from "./rowFrames";
import { JumpToLatest, JumpUp } from "./JumpButtons";
import { type ScrollAnchor } from "./scrollAnchors";
import { THREAD_TOP } from "./RowFrame";
import { Spinner } from "../conversation/icons";

/// The box of the spinner over the loaded rows while older ones load (`.acpmux-older-loading`): it
/// shows only where the room held for them has this much space above the first loaded row.
const OLDER_SPINNER_BOX = 32;

/// The live line's box and gap in a run as custom properties on the scroller (transcriptGrid.ts transcriptLiveVars):
/// conversation.css sizes the line with them. Constant, so the scroller's per-scroll restyle never changes them.
const LIVE_STEP_VARS = transcriptLiveVars();

/// A wheel tick re-renders the transcript; these draw again only when their own props change (the minimap reads
/// the scroll from its scroller, not from a prop).
const JumpToLatestMemo = React.memo(JumpToLatest);
const ChatMinimapMemo = React.memo(ChatMinimap);

/// A read-only transcript draws inside the guest boundary (conversation/GuestActionsBoundary.tsx).
function ReadOnlyBoundary({ readOnly, children }: { readOnly: boolean; children: React.ReactNode }) {
  return readOnly ? <GuestActionsBoundary>{children}</GuestActionsBoundary> : <>{children}</>;
}

/// What the transcript's rows read from it: Find's reveal target and, for a prompt's own bookmark
/// button, the session its marks key into (threadMinimap/promptMarks.ts).
function TranscriptContext({
  find,
  sessionId,
  children,
}: {
  find: React.ContextType<typeof FindReveal>;
  sessionId?: string;
  children: React.ReactNode;
}) {
  return (
    <FindReveal.Provider value={find}>
      <PromptMarksSession.Provider value={sessionId ?? ""}>{children}</PromptMarksSession.Provider>
    </FindReveal.Provider>
  );
}

type MinimapProps = React.ComponentProps<typeof ThreadMinimap>;

/// What TranscriptView's render hands its shell (`drawTranscriptShell`): each value as the render worked it out.
export type TranscriptShellDeps = {
  readOnly: boolean;
  retryTarget: React.ContextType<typeof RetryTargetContext>;
  livePulse: React.ContextType<typeof LiveLinePulseContext>;
  ref: React.RefObject<HTMLDivElement | null>;
  slimFollow: boolean;
  /** The live line is among the mounted rows: the scroller's `data-live-line` (conversation.css). */
  liveLineMounted: boolean;
  onAnchor: ((anchor: ScrollAnchor | null) => void) | undefined;
  t: ReturnType<typeof useT>;
  onScroll: (event: React.UIEvent<HTMLDivElement>) => void;
  onWheel: (event: React.WheelEvent<HTMLDivElement>) => void;
  renderScroll: { top: number };
  origin: number;
  renderFollowing: boolean;
  below: number;
  jumpButton: boolean;
  behind: boolean;
  dockSpace: number;
  pinnedPill: AcpmuxRow | undefined;
  dockHoles: string;
  pinAt: { top: number; pad: number };
  topInset: number;
  showMinimap: boolean;
  rows: readonly AcpmuxRow[];
  layout: PlacedLayout;
  height: number;
  rowsChange: { current: RowsChange | undefined };
  earlier: MinimapProps["earlier"];
  canLoadNewer: boolean;
  canLoadOlder: boolean;
  /// The chat is still reading its rows.
  loading: boolean;
  later: MinimapProps["later"];
  promptCount: MinimapProps["promptCount"];
  loadThrough: MinimapProps["loadThrough"];
  loadPromptIndex: MinimapProps["loadPromptIndex"];
  sessionId: string | undefined;
  room: number;
  railBox: { height: number; foot: number; live: number };
  paneWidth: number;
  width: number;
  minimapPlaced: MinimapProps["placed"];
  endReserve: number;
  find: ChatFind | undefined;
  countReveal: React.ContextType<typeof FindReveal> | undefined;
  findReveal: React.ContextType<typeof FindReveal>;
  lane: number;
  lift: number;
  standIns: Parameters<typeof standInElements>[1];
  frameKey: Parameters<typeof standInElements>[3];
  thread: React.RefObject<HTMLDivElement | null>;
  pointAt: (target: EventTarget | null) => void;
  rowFrames: React.ReactNode;
  afterLatest: React.ReactNode;
  dockHeight: number;
  sinceKey: string | undefined;
  onJumpToSince: (() => void) | undefined;
  sinceRow: AcpmuxRow | undefined;
  clearTop: number;
  sinceIndex: number;
  jumpUp: boolean;
  upShown: boolean;
  jumpBackHeld: boolean;
  pressUp: () => void;
  working: boolean;
  onJumpLatest: (focused: boolean) => void;
  needsYou: TranscriptNeedsYou | undefined;
};

/// The transcript's drawn tree around its rows: the scroller, the two minimaps, Find's bar, the spacer that holds the
/// stand-ins and the mounted row frames (`drawRowFrames`), and over it the pinned pill, the unread banner and the jump
/// buttons. A plain render function TranscriptView calls inline as its return, so React sees the same element tree
/// (no component boundary of its own); it holds no state and reads only `deps`.
export function drawTranscriptShell({
  readOnly,
  retryTarget,
  livePulse,
  ref,
  slimFollow,
  liveLineMounted,
  onAnchor,
  t,
  onScroll,
  onWheel,
  renderScroll,
  origin,
  renderFollowing,
  below,
  jumpButton,
  behind,
  dockSpace,
  pinnedPill,
  dockHoles,
  pinAt,
  topInset,
  showMinimap,
  rows,
  layout,
  height,
  rowsChange,
  earlier,
  canLoadNewer,
  canLoadOlder,
  loading,
  later,
  promptCount,
  loadThrough,
  loadPromptIndex,
  sessionId,
  room,
  railBox,
  paneWidth,
  width,
  minimapPlaced,
  endReserve,
  find,
  countReveal,
  findReveal,
  lane,
  lift,
  standIns,
  frameKey,
  thread,
  pointAt,
  rowFrames,
  afterLatest,
  dockHeight,
  sinceKey,
  onJumpToSince,
  sinceRow,
  clearTop,
  sinceIndex,
  jumpUp,
  upShown,
  jumpBackHeld,
  pressUp,
  working,
  onJumpLatest,
  needsYou,
}: TranscriptShellDeps) {
  return (
    <ReadOnlyBoundary readOnly={readOnly}>
      <RetryTargetContext.Provider value={retryTarget}>
        <LiveLinePulseContext.Provider value={livePulse}>
          <div
            ref={ref}
            className="acpmux-scroll"
            role="feed"
            // The slim arm's send: the bubble only fades in where it lands, on a send step of at most
            // 120 ms (conversation.css SEND-SLIM), never opening from the right on a clip the main thread
            // paints (Leo, 2026-11-09: "the scroll up is extremely sluggish ... if I send in a prompt like
            // this and it just lags, it's not a good look").
            data-send-entrance={slimFollow ? "fade" : undefined}
            // The live line is among the mounted rows (`liveLineMounted`).
            data-live-line={liveLineMounted || undefined}
            // A read-only transcript's right-clicks are reported to no host (conversation/messageMenu.ts).
            data-read-only-transcript={readOnly ? "" : undefined}
            // Its place comes back after a web update's reload (reportAnchor, pages/shared/webSwap.ts).
            {...(onAnchor ? { [WEB_SWAP_KEPT_SCROLL]: "kept" } : {})}
            aria-label={t("transcript.label")}
            onScroll={onScroll}
            onWheel={onWheel}
            // Its thin scrollbar stays shown while the chat overflows, as in every agent app, and never
            // flashes as rows arrive or the view follows them (scrollers.ts, Leo 2026-10-21).
            {...{ [SHOWN_SCROLLER_ATTRIBUTE]: "" }}
            // Soft edges (conversation.css): the top once scrolled from the start, the bottom while more
            // lies below. A followed reply has nothing below it, even while its growth outruns the offset.
            // The bottom one takes follow's deadband: a reader resting at the end saw the band above the
            // composer flicker on and off as a row's measure or the stack moved the end by a pixel (Leo,
            // 2026-10-23: "that little bit above composer can flicker").
            data-fade-top={renderScroll.top - origin > 0.5 || undefined}
            data-fade-bottom={fadesBelow(renderFollowing, below) || undefined}
            // Jump to latest stands in that band: the fade reaches past it, so rows (a date line) pass
            // out of sight behind it instead of reading through its glass.
            data-jump-shown={(jumpButton && behind) || undefined}
            // Under the bottom stack: rows there stay out of sight (conversation.css), and focus or Find
            // scroll a row into view above it.
            data-docked={dockSpace > 0 || undefined}
            // A subagent's view keeps its "Subagent of" pill pinned over the top (pinnedPill below): rows
            // pass out of sight under it.
            data-pinned-top={pinnedPill ? "" : undefined}
            // How deep each soft edge draws (threadMinimap/model.ts transcriptFadeReach): none at that end
            // of the chat, deeper the farther the view is from it. Non-inherited (conversation.css), so a
            // scroll restyles the scroller alone.
            style={
              {
                "--acpmux-fade-top-reach": transcriptFadeReach(renderScroll.top - origin),
                "--acpmux-fade-bottom-reach": renderFollowing
                  ? 0
                  : transcriptFadeReach(below - FOLLOW_BOTTOM_DEADBAND_PX),
                ...(dockSpace > 0 ? { "--acpmux-dock-space": `${dockSpace}px` } : {}),
                ...(dockHoles ? { "--acpmux-dock-holes": dockHoles } : {}),
                ...(pinnedPill ? { "--acpmux-view-top": `${pinAt.pad + topInset + SUBAGENT_OF_HEIGHT}px` } : {}),
                // The live line's box and the gap over it in a run, from their one source (transcriptGrid.ts).
                ...LIVE_STEP_VARS,
              } as React.CSSProperties
            }
          >
            {showMinimap && (
              // Its own MinimapSource takes these values each render; the rail draws only when what it
              // draws changes (ThreadMinimapRail).
              <ThreadMinimap
                rows={rows}
                layout={layout}
                scrollTop={renderScroll.top - origin}
                scrolls={layout.totalHeight - height > 0.5}
                change={rowsChange.current}
                earlier={earlier}
                later={canLoadNewer ? later : undefined}
                promptCount={promptCount}
                loadThrough={loadThrough}
                loadPromptIndex={loadPromptIndex}
                sessionId={sessionId}
                scroller={ref}
                // Above the room under the last row, so a composer that grows while the reader is scrolled
                // up leaves the map as it was, as it does the scrollbar.
                viewportHeight={height - room}
                // Where the transcript's mask ends the view (conversation.css --acpmux-view-foot): the
                // rail's rows stay above its bottom band.
                foot={height - dockSpace}
                railBox={railBox}
                width={paneWidth}
                columnWidth={width}
                placed={minimapPlaced}
                topInset={topInset}
              />
            )}
            {/* The VS Code-style minimap at the right edge (Settings > Agent Chat > VS Code Minimap, off by default). */}
            <ChatMinimapMemo
              // Another chat is another minimap: no canvas, placeholder or scale carried over.
              key={sessionId}
              rows={rows}
              layout={layout}
              scroller={ref}
              viewportHeight={height - room}
              foot={height - dockSpace}
              width={width}
              endReserve={endReserve}
              scrolls={layout.totalHeight - height > 0.5}
              change={rowsChange.current}
            />
            {find?.open && <ChatFindBar find={find} />}
            <TranscriptContext find={countReveal ?? findReveal} sessionId={sessionId}>
              <div
                className="acpmux-spacer"
                // The room held above the loaded rows for older history (conversation/olderReserve.ts).
                data-older-room={layout.origin || undefined}
                // Older history is left to load. The room is not the sign of it: it goes once the reader
                // nears the loaded top with no page there yet (`giveRoomNearTop`), while pages still come.
                data-loads-older={canLoadOlder || undefined}
                style={{
                  height: layout.totalHeight,
                  width: lane > 0 ? `calc(100% + ${lane}px)` : undefined,
                }}
              >
                {/* A chat still reading its rows with none to show yet: a spinner, never an empty pane
                    (cmux#48605). The spacer is at least the view's height, so it sits in the view's middle. */}
                {loading && rows.length === 0 && (
                  <output className="acpmux-transcript-loading" aria-label={t("transcript.loading")}>
                    <Spinner size={20} loading />
                  </output>
                )}
                {/* Older history still to load: a spinner just above the first loaded row, in the room held
                    for that history, so a reader who scrolls up to the loaded top sees the next page is coming. */}
                {canLoadOlder && rows.length > 0 && (layout.origin ?? 0) >= OLDER_SPINNER_BOX && (
                  <output
                    className="acpmux-older-loading"
                    aria-label={t("transcript.loadingOlder")}
                    style={{ top: lift + topInset + THREAD_TOP + (layout.origin ?? 0) - OLDER_SPINNER_BOX }}
                  >
                    <Spinner size={16} loading />
                  </output>
                )}
                {/* Under the rows, at the thread's place: one empty element per stand-in. */}
                <div className="acpmux-stand-ins" aria-hidden style={{ top: lift + topInset }}>
                  {standInElements(rows, standIns, layout.geometry, frameKey)}
                </div>
                <div
                  ref={thread}
                  className="acpmux-thread"
                  style={{ top: lift + topInset }}
                  onPointerOver={(event) => pointAt(event.target)}
                  onPointerLeave={() => pointAt(null)}
                >
                  {rowFrames}
                </div>
              </div>
            </TranscriptContext>
          </div>
          {afterLatest && (
            <div
              className="acpmux-transcript-after-latest"
              // The dock is absolute over the stage. Keep an after-latest tray in flow above its
              // measured room so the composer never covers the expansion or its live tail.
              style={dockHeight > 0 ? { marginBottom: dockHeight } : undefined}
            >
              {afterLatest}
            </div>
          )}
          {pinnedPill && (
            // Lucas, 2026-11-06: "the "subagent of ..." text on the subagent page is sticky and always at the
            // top". Outside the scroller, so its soft edge never fades the pill; the row's own slot stays.
            <div className="acpmux-pinned-top" style={{ top: pinAt.top + topInset }}>
              <SubagentOfRow row={pinnedPill} />
            </div>
          )}
          {sinceKey !== undefined && onJumpToSince && sinceRow?.since && (
            // The top-start zone (overlayLayout.ts): what is new arrives where the eye settles, under
            // the clear line and under a pinned "Subagent of" pill.
            <div
              className="acpmux-over-top"
              data-zone="top-start"
              style={{
                top: topZoneOffset({
                  clearTop,
                  pinnedBottom: pinnedPill ? Math.max(pinAt.top + topInset, clearTop) + SUBAGENT_OF_HEIGHT : undefined,
                }),
              }}
            >
              <UnreadBanner
                mark={sinceKey}
                turns={sinceRow.since.turns}
                // A row's `at` is ms since 1970; a fixture's small `at` is no time to show.
                firstNewAt={(rows[sinceIndex + 1]?.at ?? 0) > 1e12 ? rows[sinceIndex + 1]!.at : undefined}
                onJump={onJumpToSince}
              />
            </div>
          )}
          {jumpUp && <JumpUp shown={upShown} back={jumpBackHeld} onJump={() => pressUp()} lift={dockSpace} />}
          {jumpButton && (
            <JumpToLatestMemo
              // The pill also shows at the latest message while the chats this chat started wait: it cycles to them.
              shown={behind || (needsYou?.elsewhere ?? 0) > 0}
              working={working}
              onJump={onJumpLatest}
              lift={dockSpace}
              needsYou={needsYou}
            />
          )}
        </LiveLinePulseContext.Provider>
      </RetryTargetContext.Provider>
    </ReadOnlyBoundary>
  );
}
