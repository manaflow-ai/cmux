import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { flushSync } from "react-dom";
import { usePresence } from "../../../ui/presence";
import { useChatDisplay } from "../chatDisplay";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatSizing } from "../chatWidth";
import { FIND_HIDE_EVENT, FIND_OPEN_EVENT } from "../conversation/chatFind";
import { PanelToggle } from "../header/PanelToggle";
import { useHeaderState, type HeaderPullRequest } from "../header/headerState";
import { useTabRow } from "../header/tabRow";
import { useT } from "../i18n";
import { transcriptColumn, type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { compactingUsage } from "../usageStats";
import { registerPicker } from "../pickerOpeners";
import { opensProcessTerminal } from "../processTerminal";
import { chatGallery, type GalleryItem } from "../summary/chatGallery";
import { GalleryDialog } from "../summary/GalleryDialog";
import { sessionSummary, type SessionSummary } from "../summary/sessionSummary";
import { waitingSubagents } from "../summary/subagentStatusListModel";
import type { Artifact } from "../conversation/artifactPreview";
import type { StartedSession } from "../started/startedSessions";
import { headerStatus, visibleChanges } from "./changesSectionModel";
import { useChangesStatuses, useStableUrls, withHeader } from "./changesStatus";
import { type AccessGrant } from "./EnvironmentSection";
import { SubagentBanner, SubagentTitle } from "./SubagentScopeHeader";
import { SUBAGENT_HEADER } from "./subagentScopeHeaderModel";
import {
  subagentBackLabel,
  subagentProcesses,
  subagentSummary,
  withChatEnds,
  type SubagentScope,
} from "./subagentScope";
import {
  bindSessionInfoPane,
  sessionInfoPaneKey,
  setSessionInfoOpen,
  setSessionInfoSection,
  useSessionInfoOpen,
  useSessionInfoState,
  type SessionInfoSectionId,
} from "./sessionInfoState";
import { outputArtifacts, outputLinks, type OutputArtifact, type OutputLink } from "./outputsSectionModel";
import { chatOutputs, type OutputFile } from "./chatOutputs";
import { producedLinks, type ProducedLink } from "./producedLinks";
import { type ProcessRegistry, type SessionInfoProcess } from "./processes";
import { currentPlan, type SessionInfoPlan } from "./progressSectionModel";
import type { WorkflowAgent, WorkflowSummary } from "../summary/workflow";
import { useUnderSessionInfo } from "./underSessionInfo";
import { useNativeSessionInfoHost } from "./native/host";
import { useSameValue } from "./sameValue";
import { NativeSessionInfo } from "./native/NativeSessionInfo";
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
  sessionInfoShown,
  SIDE_PANEL,
  sessionInfoTopOffset,
  type PaneRoom,
  paneRoom,
  DISMISS_KEEPERS,
  SESSION_INFO_TOGGLE,
  toolCallIds,
  openOutputFile,
} from "./sessionInfoModel";
import { MemoSessionInfoPanel, MemoSessionInfoSections } from "./SessionInfo";
import { subagentsIn } from "../subagents/subagentRows";
import type { Subagent } from "../subagents/subagentFold";
import { useCountedRender } from "../perfRender";
import { useStableProps } from "../stableProps";
import { COMPUTER_USE_PREVIEW_RESERVE, useComputerUsePreview } from "../computerUse/computerUsePreview";
import { useChangeCounts, type ReadChanges } from "./changeCounts";
import { useStepAside } from "./stepAside";
import { usageEntries } from "./usageEntries";
import { chatPlace } from "../chatMachine";
import { useAlsoHere } from "./alsoHereSectionModel";

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

