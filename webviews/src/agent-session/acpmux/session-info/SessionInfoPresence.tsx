import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { usePresence } from "../../../ui/presence";
import { useChatDisplay } from "../chatDisplay";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatSizing } from "../chatWidth";
import { FIND_HIDE_EVENT, FIND_OPEN_EVENT } from "../conversation/chatFind";
import { type HeaderPullRequest } from "../header/headerState";
import { useTabRow } from "../header/tabRow";
import { useT } from "../i18n";
import { transcriptColumn, type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { compactingUsage } from "../usageStats";
import { GalleryDialog } from "../summary/GalleryDialog";
import { waitingSubagents } from "../summary/subagentStatusListModel";
import type { Artifact } from "../conversation/artifactPreview";
import type { StartedSession } from "../started/startedSessions";
import { headerStatus, visibleChanges } from "./changesSectionModel";
import { useChangesStatuses, useStableUrls, withHeader } from "./changesStatus";
import { type AccessGrant } from "./EnvironmentSection";
import { SubagentBanner, SubagentTitle } from "./SubagentScopeHeader";
import { SUBAGENT_HEADER } from "./subagentScopeHeaderModel";
import { subagentBackLabel, type SubagentScope } from "./subagentScope";
import { setSessionInfoSection, useSessionInfoState, type SessionInfoSectionId } from "./sessionInfoState";
import { type ProcessRegistry } from "./processes";
import { type SessionInfoPlan } from "./progressSectionModel";
import type { WorkflowAgent, WorkflowSummary } from "../summary/workflow";
import { useUnderSessionInfo } from "./underSessionInfo";
import { useNativeSessionInfoHost } from "./native/host";
import { useSameValue } from "./sameValue";
import { LazyNativeSessionInfo } from "./native/LazyNativeSessionInfo";
import {
  FLOAT_MARGIN,
  pushes,
  pushedWidth,
  sessionInfoFits,
  sessionInfoPopover,
  sessionInfoStage,
  SESSION_INFO_CLEAR,
  sessionInfoClear,
  findBarCramped,
  pushedRoom,
  chatContentOverflow,
  SIDE_PANEL,
  sessionInfoTopOffset,
  type PaneRoom,
  paneRoom,
  DISMISS_KEEPERS,
  SESSION_INFO_TOGGLE,
  openOutputFile,
} from "./sessionInfoModel";
import { MemoSessionInfoPanel, MemoSessionInfoSections } from "./SessionInfo";
import type { ResumeActions } from "../subagents/ResumeControl";
import { useCountedRender } from "../perfRender";
import { COMPUTER_USE_PREVIEW_RESERVE, useComputerUsePreview } from "../computerUse/computerUsePreview";
import { useChangeCounts, type ReadChanges } from "./changeCounts";
import type { ReadCarried, ResolveCarried } from "./carriedSectionModel";
import { usageEntries } from "./usageEntries";
import { chatPlace } from "../chatMachine";
import { useAlsoHere } from "./alsoHereSectionModel";
import type { SessionInfoLists } from "./useSessionInfo";
import { useStableCallback } from "./useStableCallback";

/// How long after an output click a narrowing counts as that diff's split.
const SPLIT_SETTLE_MS = 2000;
/// The shell's pin on the transcript's column while Session Info pushes (sessionInfo.css).
const SESSION_INFO_COLUMN = "--acpmux-session-info-column";
/// How far the column moves left while it pushes (sessionInfo.css --acpmux-session-info-shift).
const SESSION_INFO_ROOM = "--acpmux-session-info-room";
/// The animated column shift itself (sessionInfo.css, a registered custom property).
const SHIFT = "--acpmux-session-info-shift";
/// Whether the chat's column is sliding now (its shift's transition runs on the shell's main).
const columnSliding = (shell: HTMLElement) => {
  const main = shell.querySelector<HTMLElement>(":scope > .acpmux-main");
  // Reading the animations brings the page's styles up to date first, so a slide set a moment ago runs.
  if (!main || typeof main.getAnimations !== "function") return false;
  return main.getAnimations().some((animation) => (animation as CSSTransition).transitionProperty === SHIFT);
};

/// AppKit's top is in page CSS pixels, below the same header or shared tab row as the web panel.
function nativeTop(shell: HTMLElement | null | undefined, tabRowHeight: number): number {
  const shellTop = Math.max(0, shell?.getBoundingClientRect().top ?? 0);
  if (tabRowHeight > 0) return shellTop + tabRowHeight;
  const header = shell ? Number.parseFloat(getComputedStyle(shell).getPropertyValue("--acpmux-header-height")) : NaN;
  return shellTop + (Number.isFinite(header) ? header : 28);
}

/// The composer's stack height (`.acpmux-dock` in `shell`) while `on`: from the top of its highest
/// child to the shell's foot. A new chat's dock is `display: contents` (bottomStack.css), so its own
/// box is empty and only its children have one. One ResizeObserver on the dock and its children (a
/// MutationObserver re-observes when its children change), both disconnected when `on` goes false or
/// the shell changes.
/// A change the observers see is drawn in the frame the stack changed (flushSync, as VirtualTranscript
/// follows the same stack): a scheduled render drew the panel's old foot over the grown stack for a
/// frame or more (the running tray coming in under an expanded Session Info).
function useDockHeight(shell: HTMLElement | null | undefined, on: boolean): number {
  const [height, setHeight] = useState(0);
  useLayoutEffect(() => {
    const dock = on ? shell?.querySelector<HTMLElement>(".acpmux-dock") : null;
    if (!shell || !dock) return;
    const measure = () => {
      let top = Infinity;
      for (const part of [dock, ...dock.children]) {
        const box = part.getBoundingClientRect();
        if (box.height > 0) top = Math.min(top, box.top);
      }
      return top === Infinity ? 0 : Math.max(0, Math.round(shell.getBoundingClientRect().bottom - top));
    };
    let last = measure();
    const read = () => {
      const next = measure();
      if (next === last) return;
      last = next;
      flushSync(() => setHeight(next));
    };
    const resize = new ResizeObserver(read);
    const observe = () => {
      resize.disconnect();
      resize.observe(dock);
      for (const child of dock.children) resize.observe(child);
    };
    observe();
    setHeight(last);
    const children = new MutationObserver(() => {
      observe();
      read();
    });
    children.observe(dock, { childList: true });
    return () => {
      children.disconnect();
      resize.disconnect();
    };
  }, [shell, on]);
  return height;
}

const UNMEASURED: PaneRoom = { width: 0, side: 0, height: 0 };
/// The chat's room, followed as the pane resizes and as the side panel opens, closes or resizes
/// (`beside` changes with it); width 0 before it is measured. A resize draws in the frame that has
/// the new width: the observer runs after that frame's layout and before its paint, and `flushSync`
/// renders the panel's place there (state set plainly drew a frame or more later, the panel floating
/// over the narrowed transcript before the chat jumped aside: "WHY DOES IT FLICKER").
function usePaneRoom(shell: HTMLElement | null | undefined, live: boolean, beside: unknown): PaneRoom {
  const [room, setRoom] = useState<PaneRoom>(UNMEASURED);
  useLayoutEffect(() => {
    if (!shell || !live) return;
    const measure = () => {
      const next = paneRoom(shell);
      setRoom((current) =>
        current.width === next.width && current.side === next.side && current.height === next.height ? current : next,
      );
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(() => flushSync(measure));
    observer.observe(shell);
    const side = shell.querySelector<HTMLElement>(SIDE_PANEL);
    if (side) observer.observe(side);
    return () => observer.disconnect();
  }, [shell, live, beside]);
  return room;
}

/// Session Info while it is drawn: its presence, its width and folds, whether it floats or pushes,
/// and what it lists. Its own component, so its enter and exit phases, a drag step and a fold draw the panel
/// alone, not the chat pane that calls useSessionInfo (one Session Info open drew that pane five
/// times in a frame).
export const SessionInfoPresence = memo(function SessionInfoPresence({
  chat,
  shown,
  snapshot,
  lists,
  pullRequest,
  machineName,
  repository,
  cloudRepositoryAvailable,
  shell,
  grants,
  beside,
  wide,
  openedOutputAt,
  asked = false,
  onSuppress,
  onStepAside,
  onStepBack,
  registry,
  subagents,
  sessions,
  onSetRunningLimit,
  workflows,
  revealed,
  onRevealed,
  onStopProcess,
  onOpenOutput,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  readPromptImage,
  onOpenFolder,
  readChanges,
  onOpenChanges,
  onSaveEnvironment,
  onReconnectMcp,
  readCarried,
  onResolveCarried,
  remoteControl,
  onCompact,
  onViewPrompt,
  onOpenChat,
  onShowUsage,
  onRender,
  onOpenDocument,
  onShowCall,
  onShowTurn,
  scope,
}: {
  /// The chat whose width and folds it draws (sessionInfoState.ts `useSessionInfoState`).
  chat: string | undefined;
  shown: boolean;
  /// The chat's snapshot, its rows as the sections read them (`lists.rows`): the same object while
  /// nothing else in it changed (useSessionInfo `panelSnapshot`).
  snapshot: AcpmuxSnapshot;
  /// What it lists of the rows (useSessionInfoLists).
  lists: SessionInfoLists;
  /// What the App read of the chat's pull requests (header state), which the hook already follows.
  pullRequest: HeaderPullRequest | undefined;
  machineName?: string;
  repository?: string;
  cloudRepositoryAvailable?: boolean;
  shell?: HTMLElement | null;
  grants?: readonly AccessGrant[];
  /// The side panel beside the chat, as it opens or closes: the chat's room is measured again.
  beside?: unknown;
  /// A handoff review's form shows: whether the panel lies over the chat is measured against it.
  wide?: boolean;
  /// When an output's diff was last opened (Date.now()).
  openedOutputAt: { readonly current: number };
  /// The person opened it in this pane (useSessionInfo), not only a saved open state.
  asked?: boolean;
  /// That diff's split left no room for the chat beside Session Info: Session Info steps aside.
  onSuppress: () => void;
  /// A row opened something (the folder, Changes, an output): Session Info hides until it is gone
  /// (stepAside.ts); `onStepBack` brings it back at once (the host refused the open).
  onStepAside: () => void;
  onStepBack: () => void;
  registry?: ProcessRegistry;
  subagents?: {
    views: Record<string, AcpmuxRow[]> | undefined;
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
    /// Resume on a stopped subagent's line (subagents/ResumeControl.tsx): the chat's `resumeAgent`.
    resume?: ResumeActions;
  };
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  /// The chat's Claude workflows (Labs, App.tsx `workflows`), in Background tasks (WorkflowTasks.tsx).
  workflows?: {
    list: readonly WorkflowSummary[];
    onStop?: (id: string) => Promise<unknown>;
    onOpenAgent?: (agent: WorkflowAgent) => void;
  };
  revealed?: { section: SessionInfoSectionId; at: number };
  onRevealed: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  /// A pasted image's bytes by its id, for its Sources row (direct.ts `promptImage`).
  readPromptImage?: (id: string) => Promise<string | undefined>;
  onOpenFolder?: (path: string) => void;
  /// Reads the chat folder's git changes for Environment's Changes row (changeCounts.ts), with
  /// `onOpenChanges` opening the chat folder's diff beside the chat.
  readChanges?: ReadChanges;
  onOpenChanges?: () => void;
  onSaveEnvironment?: () => Promise<unknown>;
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Carried memory (CarriedSection.tsx): `_acpmux/agent_home` and `_acpmux/agent_home_resolve`.
  readCarried?: ReadCarried;
  onResolveCarried?: ResolveCarried;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onCompact?: () => void;
  onViewPrompt?: () => void;
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  onRender?: () => void;
  onOpenDocument?: (artifact: Artifact) => void;
  onShowCall?: (toolCallId: string) => boolean;
  onShowTurn?: (turnId: string) => void;
  /// The subagent it lists, while the pane shows one's own view.
  scope?: SubagentScope;
}) {
  onRender?.();
  useCountedRender("session-info:presence");
  const { width, sections } = useSessionInfoState(chat);
  const native = useNativeSessionInfoHost();
  const t = useT();
  const [gallery, setGallery] = useState(false);
  const display = useChatDisplay();
  const sizing = useChatSizing();
  // A column the display owns (its own width) or a zoomed page's is a new object on every call: kept
  // while its numbers are the same, so the placement effect below (the shell's column pin and its
  // CHAT_LAYOUT_EVENT) runs only when the column changes, never once per streamed token.
  const column = useSameValue(chatColumnOf(display, sizing.scale));
  // It slides in from the pane's right edge and back out (ui/presence.ts), keeping its sections
  // while it leaves.
  const presence = usePresence(shown && !native, "right");
  // The computer use card beside the chat narrows its column (the placement effect's pin follows it).
  const preview = useComputerUsePreview() !== null;
  // Leaving: the column slides back while the panel slides out (sessionInfo.css).
  const leaving = !native && !!presence.leaving;
  const drawn = native ? shown : presence.present;
  // The chat's room: the pane less the side panel beside it (a document), whose edge the floating
  // panel keeps clear of, so it never lies over the document.
  const { width: paneWidth, side, height: paneHeight } = usePaneRoom(shell, drawn, beside);
  // How far the chat's content reaches past the column the model expects (chatContentOverflow),
  // read while the panel floats: a panel that would lie over any of it pushes the chat left (Leo,
  // 2026-11-01: "why does the session info not push the layout left ever anymore"). It keeps its
  // reading while pushed, and starts again at 0 each time the panel opens.
  const [overflow, setOverflow] = useState(0);
  // Its three places by the pane's width: in the gutter, pushing into the chat, over the chat.
  const stage = sessionInfoStage(
    display.sessionInfo,
    { width: paneWidth, height: paneHeight },
    width,
    column,
    wide,
    overflow,
  );
  const push = stage === "push";
  const overChat = stage === "overlay";
  // Pushing, its width (narrowed to keep a readable chat) and the room it takes from the chat's right
  // end: by default only what the gutter lacks, so the chat narrows gradually (pushedRoom).
  const panelWidth = push ? pushedWidth(paneWidth, width) : width;
  const room = push ? pushedRoom(paneWidth, panelWidth, column, overflow, pushes(display.sessionInfo)) : 0;
  // How far the panel reaches into the chat's right edge: Find's bar keeps clear of it (sessionInfoClear).
  // The web panel floats over the chat's whole width (its column moves left instead), so the chat's
  // right edge is the pane's; the App's native panel still takes its room from the chat.
  const chatRoom = native ? room : 0;
  const clear = sessionInfoClear(panelWidth, chatRoom);
  const cramped = findBarCramped(paneWidth - chatRoom, clear);
  // In a short pane, over the chat it is a popover that a click elsewhere hides (POPOVER_BELOW_HEIGHT);
  // in a narrow one too (useSessionInfo `narrow`).
  const popover = sessionInfoPopover(paneHeight, overChat) || (overChat && !sessionInfoFits(paneWidth));
  // Open only from a saved state (a new chat, a relaunch), it waits for the person where it would be a
  // popover: it steps aside until the toggle, a running line's count or the palette opens it
  // (cmuxterm-hq#6137: a new chat in a 370px pane opened with the panel over its Retry). A narrow pane
  // holds it in useSessionInfo before it draws.
  // Only a short pane's popover: a narrow pane's is held or kept by useSessionInfo, whose observer can
  // run after this one (a panel showing as the pane narrows must stay, as a popover).
  // Only as it first draws: one already showing as the window gets shorter stays, as a popover (a
  // resize never closes it; Leo, 2026-11-10).
  const drawnRoomy = useRef(false);
  useLayoutEffect(() => {
    if (!drawn) {
      drawnRoomy.current = false;
      return;
    }
    if (paneWidth <= 0) return;
    const short = sessionInfoPopover(paneHeight, overChat);
    if (!short) drawnRoomy.current = true;
    else if (!asked && !drawnRoomy.current) onSuppress();
  }, [drawn, paneWidth, paneHeight, overChat, asked, onSuppress]);
  useEffect(() => {
    const doc = shell?.ownerDocument;
    if (!native || !drawn || !popover || !doc) return;
    const away = (event: PointerEvent) => {
      const target = event.target as Element | null;
      if (target?.closest?.(`${SESSION_INFO_TOGGLE}, ${DISMISS_KEEPERS}`)) return;
      onSuppress();
    };
    doc.addEventListener("pointerdown", away, true);
    return () => doc.removeEventListener("pointerdown", away, true);
  }, [native, drawn, popover, shell, onSuppress]);
  // Over the chat in a taller pane, the card stops above the composer's stack: its height, followed
  // while it lies over the chat (one ResizeObserver on the dock, disconnected when it no longer does,
  // turns popover, or the panel goes). The card's foot animates to it (sessionInfo.css).
  const stopsAboveComposer = overChat && !popover;
  const dockHeight = useDockHeight(shell, drawn && stopsAboveComposer);
  const tabRowHeight = useTabRow().height;
  const sessionInfoTop = sessionInfoTopOffset(tabRowHeight);
  // The column slides only as the panel comes in or leaves (sessionInfo.css data-session-info-sliding);
  // a resize, or a stage that changes with the pane's width, moves it at once, in the frame the pane
  // has its new size, as the rest of the chat moves (agent-pane-running-layout.test.ts).
  const wasDrawn = useRef(false);
  // The placement marker: a pushed column narrows the transcript and not the header
  // (sessionInfo.css). Floating moves nothing.
  useLayoutEffect(() => {
    if (!shell) return;
    if (!drawn) {
      wasDrawn.current = false;
      delete shell.dataset.sessionInfoChatPlacement;
      delete shell.dataset.sessionInfoLeaving;
      delete shell.dataset.sessionInfoSliding;
      shell.style.removeProperty("--acpmux-header-room");
      shell.style.removeProperty(SESSION_INFO_COLUMN);
      shell.style.removeProperty(SESSION_INFO_ROOM);
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
      return;
    }
    shell.dataset.sessionInfoChatPlacement = push ? "push" : "overlay";
    // Pushing, the transcript's column keeps the width it has in the whole pane on every frame of the
    // slide, and only moves left (pushKeepsColumn, sessionInfo.css).
    // Beside the computer use card (App.tsx data-cu-preview on the chat), the column the chat has
    // closed keeps the card's reserve at its end: pinned at that width, opening rewraps no line.
    const reserve = shell.querySelector(":scope > .acpmux-main[data-cu-preview]") ? COMPUTER_USE_PREVIEW_RESERVE : 0;
    if (push && paneWidth > 0)
      shell.style.setProperty(SESSION_INFO_COLUMN, `${transcriptColumn(paneWidth, column, reserve).width}px`);
    else shell.style.removeProperty(SESSION_INFO_COLUMN);
    // How far the column moves left (sessionInfo.css --acpmux-session-info-shift): the room, back to 0
    // as the panel leaves, so the column slides back with it. The native panel's room is a flex item.
    const shift = push && !native && !leaving ? room : 0;
    const opening = !wasDrawn.current;
    wasDrawn.current = true;
    if (push && !native && (opening || leaving)) shell.dataset.sessionInfoSliding = "";
    // A change that is no open or leave (a resize, a stage the new width picks) after the slide ended:
    // no transition, even before the slide's transitionend has come.
    else if ("sessionInfoSliding" in shell.dataset && !columnSliding(shell)) delete shell.dataset.sessionInfoSliding;
    shell.style.setProperty(SESSION_INFO_ROOM, `${shift}px`);
    shell.toggleAttribute("data-session-info-leaving", leaving);
    shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
    // Push always narrows the transcript, not the header: native tabs reserve the tools at the
    // pane's trailing edge. Reuse the measured room (excluding an artifact beside the chat).
    if (paneWidth > 0) shell.style.setProperty("--acpmux-header-room", `${paneWidth}px`);
  }, [shell, drawn, push, paneWidth, column, native, leaving, room, preview]);
  // Find in Chat's bar keeps left of the panel (sessionInfoClear, conversation.css .acpmux-find__bar). Its
  // own effect, so a width drag only moves the bar and fires no chat layout event per frame.
  useLayoutEffect(() => {
    if (!shell || !drawn) return;
    shell.style.setProperty(SESSION_INFO_CLEAR, `${clear}px`);
    return () => {
      shell.style.removeProperty(SESSION_INFO_CLEAR);
    };
  }, [shell, drawn, clear]);
  // Where the chat has no room for Find's bar beside the panel (findBarCramped), the panel steps aside
  // when Find opens, and Find steps aside when the toggle opens the panel over an open bar: the bar is
  // never under it. The panel stays aside after Find closes, until its toggle opens it.
  useEffect(() => {
    if (!shell || !drawn || !cramped) return;
    const away = () => onSuppress();
    // Cramped with both showing (the toggle opened it over the bar, or the window got narrower): the
    // bar steps aside, never the panel, since a resize never closes it (Leo, 2026-11-10).
    if (shell.querySelector(".acpmux-find__bar"))
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(FIND_HIDE_EVENT));
    shell.addEventListener(FIND_OPEN_EVENT, away);
    return () => shell.removeEventListener(FIND_OPEN_EVENT, away);
  }, [shell, drawn, cramped, onSuppress]);
  // The slide's end: the column's own transition, else the panel's (a slide that moved nothing).
  useEffect(() => {
    const main = shell?.querySelector<HTMLElement>(":scope > .acpmux-main");
    if (!shell || !main) return;
    const ended = (event: TransitionEvent) => {
      if (!("sessionInfoSliding" in shell.dataset)) return;
      if (event.target === main ? event.propertyName === SHIFT : !columnSliding(shell))
        delete shell.dataset.sessionInfoSliding;
    };
    shell.addEventListener("transitionend", ended);
    shell.addEventListener("transitioncancel", ended);
    return () => {
      shell.removeEventListener("transitionend", ended);
      shell.removeEventListener("transitioncancel", ended);
    };
  }, [shell]);
  useLayoutEffect(() => {
    if (!shell) return;
    return () => {
      delete shell.dataset.sessionInfoSliding;
      delete shell.dataset.sessionInfoChatPlacement;
      shell.style.removeProperty("--acpmux-header-room");
      shell.style.removeProperty(SESSION_INFO_COLUMN);
      shell.style.removeProperty(SESSION_INFO_ROOM);
      delete shell.dataset.sessionInfoLeaving;
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
    };
  }, [shell]);
  // A card under the panel (the computer use live preview) reads where it goes from the shell.
  // The web panel floats at the pane's right, pushing or not; the native one's room is in the chat's row.
  useUnderSessionInfo(shell, drawn, push && native, FLOAT_MARGIN, sessionInfoTop, push && native ? room : undefined);
  // What the sections list of the rows (useSessionInfoLists, read as the pane renders): a subagent's
  // panel reads its own rows only.
  const {
    summary,
    made,
    links,
    produced,
    outputFiles,
    scopedPlan,
    artifacts,
    documents,
    agents,
    transcriptTasks,
    processes,
    toolCalls,
    rows: sectionRows,
    rowCount,
  } = lists;
  // Measured before paint, so a panel that would cover the chat never draws a frame over it. Again
  // as the pane, the panel or the rows change while it floats or pushes by less than its full room
  // (the chat's width is the pane less that room).
  const reading = drawn && (stage === "float" || (push && room < panelWidth + FLOAT_MARGIN));
  useLayoutEffect(() => {
    if (!drawn) {
      setOverflow(0);
      return;
    }
    if (!shell || !reading || wide) return;
    // The chat's drawn width, not the room's target: while the push slides in, the chat is still wider.
    const main = shell.querySelector<HTMLElement>(":scope > .acpmux-main");
    const drawnChat = main?.getBoundingClientRect().width ?? 0;
    // The web panel's chat keeps the pane's width and its column slides (sessionInfo.css): measured
    // where the column is drawn now, not where the slide ends. Against the slide's end, the rows still
    // at their old place read as overflow, which asked for more room, until the push gave way to lying
    // over the chat.
    const shiftNow = main
      ? Number.parseFloat(
          main.ownerDocument.defaultView?.getComputedStyle(main).getPropertyValue("--acpmux-session-info-shift") ?? "",
        ) || 0
      : 0;
    const next = chatContentOverflow(
      shell,
      push && !native ? paneWidth - shiftNow : drawnChat > 0 ? Math.min(paneWidth, drawnChat) : paneWidth - room,
      column,
      push ? paneWidth : undefined,
    );
    // Only a larger reading sets it: an unchanged one would still draw the panel once (React runs the
    // component before it bails out), once per streamed row while it pushes.
    if (next > overflow) setOverflow((current) => (next > current ? next : current));
  }, [shell, drawn, reading, wide, paneWidth, room, side, width, column, rowCount, push, overflow, native]);
  // After `summary`: read before its declaration, it threw on every render (a temporal dead zone).
  const usage = compactingUsage(summary?.usage, summary?.usageStats, summary?.contextBreakdown);
  // The plan the transcript's todo list draws. The chat's is the one the client publishes beside its
  // rows (snapshot.progress, liveProgress.ts): the same object until the checklist changes or its turn
  // ends, so a streamed token neither rescans the rows nor recounts the steps (carried from #34933). A
  // subagent's panel gets the parent's snapshot, so it never reads that one: its plan comes from its
  // own live rows (useSessionInfoLists `scopedPlan`), so a step ticked in place shows here at once.
  const live = snapshot.progress;
  const livePlan = useMemo<SessionInfoPlan | undefined>(
    () => (live ? { entries: live.plan, ended: Boolean(live.ended), done: live.completed } : undefined),
    [live],
  );
  const plan = scope?.agent ? scopedPlan : drawn ? livePlan : undefined;
  const views = subagents?.views;
  const asks = subagents?.asks;
  // Environment's Changes: the folder's git changes, read as the panel shows and at each turn's end.
  const edits = useChangeCounts(
    readChanges,
    drawn,
    `${snapshot.sessionId ?? ""}\u0000${snapshot.isWorking ? "working" : "idle"}`,
  );
  const waiting = useSameValue(
    useMemo(() => (drawn && asks ? waitingSubagents(asks, views) : new Set<string>()), [drawn, asks, views]),
  );
  // The rest of what the sections take from the snapshot and the App, kept the same way.
  // What the sections draw of the other chats acpmux lists, not the list itself: the list is new each
  // time any chat anywhere changes (its status, its indicator, its time), which drew every section
  // again, while a scroll ran too, though they show none of it. Usage's rows (usageEntries.ts) and Also
  // working here's (useAlsoHere) keep their identity until what they draw changes.
  const everyChat = drawn && !scope ? snapshot.sessions : undefined;
  const usageSessions = useSameValue(useMemo(() => usageEntries(everyChat), [everyChat]));
  const alsoHereRows = useSameValue(useAlsoHere(summary?.sessionId, everyChat));
  const peerKinds = useSameValue(snapshot.peerKinds);
  // Where the chat runs beyond its summary (its route and listed peer), for Environment's machine row.
  const place = useSameValue(chatPlace(snapshot));
  const startedList = useSameValue(scope ? undefined : sessions?.list);
  const workflowList = useSameValue(scope ? undefined : workflows?.list);
  // A subagent, a started chat or a workflow's agent opens beside the chat (its own pane): Session Info
  // steps aside for it as for the folder and Changes, and is back once that pane closes (Lucas,
  // 2026-11-06: "clicking on a subagent will close the session info summary menu, like how it does for
  // files and changes"). One shown here in place moves the panel to its scope, which brings it back.
  const openSubagentOwn = useStableCallback(subagents?.onOpen);
  const openSessionOwn = useStableCallback(sessions?.onOpen);
  const openWorkflowAgentOwn = useStableCallback(workflows?.onOpenAgent);
  const onOpenSubagent = useMemo(
    () =>
      openSubagentOwn &&
      ((id: string) => {
        onStepAside();
        openSubagentOwn(id);
      }),
    [openSubagentOwn, onStepAside],
  );
  const onOpenSession = useMemo(
    () =>
      openSessionOwn &&
      ((sessionId: string) => {
        onStepAside();
        openSessionOwn(sessionId);
      }),
    [openSessionOwn, onStepAside],
  );
  const onOpenWorkflowAgent = useMemo(
    () =>
      openWorkflowAgentOwn &&
      ((agent: WorkflowAgent) => {
        onStepAside();
        openWorkflowAgentOwn(agent);
      }),
    [openWorkflowAgentOwn, onStepAside],
  );
  const onStopWorkflow = useStableCallback(workflows?.onStop);
  const setRunningLimit = useStableCallback(onSetRunningLimit);
  const banner = useMemo(
    () =>
      scope && SUBAGENT_HEADER !== "title" ? <SubagentBanner scope={scope} variant={SUBAGENT_HEADER} /> : undefined,
    [scope],
  );
  // Every pull request's title, state, lines and checks from the App's cache, the folder's live
  // read over it (changesStatus.ts); asked for only while Changes is unfolded.
  const changes = useMemo(() => visibleChanges(made?.pullRequests ?? [], {}), [made?.pullRequests]);
  const prUrls = useStableUrls(changes);
  const { statuses: cached } = useChangesStatuses(prUrls, drawn, drawn && sections.changes);
  const statuses = useMemo(() => withHeader(cached, headerStatus(pullRequest)), [cached, pullRequest]);
  // An output's diff opens beside the chat. With Settings Push always, when that split leaves too
  // little room for a readable chat beside Session Info, it steps aside until the toggle opens it
  // again. By default it stays, pushing or, under 648px, over the chat above the composer.
  const roomy = !pushes(display.sessionInfo) || sessionInfoFits(paneWidth);
  const roomyRef = useRef(roomy);
  // Environment's project opens in Files as a tab right of the chat (App.tsx `onOpenFolder`), its
  // Changes the folder's diff there, and an Outputs file in cmux's file pages: Session Info steps aside
  // so what the row opened is what shows, and comes back once it is closed (stepAside.ts; Leo,
  // 2026-10-27: "why am i sent to a whole new thing instead of a tab opening on the right?").
  const openFolder = useMemo(
    () =>
      onOpenFolder &&
      ((path: string) => {
        onStepAside();
        onOpenFolder(path);
      }),
    [onOpenFolder, onStepAside],
  );
  const openChanges = useMemo(
    () =>
      onOpenChanges &&
      (() => {
        onStepAside();
        onOpenChanges();
      }),
    [onOpenChanges, onStepAside],
  );
  const openOutputPath = useCallback(
    (path: string) => {
      onStepAside();
      // A refused open (no gesture, a denied path, a missing file) shows nothing: the panel is back.
      void openOutputFile(path).then((opened) => {
        if (!opened) onStepBack();
      });
    },
    [onStepAside, onStepBack],
  );
  useEffect(() => {
    const was = roomyRef.current;
    roomyRef.current = roomy;
    if (was && !roomy && Date.now() - openedOutputAt.current < SPLIT_SETTLE_MS) onSuppress();
  }, [roomy, openedOutputAt, onSuppress]);
  // AppKit is above the page. Existing page popovers temporarily take the pane and restore it on close.
  if (native)
    return (
      <>
        {/* The App draws the panel over the page (AgentPaneView+SessionInfo.swift sessionInfoFrame: the
            pushed width and the float margin from the pane's right edge, left of a side panel). Pushing,
            the page keeps that same room in the shell's row, so the chat narrows beside the panel
            instead of lying under it (cmuxterm-hq#6137). */}
        {push && drawn && !gallery && room > 0 && (
          <div
            className="acpmux-session-info-room"
            aria-hidden="true"
            style={{
              width: Math.max(0, room - FLOAT_MARGIN),
              marginRight: Math.min(room, FLOAT_MARGIN),
            }}
          />
        )}
        <LazyNativeSessionInfo
          key={scope ? `${snapshot.sessionId}:subagent:${scope.agent.id}` : snapshot.sessionId}
          shown={drawn && !gallery}
          width={panelWidth}
          top={nativeTop(shell, tabRowHeight)}
          side={side}
          foot={stopsAboveComposer ? dockHeight : undefined}
          overChat={overChat}
          label={t("sessionInfo.title")}
          title={scope ? `${t("sessionInfo.subagent")} · ${scope.agent.name}` : undefined}
          onBack={scope?.onBack}
          backLabel={scope ? subagentBackLabel(t, scope.parent) : undefined}
          summary={summary}
          usage={usage}
          plan={plan}
          machineName={machineName}
          peerKinds={snapshot.peerKinds}
          place={place}
          repository={repository}
          grants={scope ? undefined : grants}
          cloudRepositoryAvailable={cloudRepositoryAvailable}
          made={made}
          links={links}
          produced={produced}
          artifacts={artifacts}
          documents={documents}
          rows={sectionRows}
          agents={agents}
          waiting={waiting}
          statuses={statuses}
          processes={processes ?? []}
          listed={registry?.listed ?? false}
          transcriptTasks={transcriptTasks ?? []}
          sessions={scope ? [] : (sessions?.list ?? [])}
          workflows={scope ? [] : (workflows?.list ?? [])}
          agent={scope?.agent}
          onOpenSubagent={subagents?.onOpen}
          resumeSubagent={subagents?.resume}
          onOpenSession={sessions?.onOpen}
          allSessions={scope ? undefined : snapshot.sessions}
          onOpenChat={onOpenChat}
          onShowUsage={scope ? undefined : onShowUsage}
          onSetRunningLimit={onSetRunningLimit}
          onStopWorkflow={workflows?.onStop}
          onOpenWorkflowAgent={workflows?.onOpenAgent}
          onStopProcess={onStopProcess}
          onOpenOutput={onOpenOutput}
          onOpenSourceFile={onOpenSourceFile}
          onOpenUrl={onOpenUrl}
          onOpenDocument={onOpenDocument}
          onOpenArtifacts={rowCount > 0 ? () => setGallery(true) : undefined}
          onReconnectMcp={onReconnectMcp}
          remoteControl={scope ? undefined : remoteControl}
          onCompact={scope ? undefined : onCompact}
          onViewPrompt={scope ? undefined : onViewPrompt}
          onOpenFolder={openFolder}
          onShowCall={onShowCall}
          onShowTurn={onShowTurn}
          revealed={revealed}
          onRevealed={onRevealed}
        />
        {gallery && (
          <GalleryDialog
            rows={sectionRows}
            onClose={() => setGallery(false)}
            onOpenImage={
              onOpenImage &&
              ((src, alt, path) => {
                setGallery(false);
                onOpenImage(src, alt, path);
              })
            }
          />
        )}
      </>
    );
  if (!drawn) return null;
  return (
    <MemoSessionInfoPanel
      title={scope && SUBAGENT_HEADER === "title" ? <SubagentTitle scope={scope} /> : undefined}
      width={panelWidth}
      placement={push ? "push" : "overlay"}
      overlap={0}
      // Floating or pushing, it starts under the chat header (styles.css --acpmux-header-height; in the
      // pane's tab row, the row's height), so the header's tools, its own toggle among them, stay in reach.
      under={sessionInfoTop}
      // Floating or pushing, it stays left of a side panel beside the chat (its width).
      side={side}
      foot={stopsAboveComposer ? dockHeight : undefined}
      onDismiss={popover ? onSuppress : undefined}
      presence={presence}
    >
      {/* Another chat's sections start drawn with what that chat has: none of its rows drops in. */}
      <MemoSessionInfoSections
        key={scope ? `${snapshot.sessionId}:subagent:${scope.agent.id}` : snapshot.sessionId}
        banner={banner}
        agent={scope?.agent}
        summary={summary}
        machineName={machineName}
        peerKinds={peerKinds}
        place={place}
        repository={repository}
        cloudRepositoryAvailable={cloudRepositoryAvailable}
        made={made}
        artifacts={artifacts}
        documents={documents}
        rows={sectionRows}
        outputFiles={outputFiles}
        produced={produced}
        plan={plan}
        toolCalls={toolCalls}
        agents={agents}
        waiting={waiting}
        onOpenSubagent={onOpenSubagent}
        resumeSubagent={subagents?.resume}
        statuses={statuses}
        processes={processes}
        listed={registry?.listed}
        transcriptTasks={transcriptTasks}
        // The chats the chat's agent started are the chat's.
        sessions={startedList}
        workflows={workflowList}
        onStopWorkflow={onStopWorkflow}
        onOpenWorkflowAgent={onOpenWorkflowAgent}
        onOpenSession={onOpenSession}
        // Usage lists every chat acpmux lists; a subagent's own panel has no Usage.
        usageSessions={usageSessions}
        alsoHere={alsoHereRows}
        onOpenChat={onOpenChat}
        onShowUsage={scope ? undefined : onShowUsage}
        onSetRunningLimit={setRunningLimit}
        revealed={revealed}
        onRevealed={onRevealed}
        onStopProcess={onStopProcess}
        sections={sections}
        onSection={setSessionInfoSection}
        onOpenSourceFile={onOpenSourceFile}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
        readPromptImage={readPromptImage}
        onOpenFolder={openFolder}
        edits={edits}
        onOpenChanges={openChanges}
        onOpenOutputFile={openOutputPath}
        // Save keeps the chat's machine and folder, not a subagent's.
        onSaveEnvironment={scope ? undefined : onSaveEnvironment}
        onReconnectMcp={onReconnectMcp}
        // Carried memory is the chat's own, never a subagent's.
        readCarried={scope ? undefined : readCarried}
        onResolveCarried={scope ? undefined : onResolveCarried}
        remoteControl={scope ? undefined : remoteControl}
        // Compact ends the chat's context, not a subagent's.
        onCompact={scope ? undefined : onCompact}
        onViewPrompt={scope ? undefined : onViewPrompt}
        onOpenDocument={onOpenDocument}
        onShowCall={onShowCall}
        onShowTurn={onShowTurn}
      />
    </MemoSessionInfoPanel>
  );
});
