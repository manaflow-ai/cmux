import { useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useChatDisplay } from "../chatDisplay";
import { PanelToggle } from "../header/PanelToggle";
import { useHeaderState } from "../header/headerState";
import { useT } from "../i18n";
import { type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { registerPicker, ChatViewParked } from "../pickerOpeners";
import { opensProcessTerminal } from "../processTerminal";
import { chatGallery, type GalleryItem } from "../summary/chatGallery";
import { sessionSummary, type SessionSummary } from "../summary/sessionSummary";
import type { Artifact } from "../conversation/artifactPreview";
import type { StartedSession } from "../started/startedSessions";
import { type AccessGrant } from "./EnvironmentSection";
import type { SessionInfoCloudControl } from "../hybrid/SessionInfoCloud";
import { subagentProcesses, subagentSummary, withChatEnds, type SubagentScope } from "./subagentScope";
import {
  bindSessionInfoPane,
  sessionInfoPaneKey,
  setSessionInfoOpen,
  setSessionInfoSection,
  useSessionInfoOpen,
  type SessionInfoSectionId,
} from "./sessionInfoState";
import { outputArtifacts, outputLinks, type OutputArtifact, type OutputLink } from "./outputsSectionModel";
import { chatOutputs, type OutputFile } from "./chatOutputs";
import { producedLinks, type ProducedLink } from "./producedLinks";
import { type ProcessRegistry, type SessionInfoProcess } from "./processes";
import type { WorkflowAgent, WorkflowSummary } from "../summary/workflow";
import { useSameValue } from "./sameValue";
import {
  inlines,
  sessionInfoFits,
  sessionInfoShown,
  paneRoom,
  SESSION_INFO_TOGGLE,
  toolCallIds,
} from "./sessionInfoModel";
import { subagentsIn } from "../subagents/subagentRows";
import type { Subagent } from "../subagents/subagentFold";
import type { ResumeActions } from "../subagents/ResumeControl";
import { useStableProps } from "../stableProps";
import { type ReadChanges } from "./changeCounts";
import { useStepAside } from "./stepAside";
import { SessionInfoPresence } from "./SessionInfoPresence";
import { useStableCallback } from "./useStableCallback";

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
  onRemoveFolder,
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
  onShowTurn,
  subagent,
  split = false,
  covered = false,
  onUncover,
  onBeforeOpen,
  beside,
  wide = false,
  onReconnectMcp,
  remoteControl,
  cloud,
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
  onRemoveFolder?: (path: string) => Promise<unknown> | unknown;
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
    /// Resume on a stopped subagent's line (subagents/ResumeControl.tsx): the chat's `resumeAgent`.
    resume?: ResumeActions;
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
  onShowTurn?: (turnId: string) => void;
  /// The subagent whose own view the pane shows: Session Info lists its things, not the chat's.
  subagent?: SubagentScope;
  /// The pane was opened beside another chat (a subagent's pane, a chat its agent started): its
  /// Session Info is its own and starts closed (sessionInfoState.ts `sessionInfoPaneKey`).
  split?: boolean;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Environment's Remote Control switch (App.tsx, remoteControl.ts): absent, no row.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Environment's cloud controls (hybrid/HybridMounts.tsx), in Remote Control's place.
  cloud?: SessionInfoCloudControl;
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
  // stays, as a popover.
  // A resize never opens it (Leo, 2026-11-10: "It's the resizing of the window itself, potentially...
  // Like the size of the window itself being resized or whatever. Maybe making a new workspace."):
  // once a narrow pane held it closed (`held`), it stays closed when the pane gets room again, and
  // anything that put it aside for now (`suppressed`: a popover's click-away, Find's bar, a diff split)
  // keeps it aside however wide the pane gets. Only the person brings it back (`asked`). A resize never
  // closes one that shows either: narrower, it stays as a popover; shorter, too (SessionInfoPresence);
  // and where Find's bar then has no room, the bar steps aside. The chat's saved open choice is kept as
  // it was: a resize changes nothing saved.
  // Inline (Settings placement `inline`), it is a band atop the transcript: any pane holds it, so no
  // narrow pane holds it closed.
  const inline = inlines(useChatDisplay().sessionInfo);
  const measuredNarrow = useNarrowPane(shell, on && !inline, beside);
  const narrow = inline ? false : measuredNarrow;
  const roomyShown = sessionInfoShown({ on, open, suppressed: suppressed || stepAside.aside, covered });
  const [narrowWas, setNarrowWas] = useState(narrow);
  // The chats this pane held closed, kept while the page lives: switching to another chat and back
  // does not bring a held panel back either. The person's open (`ask`) lets it go.
  const [heldChats, setHeldChats] = useState<ReadonlySet<string>>(NO_HELD_CHATS);
  const heldKey = paneSession ?? "";
  const held = heldChats.has(heldKey);
  // Shown at a width: asked for, or saved open where it has room and no narrow pane held it.
  const shownAt = (isNarrow: boolean | undefined) => roomyShown && (asked || (!isNarrow && !held));
  // Narrowed while it showed: it stays (the first measure is a start, not a narrowing). One held
  // closed is not showing, so narrowing again leaves it closed.
  const keeps = narrow === true && narrowWas === false && shownAt(false);
  if (narrowWas !== narrow) {
    setNarrowWas(narrow);
    if (keeps) setAsked(true);
  }
  // Held only where it would show: one aside for a view its row opened, covered, closed, or kept as
  // the pane narrowed is not.
  if (narrow && !asked && !keeps && !held && roomyShown) setHeldChats(new Set(heldChats).add(heldKey));
  const shown = shownAt(narrow);
  // The person opens it here (the toggle, the palette, a running line's count).
  const ask = useCallback(() => {
    setAsked(true);
    setHeldChats((chats) => {
      if (!chats.has(heldKey)) return chats;
      const next = new Set(chats);
      next.delete(heldKey);
      return next;
    });
  }, [heldKey]);
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
  // Resume keeps one identity while the chat's capabilities do: the chat's `resumeAgent` is made
  // again with its turn actions, and the panel draws only when what it is handed changes.
  const resumeAgent = useStableCallback(subagents?.resume?.resumeAgent);
  const resumeCapabilities = subagents?.resume?.retryCapabilities;
  const steadySubagents = useMemo(
    () =>
      subagentAsks && openSubagent
        ? {
            views: subagentViews,
            asks: subagentAsks,
            onOpen: openSubagent,
            ...(resumeAgent && { resume: { resumeAgent, retryCapabilities: resumeCapabilities } }),
          }
        : undefined,
    [subagentViews, subagentAsks, openSubagent, resumeAgent, resumeCapabilities],
  );
  // The section a running line's count asked for, scrolled to once drawn.
  const [revealed, setRevealed] = useState<{ section: SessionInfoSectionId; at: number }>();
  const clearRevealed = useCallback(() => setRevealed(undefined), []);
  const openedOutputAt = useRef(0);
  const stableOnOpenOutput = useStableCallback(onOpenOutput);
  const stableOnOpenSourceFile = useStableCallback(onOpenSourceFile);
  const stableOnRemoveFolder = useStableCallback(onRemoveFolder);
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
  const stableOnShowTurn = useStableCallback(onShowTurn);
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
  const parked = useContext(ChatViewParked);
  useEffect(() => {
    if (!on || parked) return;
    return registerPicker(label, () => {
      onBeforeOpen?.();
      uncover.current?.();
      setSuppressed(false);
      backFromAside();
      ask();
      setSessionInfoOpen(true);
    });
  }, [on, parked, label, onBeforeOpen, backFromAside, ask]);
  // Esc closes it while the keyboard is in it or on its toggle (not in a text field there), before a
  // popup in the page takes it (they listen on the window, after the document). Anywhere else Esc
  // keeps its own meaning: with nothing focused and a turn running it is the composer's double press
  // that stops the turn (escapeStop.ts), which an Esc claimed here never reaches. An open popover,
  // menu or dialog takes Esc first: they listen on the document too, but after this.
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
      ask();
      setSessionInfoOpen(true);
    }
  };
  const reveal = (section: SessionInfoSectionId) => {
    onBeforeOpen?.();
    bringBack?.();
    setSuppressed(false);
    backFromAside();
    ask();
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
        onRemoveFolder={subagent?.agent.host ? undefined : stableOnRemoveFolder}
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
        cloud={cloud}
        onCompact={stableOnCompact}
        onViewPrompt={stableOnViewPrompt}
        onOpenChat={stableOnOpenChat}
        onShowUsage={stableOnShowUsage}
        onRender={onRender}
        onOpenDocument={stableOnOpenDocument}
        onShowCall={stableOnShowCall}
        onShowTurn={stableOnShowTurn}
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

/// Closes Session Info from Esc and gives the keyboard to its header toggle, so focus is
/// not dropped on the page when the panel it was in leaves. Over a diff in place the header, and the
/// toggle with it, is hidden and cannot take focus: the page gets it, as before.
const closeSessionInfo = () => {
  document.querySelector<HTMLElement>(SESSION_INFO_TOGGLE)?.focus({ preventScroll: true });
  setSessionInfoOpen(false);
};

/// No chat held closed yet (a stable value).
const NO_HELD_CHATS: ReadonlySet<string> = new Set();

/// No files made (a stable value, so the sections' memo holds).
const NO_OUTPUT_FILES: ReturnType<typeof chatOutputs> = [];
/// No gallery items (a stable value, so the gallery rows hold while the panel is hidden).
const NO_GALLERY: readonly GalleryItem[] = [];
/// Nothing produced (a stable value, so the sections' memo holds).
const NO_PRODUCED: readonly ProducedLink[] = [];