/// Whether the chat's pane has no room for Session Info beside a readable chat (sessionInfoFits),
/// followed as the pane resizes and as the side panel opens or closes (`beside`) while `live`;
/// undefined until measured. One ResizeObserver on the shell, set state only when the answer flips.
function useNarrowPane(shell: HTMLElement | null | undefined, live: boolean, beside: unknown): boolean | undefined {
  const [narrow, setNarrow] = useState<boolean>();
  useLayoutEffect(() => {
    if (!shell || !live) return;
    const measure = () => {
      const width = paneRoom(shell).width;
      if (width > 0) setNarrow(!sessionInfoFits(width));
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(shell);
    return () => observer.disconnect();
  }, [shell, live, beside]);
  return narrow;
}

/// The header's toggle and Session Info for the chat's pane. `on` is Debug Settings
/// `agent.sessionInfo`: off, there is neither, and the App shows its summary card instead.
export function useSessionInfo({
  snapshot,
  machineName,
  repository,
  cloudRepositoryAvailable,
  shell,
  grants,
  onOpenOutput,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  readPromptImage,
  onOpenDocument,
  processes: registry,
  onStopProcess,
  subagents,
  sessions,
  onSetRunningLimit,
  workflows,
  onOpenFolder,
  readChanges,
  onOpenChanges,
  onSaveEnvironment,
  onShowCall,
  subagent,
  split = false,
  covered = false,
  onUncover,
  onBeforeOpen,
  beside,
  wide = false,
  onReconnectMcp,
  remoteControl,
  onCompact,
  onViewPrompt,
  onOpenChat,
  onShowUsage,
  onRender,
}: {
  snapshot: AcpmuxSnapshot;
  /// A view has the pane in the chat's place (App.tsx: a turn's diff in place, the event Inspector):
  /// the panel steps aside, its open state kept, and is back when that view closes.
  covered?: boolean;
  /// Closes that view: opening Session Info (its toggle, the palette, a running line's count)
  /// brings the chat back first.
  onUncover?: () => void;
  /// Clears a competing full-height view before any Session Info entry point opens it.
  onBeforeOpen?: () => void;
  /// The side panel beside the chat, changing as it opens or closes (App.tsx `artifact.opened`):
  /// the panel measures the chat's room without it.
  beside?: unknown;
  /// What the chat shows under its header is a handoff review's form, wider than the transcript's
  /// column (App.tsx): whether the panel lies over the chat is measured against the form. It never pushes.
  wide?: boolean;
  /// This Mac's name from the handshake, for a local chat.
  machineName?: string;
  /// The chat folder's GitHub repository (`git.githubRepository`), `owner/name`.
  repository?: string;
  /// Native says whether this pane has an authenticated Cloud repository route.
  cloudRepositoryAvailable?: boolean;
  /// The pane's shell: Session Info measures it to float or push.
  shell?: HTMLElement | null;
  /// What the chat was granted (folder trust, a chat-wide allowance), each revocable in Environment.
  grants?: readonly AccessGrant[];
  /// Opens a file's diff (App.tsx openOutput: beside the chat, else in place).
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  /// Opens a web address in the browser beside the chat (a server's port, a pull request).
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  /// A pasted image's bytes by its id, for its Sources row (direct.ts `promptImage`).
  readPromptImage?: (id: string) => Promise<string | undefined>;
  /// Opens a document the chat produced in the side panel beside the chat (App.tsx openArtifact).
  onOpenDocument?: (artifact: Artifact) => void;
  /// acpmux's background-process registry for the chat: the App's one (App.tsx `processRegistry`),
  /// which the running line and the summary card read too, so it is listed once.
  processes?: ProcessRegistry;
  /// `_acpmux/process/kill`.
  onStopProcess?: (id: string) => Promise<unknown>;
  subagents?: {
    views: Record<string, AcpmuxRow[]> | undefined;
    /// The tool calls the chat's open asks are about (SubagentStatusList.tsx `pendingToolCalls`).
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
  };
  /// The chats the chat's agent started (App.tsx `childSessions`), and how one opens.
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  /// `_acpmux/subsession/limits` (direct.ts setRunningLimit): chat `sessionId`'s running limit.
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  /// The chat's Claude workflows (Labs, App.tsx `workflows`), in Background tasks (WorkflowTasks.tsx).
  workflows?: {
    list: readonly WorkflowSummary[];
    onStop?: (id: string) => Promise<unknown>;
    onOpenAgent?: (agent: WorkflowAgent) => void;
  };
  /// Opens one of the chat's folders in the Files tree beside the chat (a chat on this Mac).
  onOpenFolder?: (path: string) => void;
  /// Reads the chat folder's git changes for Environment's Changes row (changeCounts.ts), with
  /// `onOpenChanges` opening the chat folder's diff beside the chat.
  readChanges?: ReadChanges;
  onOpenChanges?: () => void;
  /// Saves the chat's machine and folder as an environment (`environment.save`).
  onSaveEnvironment?: () => Promise<unknown>;
  /// Shows the Bash call that started a background command in the transcript (App.tsx `showToolRow`).
  onShowCall?: (toolCallId: string) => boolean;
  /// The subagent whose own view the pane shows: Session Info lists its things, not the chat's.
  subagent?: SubagentScope;
  /// The pane was opened beside another chat (a subagent's pane, a chat its agent started): its
  /// Session Info is its own and starts closed (sessionInfoState.ts `sessionInfoPaneKey`).
  split?: boolean;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Environment's Remote Control switch (App.tsx, remoteControl.ts): absent, no row.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Sends the chat's agent its `/compact` (Context's and Usage's Compact); unset where it cannot reach.
  onCompact?: () => void;
  /// Context's View Prompt: opens the Context screen (context/ContextScreen.tsx); unset for a chat
  /// whose prompt text acpmux does not hand this pane.
  onViewPrompt?: () => void;
  /// Opens any chat acpmux lists, this Mac's or a peer's (Usage's rows).
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  /// Test-only render probe for the transcript scroll isolation regression test.
  onRender?: () => void;
}): {
  on: boolean;
  /// The panel shows (on, open, not stepped aside): a card under it keeps no room of its own beside
  /// the chat (App.tsx, the computer use live preview).
  shown?: boolean;
  button?: ReactNode;
  panel?: ReactNode;
  // The native command palette shares the header's visibility and uncover behavior.
  toggle?: () => void;
  // Opens Session Info with `section` unfolded (the running line's counts: App.tsx).
  reveal?: (section: SessionInfoSectionId) => void;
} {
  const t = useT();
  const { sessionInfo: on, pullRequest, lit } = useHeaderState();
  // This pane's state is its chat's: a relaunched pane shows Session Info as it left it, and a
  // toggle in another pane never reaches it (sessionInfoState.ts).
  // The chat's state is read from its first frame (`useSessionInfoOpen(paneSession)`), before the bind,
  // and the panel is keyed by the chat, so a pane switched to another chat shows that chat's
  // Session Info at once instead of playing the last chat's panel out.
  const paneSession = sessionInfoPaneKey(snapshot.sessionId ?? snapshot.summary?.sessionId, split);
  useLayoutEffect(() => bindSessionInfoPane(paneSession), [paneSession]);
  // Open alone: the width and the folds are the panel's (SessionInfoPresence), so a drag step or a fold
  // does not draw the whole chat pane again.
  const open = useSessionInfoOpen(paneSession);
  // Closed for now (not remembered): an output's diff split left no room beside the chat.
  const [suppressed, setSuppressed] = useState(false);
  const suppress = useCallback(() => setSuppressed(true), []);
  // The person opened it in this pane (the toggle, a running line's count, the palette), not only a
  // saved state: a popover shows only then (SessionInfoPresence). Both are this chat's: a pane switched
  // to another chat starts unasked and unsuppressed, so that chat's saved open state never puts a
  // popover over it either.
  const [asked, setAsked] = useState(false);
  const [askedFor, setAskedFor] = useState(paneSession);
  if (askedFor !== paneSession) {
    setAskedFor(paneSession);
    setAsked(false);
    setSuppressed(false);
  }
  // Aside while what one of its rows opened shows (stepAside.ts): the folder, Changes, an output.
  const stepAside = useStepAside(lit, shell);
  const backFromAside = stepAside.cancel;
  // A subagent shown in this pane in place (no pane of its own opened): the panel follows it there.
  const scopeId = subagent?.agent.id;
  useEffect(() => backFromAside(), [scopeId, backFromAside]);
  // Lucas, 2026-11-06: "In a narrow layout: it becomes a popover and starts closed." (Every new chat
  // starts closed since Leo, 2026-11-07: sessionInfoState.ts.) A pane with no room for it beside a readable chat
  // (sessionInfoFits) holds it closed until the person opens it there (`asked`); opened, it is a
  // popover (SessionInfoPresence). One already showing as the pane narrows (a split opens beside it)
  // stays, as a popover; and once the pane has room again, the chat's own open choice shows.
  const narrow = useNarrowPane(shell, on, beside);
  const roomyShown = sessionInfoShown({ on, open, suppressed: suppressed || stepAside.aside, covered });
  const [narrowWas, setNarrowWas] = useState(narrow);
  if (narrowWas !== narrow) {
    setNarrowWas(narrow);
    // Narrowed while it showed: it stays (the first measure is a start, not a narrowing).
    if (narrow && narrowWas === false && roomyShown) setAsked(true);
    // Room again: a popover's click-away or a cramped moment no longer holds it.
    if (!narrow && narrowWas) setSuppressed(false);
  }
  const shown = roomyShown && !(narrow && !asked);
  // What the panel lists of the rows, read here as the pane renders, and what else it is handed,
  // each the same value while it holds the same things: the panel (SessionInfoPresence, memoized)
  // renders when what it shows changed, not on every pane render (bench/delta-renders.bench.ts).
  const lists = useSessionInfoLists({
    drawn: shown,
    snapshot,
    scope: subagent,
    repository,
    views: subagents?.views,
    registry,
    showsCalls: !!onShowCall,
  });
  const panelSnapshot = usePanelSnapshot(snapshot, lists.rows);
  const steadyGrants = useStableProps({ grants }).grants;
  const openSubagent = useStableCallback(subagents?.onOpen);
  const subagentViews = subagents?.views;
  const subagentAsks = subagents?.asks;
  const steadySubagents = useMemo(
    () =>
      subagentAsks && openSubagent ? { views: subagentViews, asks: subagentAsks, onOpen: openSubagent } : undefined,
    [subagentViews, subagentAsks, openSubagent],
  );
  // The section a running line's count asked for, scrolled to once drawn.
  const [revealed, setRevealed] = useState<{ section: SessionInfoSectionId; at: number }>();
  const clearRevealed = useCallback(() => setRevealed(undefined), []);
  const openedOutputAt = useRef(0);
  const stableOnOpenOutput = useStableCallback(onOpenOutput);
  const stableOnOpenSourceFile = useStableCallback(onOpenSourceFile);
  const stableOnOpenUrl = useStableCallback(onOpenUrl);
  const stableOnOpenImage = useStableCallback(onOpenImage);
  const stableReadPromptImage = useStableCallback(readPromptImage);
  const stableOnOpenDocument = useStableCallback(onOpenDocument);
  const stableOnOpenFolder = useStableCallback(onOpenFolder);
  const stableOnOpenChanges = useStableCallback(onOpenChanges);
  const stableOnSaveEnvironment = useStableCallback(onSaveEnvironment);
  const stableOnReconnectMcp = useStableCallback(onReconnectMcp);
  const stableOnCompact = useStableCallback(onCompact);
  const stableOnViewPrompt = useStableCallback(onViewPrompt);
  const stableOnOpenChat = useStableCallback(onOpenChat);
  const stableOnShowUsage = useStableCallback(onShowUsage);
  const stableOnShowCall = useStableCallback(onShowCall);
  const stableOnStopProcess = useStableCallback(onStopProcess);
  const openOutput = useMemo(
    () =>
      stableOnOpenOutput
        ? (path: string) => {
            openedOutputAt.current = Date.now();
            stableOnOpenOutput(path);
          }
        : undefined,
    [stableOnOpenOutput],
  );
  const label = t("sessionInfo.title");
  // Opening it while a view covers the chat closes that view first. The palette's opener outlives a
  // render, so it reads the latest from a ref.
  const bringBack = covered ? onUncover : undefined;
  const uncover = useRef(bringBack);
  useLayoutEffect(() => {
    uncover.current = bringBack;
  }, [bringBack]);
  useEffect(() => {
    if (!on) return;
    return registerPicker(label, () => {
      onBeforeOpen?.();
      uncover.current?.();
      setSuppressed(false);
      backFromAside();
      setAsked(true);
      setSessionInfoOpen(true);
    });
  }, [on, label, onBeforeOpen, backFromAside]);
  // Esc closes it while the keyboard is in it or on its toggle (not in a text field there), before a
  // popup in the page takes it (they listen on the window, after the document). Anywhere else Esc
  // keeps its own meaning: with nothing focused and a turn running it is the composer's double press
  // that stops the turn (escapeStop.ts), which an Esc claimed here never reaches. An open popover,
  // menu or dialog takes Esc first (as WidgetEditing.tsx): they listen on the document too, but after this.
  useEffect(() => {
    if (!shown) return;
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return;
      const focus = document.activeElement;
      if (!(focus instanceof HTMLElement) || !focus.closest(`aside.acpmux-session-info, ${SESSION_INFO_TOGGLE}`))
        return;
      if (focus.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])")) return;
      if (
        document.querySelector(
          'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], .ui-popup',
        )
      )
        return;
      event.preventDefault();
      closeSessionInfo();
    };
    document.addEventListener("keydown", escape);
    return () => document.removeEventListener("keydown", escape);
  }, [shown]);
  if (!on) return { on: false };
  const toggle = () => {
    if (shown) setSessionInfoOpen(false);
    else {
      onBeforeOpen?.();
      bringBack?.();
      setSuppressed(false);
      backFromAside();
      setAsked(true);
      setSessionInfoOpen(true);
    }
  };
  const reveal = (section: SessionInfoSectionId) => {
    onBeforeOpen?.();
    bringBack?.();
    setSuppressed(false);
    backFromAside();
    setAsked(true);
    setSessionInfoSection(section, true);
    setSessionInfoOpen(true);
    setRevealed({ section, at: Date.now() });
  };
  return {
    on: true,
    shown,
    toggle,
    reveal,
    button: <PanelToggle className="acpmux-session-info-toggle" label={label} shown={shown} onToggle={toggle} />,
    panel: (
      <SessionInfoPresence
        key={paneSession ?? ""}
        chat={paneSession}
        shown={shown}
        snapshot={panelSnapshot}
        lists={lists}
        pullRequest={pullRequest}
        machineName={machineName}
        repository={repository}
        cloudRepositoryAvailable={cloudRepositoryAvailable}
        shell={shell}
        grants={steadyGrants}
        beside={beside}
        wide={wide}
        openedOutputAt={openedOutputAt}
        asked={asked}
        onSuppress={suppress}
        onStepAside={stepAside.step}
        onStepBack={backFromAside}
        registry={registry}
        subagents={steadySubagents}
        sessions={sessions}
        onSetRunningLimit={onSetRunningLimit}
        workflows={workflows}
        revealed={revealed}
        onRevealed={clearRevealed}
        onStopProcess={stableOnStopProcess}
        onOpenSourceFile={subagent?.agent.host ? undefined : stableOnOpenSourceFile}
        onOpenOutput={openOutput}
        onOpenUrl={stableOnOpenUrl}
        onOpenImage={stableOnOpenImage}
        // A subagent's prompt images live in its own chat, which this reader does not reach.
        readPromptImage={subagent ? undefined : stableReadPromptImage}
        onOpenFolder={stableOnOpenFolder}
        readChanges={subagent ? undefined : readChanges}
        onOpenChanges={subagent ? undefined : stableOnOpenChanges}
        onSaveEnvironment={stableOnSaveEnvironment}
        onReconnectMcp={stableOnReconnectMcp}
        remoteControl={remoteControl}
        onCompact={stableOnCompact}
        onViewPrompt={stableOnViewPrompt}
        onOpenChat={stableOnOpenChat}
        onShowUsage={stableOnShowUsage}
        onRender={onRender}
        onOpenDocument={stableOnOpenDocument}
        onShowCall={stableOnShowCall}
        scope={subagent}
      />
    ),
  };
}

/// What Session Info lists of the rows, each kept while it holds the same things (sameValue.ts).
/// Read as the pane renders (useSessionInfo), not in the panel: a snapshot is new objects on every
/// update, a running command's output among them, and the panel (SessionInfoPresence, memoized)
/// then renders only when one of these changed, not once per update. Read while the panel shows
/// (`drawn`); hidden, the last reading stands, so a panel playing out keeps what it showed.
export type SessionInfoLists = {
  readonly summary: AcpmuxSnapshot["summary"];
  readonly made: SessionSummary | undefined;
  readonly links: readonly OutputLink[];
  /// The pull requests, issues and commits the chat produced (producedLinks.ts).
  readonly produced: readonly ProducedLink[];
  readonly outputFiles: OutputFile[];
  readonly scopedPlan: SessionInfoPlan | undefined;
  readonly artifacts: number;
  readonly documents: readonly OutputArtifact[];
  readonly agents: readonly Subagent[];
  readonly transcriptTasks: ReturnType<typeof withChatEnds> | undefined;
  readonly processes: readonly SessionInfoProcess[] | undefined;
  readonly toolCalls: ReadonlySet<string> | undefined;
  /// The rows the sections read for the chat's gallery (`SessionInfoSections` `rows`).
  readonly rows: readonly AcpmuxRow[];
  readonly rowCount: number;
};

function useSessionInfoLists({
  drawn,
  snapshot,
  scope,
  repository,
  views,
  registry,
  showsCalls,
}: {
  drawn: boolean;
  snapshot: AcpmuxSnapshot;
  scope?: SubagentScope;
  repository?: string;
  views: Record<string, AcpmuxRow[]> | undefined;
  registry?: ProcessRegistry;
  /// A task row's Show call is offered (`onShowCall`).
  showsCalls: boolean;
}): SessionInfoLists {
  const rows = scope?.rows ?? snapshot.rows;
  const scopedAgent = scope?.agent;
  const summary = useSameValue(
    useMemo(
      () => (drawn && scopedAgent ? subagentSummary(snapshot.summary, scopedAgent, rows) : snapshot.summary),
      [drawn, scopedAgent, snapshot.summary, rows],
    ),
  );
  const made = useSameValue(
    useMemo(
      () => (drawn ? sessionSummary(rows, repository ?? null, summary?.cwd) : undefined),
      [drawn, rows, repository, summary?.cwd],
    ),
  );
  const links = useSameValue(useMemo(() => (drawn ? outputLinks(rows) : []), [drawn, rows]));
  // The pull requests, issues and commits the chat produced (producedLinks.ts), kept while they are the
  // same, so a streamed token draws no section for them.
  const produced = useSameValue(
    useMemo(() => (drawn ? producedLinks(rows, repository) : NO_PRODUCED), [drawn, rows, repository]),
  );
  // What the chat made for the person (chatOutputs.ts), read here beside `made` and kept while it is the
  // same files, so the sections need not read the rows for it.
  const outputFiles = useSameValue(
    useMemo(() => (drawn ? chatOutputs(rows, summary?.cwd) : NO_OUTPUT_FILES), [drawn, rows, summary?.cwd]),
  );
  const scopedWorking = scopedAgent?.state === "running";
  const scopedPlan = useSameValue(
    useMemo(
      () => (drawn && scopedAgent ? currentPlan(rows, scopedWorking) : undefined),
      [drawn, scopedAgent, rows, scopedWorking],
    ),
  );
  // The chat's gallery, kept while it holds the same items (sameValue: each item's kind, key, source and
  // render call), so a replaced image or render with the same count is a new gallery, and a streamed
  // token that changes none of it is the same one. Its pass is over the gallery's items, not the rows'
  // text: chatGallery keeps each unchanged row's images and calls (its WeakMaps).
  const gallery = useSameValue(useMemo(() => (drawn ? chatGallery(rows) : NO_GALLERY), [drawn, rows]));
  const artifacts = gallery.length;
  const documents = useSameValue(useMemo(() => (drawn ? outputArtifacts(rows) : []), [drawn, rows]));
  const scopedAgents = scope?.agents;
  const agents = useSameValue(
    useMemo(
      () => (drawn ? (scopedAgents ?? [...subagentsIn(rows, views).values()]) : []),
      [drawn, scopedAgents, rows, views],
    ),
  );
  const chatRows = snapshot.rows;
  const transcriptTasks = useSameValue(
    useMemo(
      () => (scope && made ? withChatEnds(made.backgroundTasks, chatRows) : made?.backgroundTasks),
      [scope, made, chatRows],
    ),
  );
  const allProcesses = registry?.processes;
  const processes = useSameValue(
    useMemo(
      () => (drawn && scope && allProcesses ? subagentProcesses(allProcesses, rows) : allProcesses),
      [drawn, scope, allProcesses, rows],
    ),
  );
  // The tool calls the loaded transcript holds, for a task row's Show call in a chat whose terminal
  // cannot open here, and for a wakeup or cron job, which shows the call that made it on any chat:
  // read here, so a call added to an existing row reaches the sections, and kept while it is the same
  // set. A chat on this Mac with nothing scheduled opens its terminals instead and reads none.
  const readsCalls = showsCalls && (!opensProcessTerminal(summary) || (made?.scheduled?.length ?? 0) > 0);
  const toolCalls = useSameValue(
    useMemo(() => (drawn && readsCalls ? toolCallIds(rows) : undefined), [drawn, readsCalls, rows]),
  );
  // The rows the sections read for the chat's gallery (its items: `gallery`), whether it has any, and
  // the tool calls they show where `toolCalls` is not read: the same rows until the chat has rows or
  // none, any item of its gallery or what it made changes (a replaced image or render at the same count
  // too: review of cmux#37907 at 6c29ca42, P1), a turn starts or ends, or the panel lists another agent.
  // Not each streamed token's copy, and not each row added: a tool call that makes nothing the panel
  // shows draws none of it (Outputs reads `outputFiles`, Tasks reads `toolCalls`). Another chat's
  // rows are always new: the panel outlives a chat switch, and B must never show A's images.
  const chat = snapshot.sessionId;
  const listing = scope?.agent.id;
  const working = snapshot.isWorking;
  const any = rows.length > 0;
  const galleryRows = useRef({ rows, chat, any, gallery, listing, working, outputFiles, toolCalls });
  if (
    galleryRows.current.chat !== chat ||
    galleryRows.current.any !== any ||
    galleryRows.current.gallery !== gallery ||
    galleryRows.current.listing !== listing ||
    galleryRows.current.working !== working ||
    galleryRows.current.outputFiles !== outputFiles ||
    galleryRows.current.toolCalls !== toolCalls
  )
    galleryRows.current = { rows, chat, any, gallery, listing, working, outputFiles, toolCalls };
  const sectionRows = galleryRows.current.rows;
  const rowCount = rows.length;
  const lists = useMemo<SessionInfoLists>(
    () => ({
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
    }),
    [
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
      sectionRows,
      rowCount,
    ],
  );
  const held = useRef(lists);
  if (drawn) held.current = lists;
  return held.current;
}

/// The snapshot Session Info's panel reads: `rows` in place of its own (the sections' rows,
/// useSessionInfoLists), and the one given last while every other field is the same object. The
/// client keeps a field's object while it does not change (direct.ts), so a running command's output
/// update, which changes only the rows, hands the panel the same snapshot.
function usePanelSnapshot(snapshot: AcpmuxSnapshot, rows: readonly AcpmuxRow[]): AcpmuxSnapshot {
  const held = useRef<{ source: AcpmuxSnapshot; value: AcpmuxSnapshot } | undefined>(undefined);
  const before = held.current;
  if (before && before.value.rows === rows && sameButRows(before.source, snapshot)) return before.value;
  const value = rows === snapshot.rows ? snapshot : { ...snapshot, rows: rows as AcpmuxRow[] };
  held.current = { source: snapshot, value };
  return value;
}

/// Every own field of the two snapshots is the same object, except `rows`.
function sameButRows(previous: AcpmuxSnapshot, next: AcpmuxSnapshot): boolean {
  if (previous === next) return true;
  const before = previous as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  return (
    keys.length === Object.keys(before).length &&
    keys.every((key) => key === "rows" || (key in before && Object.is(before[key], after[key])))
  );
}

/// Keep event props stable while retaining the latest callback. The pane owns transcript scroll
/// state, so a fresh inline callback would defeat the SessionInfoPresence memo.
function useStableCallback<T extends (...args: never[]) => unknown>(callback: T | undefined): T | undefined {
  const current = useRef<T | undefined>(callback);
  current.current = callback;
  const enabled = callback !== undefined;
  return useMemo(
    () => (enabled ? (((...args: Parameters<T>) => current.current?.(...args)) as T) : undefined),
    [enabled],
  );
}

/// Closes Session Info from Esc and gives the keyboard to its header toggle, so focus is
/// not dropped on the page when the panel it was in leaves. Over a diff in place the header, and the
/// toggle with it, is hidden and cannot take focus: the page gets it, as before.
const closeSessionInfo = () => {
  document.querySelector<HTMLElement>(SESSION_INFO_TOGGLE)?.focus({ preventScroll: true });
  setSessionInfoOpen(false);
};

/// No files made (a stable value, so the sections' memo holds).
const NO_OUTPUT_FILES: ReturnType<typeof chatOutputs> = [];
/// No gallery items (a stable value, so the gallery rows hold while the panel is hidden).
const NO_GALLERY: readonly GalleryItem[] = [];
/// Nothing produced (a stable value, so the sections' memo holds).
const NO_PRODUCED: readonly ProducedLink[] = [];

/// Session Info while it is drawn: its presence, its width and folds, whether it floats or pushes,
/// and what it lists. Its own component, so its enter and exit phases, a drag step and a fold draw the panel
/// alone, not the chat pane that calls useSessionInfo (one Session Info open drew that pane five
/// times in a frame).
const SessionInfoPresence = memo(function SessionInfoPresence({
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
  remoteControl,
  onCompact,
  onViewPrompt,
  onOpenChat,
  onShowUsage,
  onRender,
  onOpenDocument,
  onShowCall,
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
  useLayoutEffect(() => {
    if (!drawn || paneWidth <= 0) return;
    if (!asked && sessionInfoPopover(paneHeight, overChat)) onSuppress();
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
    if (shell.querySelector(".acpmux-find__bar")) {
      if (asked) shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(FIND_HIDE_EVENT));
      else onSuppress();
    }
    shell.addEventListener(FIND_OPEN_EVENT, away);
    return () => shell.removeEventListener(FIND_OPEN_EVENT, away);
  }, [shell, drawn, cramped, asked, onSuppress]);
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
        <NativeSessionInfo
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
        remoteControl={scope ? undefined : remoteControl}
        // Compact ends the chat's context, not a subagent's.
        onCompact={scope ? undefined : onCompact}
        onViewPrompt={scope ? undefined : onViewPrompt}
        onOpenDocument={onOpenDocument}
        onShowCall={onShowCall}
      />
    </MemoSessionInfoPanel>
  );
});
