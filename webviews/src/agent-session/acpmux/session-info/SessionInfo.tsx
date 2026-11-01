// Session Info: the right-hand panel of an agent chat, Chief included, opened by the header's
// top-right toggle (Claude Code desktop calls its own the session rail, ChatGPT its pinned
// summary). Leo, 2026-10-20: take the facts Claude Code's panel shows and ChatGPT's subagents row.
// Top to bottom, in three blocks with no box around a section (`RAIL_LAYOUT`):
//
// - Where it runs: the Environment's rows, the machine, the folder, the repository, the branch or
//   worktree (EnvironmentSection); then Context, how much of the context window the chat used, with a
//   bar, open the token counts; then Connectors, the MCP servers its harness loaded, with how many
//   need reconnecting, each failed one with a Reconnect where acpmux reconnects it (ConnectorsSection).
//   Context and Connectors are one row each until opened.
// - What it made: Changes, the pull requests it opened, touched or named, in any repository
//   (ChangesSection); Outputs, the files, artifacts and links it produced (OutputsSection).
// - What it runs: Subagents, each running subagent and started chat on its own line, the ended ones
//   folded into one row: the harness's subagents and the chats its agent started, a Cloud VM's or
//   another machine's included (SubagentsSection); Background tasks, the dev servers it runs first
//   (ServersSection), then its other background commands, the ones only the transcript knows
//   included, and its wakeups (TasksSection).
//
// Open, it floats under the header's toggle in the pane's right gutter, beside the transcript's
// centered column, so opening, closing or updating it never moves or reflows the chat. When that
// gutter has no room for it, it floats over the chat and stops above the composer (Leo, 2026-10-29:
// "it's not supposed to be a fucking sidebar that pushes the fucking layout"). Settings > Agent Chat >
// Session Info: Push always pushes.
// It shows only over the chat, where its toggle is: while a view takes the pane in the chat's place
// (a turn's diff in place, the event Inspector) it steps aside and comes back when that view closes,
// and with the side panel open beside the chat it floats in the chat's gutter, never over the
// document (Leo, 2026-10-22: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING
// CLOSABLE!?"). Its left edge drags to resize it. Open, width and folds are each pane's own
// (Leo, 2026-10-25: "they should all be individual per pane"), kept under the chat's session
// (sessionInfoState.ts). Debug Settings `agent.inspector` (on by default)
// turns it off, which brings back the summary card it replaces (summary/SummaryCard.tsx). It reads
// only acpmux's common snapshot and the App's header state, never one harness's own fields.
// While the pane shows a subagent's own view, it lists that subagent's things alone, under
// "Subagent · <name>" with a back button (subagentScope.ts, SubagentScopeHeader.tsx).
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { flushSync } from "react-dom";
import { usePresence, type Presence } from "../../../ui/presence";
import { useChatDisplay } from "../chatDisplay";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatSizing, type ChatColumn } from "../chatWidth";
import { PanelToggle } from "../header/PanelToggle";
import { useHeaderState, type HeaderPullRequest } from "../header/headerState";
import { useTabRow } from "../header/tabRow";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { transcriptColumn, type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { registerPicker } from "../pickerOpeners";
import { opensProcessTerminal } from "../processTerminal";
import { tooltipProps } from "../shortcuts";
import { subagentsIn } from "../subagents/subagentRows";
import { chatGallery } from "../summary/chatGallery";
import { GalleryDialog } from "../summary/GalleryDialog";
import { sessionSummary, type SessionSummary, type SummaryBackgroundTask } from "../summary/sessionSummary";
import { waitingSubagents } from "../summary/SubagentStatusList";
import type { Artifact } from "../conversation/artifactPreview";
import type { TurnFile } from "../diff";
import type { StartedSession } from "../started/startedSessions";
import { ChangesSection, headerStatus, visibleChanges, type SessionInfoPullRequestStatus } from "./ChangesSection";
import { useChangesStatuses, useStableUrls, withHeader } from "./changesStatus";
import { ConnectorsSection } from "./ConnectorsSection";
import { ContextSection } from "./ContextSection";
import { EnvironmentSection, type ProjectRowLook } from "./EnvironmentSection";
import { SessionInfoSectionList } from "./SessionInfoGroup";
import { SessionInfoSection } from "./SessionInfoSection";
import { SourcesSection } from "./SourcesSection";
import { SUBAGENT_HEADER, SubagentBanner, SubagentTitle } from "./SubagentScopeHeader";
import { subagentProcesses, subagentSummary, withChatEnds, type SubagentScope } from "./subagentScope";
import {
  bindSessionInfoPane,
  SESSION_INFO_WIDTH,
  setSessionInfoOpen,
  setSessionInfoSection,
  setSessionInfoSourcesAll,
  setSessionInfoWidth,
  useSessionInfoOpen,
  useSessionInfoState,
  type SessionInfoSectionId,
  type SessionInfoSections,
} from "./sessionInfoState";
import { OutputsSection, outputArtifacts, outputLinks, type OutputArtifact, type OutputLink } from "./OutputsSection";
import { sessionInfoLists, type SessionInfoProcess, type ProcessRegistry } from "./processes";
import { ServersSection } from "./ServersSection";
import { SubagentLimitStepper } from "./SubagentLimitStepper";
import { SubagentsSection, subagentCounts } from "./SubagentsSection";
import { TasksSection } from "./TasksSection";
import { WorkflowTasks, type WorkflowAgentRowVariant } from "./WorkflowTasks";
import { UsageSection, usageMeta } from "./UsageSection";
import type { AcpmuxSessionEntry } from "../sessionList";
import type { WorkflowAgent, WorkflowSummary } from "../summary/workflow";
import type { Subagent } from "../subagents/subagentFold";
import { subagentProgress } from "../subagents/subagentProgress";
import { useUnderSessionInfo } from "./underSessionInfo";
import "./sessionInfo.css";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
export type SessionInfoPlacement = "push" | "overlay";

/// The narrowest chat Session Info pushes aside: a pushed panel narrows to keep it, down to the
/// panel's own narrowest width.
export const PUSH_MIN_CHAT = 440;
/// The room the panel keeps from the pane's right edge, floating or pushing, and from the
/// transcript's column when it floats (sessionInfo.css --acpmux-session-info-inset).
export const FLOAT_MARGIN = 8;
/// How long after an output click a narrowing counts as that diff's split.
const SPLIT_SETTLE_MS = 2000;

/// Whether Session Info pushes the chat: only with Settings Push always. By default it floats
/// outside the pane's layout and never takes a column (Leo, 2026-10-24: "it was never supposed to be
/// a sidebar; y'all kept doing sidebars").
export const pushes = (placement: SessionInfoPlacement) => placement === "push";

/// A pushed panel's width: its own, narrowed so the chat keeps PUSH_MIN_CHAT beside it and its
/// right margin, down to the panel's narrowest.
export const pushedWidth = (paneWidth: number, width: number) =>
  paneWidth <= 0 ? width : Math.min(width, Math.max(SESSION_INFO_WIDTH.min, paneWidth - PUSH_MIN_CHAT - FLOAT_MARGIN));

/// A handoff review's form (handoff/styles.css: 760px, 18px from each edge) takes the transcript's
/// place and is wider than the column.
export const HANDOFF_FORM_WIDTH = 760;
/// The form's clearance from each pane edge (handoff/styles.css `min(760px, calc(100% - 36px))`).
export const HANDOFF_FORM_EDGE = 18;
/// The floating panel's right gutter: the transcript's (model.ts transcriptColumn), or with `wide` the
/// handoff review form's.
const gutterOf = (paneWidth: number, column?: ChatColumn, wide = false) => {
  const columnInset = transcriptColumn(paneWidth, column).inset;
  return wide
    ? Math.min(columnInset, (paneWidth - Math.min(HANDOFF_FORM_WIDTH, paneWidth - 2 * HANDOFF_FORM_EDGE)) / 2)
    : columnInset;
};

/// Whether the floating panel lies over the chat's column: the right gutter cannot hold it and its
/// margins. Opening it never moves the chat (Leo, 2026-10-29: "it's not supposed to be a fucking
/// sidebar that pushes the fucking layout"), so then the card, full length otherwise, stops above the
/// composer's stack so it never covers the composer.
export const sessionInfoOverChat = (paneWidth: number, width: number, column?: ChatColumn, wide = false) => {
  if (paneWidth <= 0 || width <= 0) return false;
  return width + 2 * FLOAT_MARGIN > gutterOf(paneWidth, column, wide);
};

/// Below this pane height, a panel that lies over the chat is a popover: it hides when a click lands
/// anywhere else, and while it shows it covers the composer instead of stopping above it. A taller pane
/// keeps the card above the composer, its foot following the composer's top with an animation
/// (sessionInfo.css), never a jump (Leo, 2026-10-31: "THE FACT THIS SHIT FUCKING EXPANDS WHEN THE
/// COMPOSER GROWS OR SHRINKS IS... ok i guess but i feel like should have an animation... sometimes
/// the claude code/chatgpt desktop just straight up make it a popover that hides when you click away
/// when the viewport is indeed too small"). It reads the pane's height alone, never the composer's, so
/// typing a long draft never switches the panel between the two.
export const POPOVER_BELOW_HEIGHT = 520;

/// Whether the floating panel is a popover (POPOVER_BELOW_HEIGHT): it lies over the chat in a short pane.
export const sessionInfoPopover = (paneHeight: number, overChat: boolean) =>
  overChat && paneHeight > 0 && paneHeight < POPOVER_BELOW_HEIGHT;

/// Whether Session Info shows: on (Debug Settings `agent.inspector`), open (the viewer's, in every
/// chat tab), not stepped aside for a diff split, and only over the chat: never while a view takes
/// the pane in its place (`covered`: a turn's diff in place hides the header, and the toggle with it).
export const sessionInfoShown = ({
  on,
  open,
  suppressed = false,
  covered = false,
}: {
  on: boolean;
  open: boolean;
  suppressed?: boolean;
  covered?: boolean;
}) => on && open && !suppressed && !covered;

/// The side panel beside the chat (conversation/ArtifactPanel.tsx), a child of the pane's shell, or
/// the Background tasks column (backgroundTasks/BackgroundTasksPanel.tsx), which docks under it or
/// stands in its place at the same width.
const SIDE_PANEL = ":scope > .acpmux-artifact, :scope > .acpmux-bg";

/// Session Info starts right below the header: the pane's tab row when the header is in it.
export function sessionInfoTopOffset(tabRowHeight: number): string {
  return tabRowHeight > 0 ? `${tabRowHeight}px` : "var(--acpmux-header-height, 28px)";
}

/// The composer's stack height (`.acpmux-dock` in `shell`) while `on`: from the top of its highest
/// child to the shell's foot. A new chat's dock is `display: contents` (bottomStack.css), so its own
/// box is empty and only its children have one. One ResizeObserver on the dock and its children (a
/// MutationObserver re-observes when its children change), both disconnected when `on` goes false or
/// the shell changes.
function useDockHeight(shell: HTMLElement | null | undefined, on: boolean): number {
  const [height, setHeight] = useState(0);
  useLayoutEffect(() => {
    const dock = on ? shell?.querySelector<HTMLElement>(".acpmux-dock") : null;
    if (!shell || !dock) return;
    const read = () => {
      let top = Infinity;
      for (const part of [dock, ...dock.children]) {
        const box = part.getBoundingClientRect();
        if (box.height > 0) top = Math.min(top, box.top);
      }
      setHeight(top === Infinity ? 0 : Math.max(0, Math.round(shell.getBoundingClientRect().bottom - top)));
    };
    const resize = new ResizeObserver(read);
    const observe = () => {
      resize.disconnect();
      resize.observe(dock);
      for (const child of dock.children) resize.observe(child);
    };
    observe();
    read();
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

/// The chat's room in the pane: the pane's width less the side panel's beside the chat, and that
/// panel's width, which the floating Session Info keeps clear of.
export type PaneRoom = { width: number; side: number; height: number };
const UNMEASURED: PaneRoom = { width: 0, side: 0, height: 0 };
export function paneRoom(shell: HTMLElement): PaneRoom {
  const side = shell.querySelector<HTMLElement>(SIDE_PANEL)?.offsetWidth ?? 0;
  return { width: Math.max(0, shell.clientWidth - side), side, height: shell.clientHeight };
}

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

/// How long a revealed section stays lit.
const REVEAL_LIT_MS = 1200;

/// The header's toggle and Session Info for the chat's pane. `on` is Debug Settings
/// `agent.inspector`: off, there is neither, and the App shows its summary card instead.
export function useSessionInfo({
  snapshot,
  machineName,
  repository,
  shell,
  onOpenOutput,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  onOpenDocument,
  processes: registry,
  onStopProcess,
  subagents,
  sessions,
  onSetRunningLimit,
  workflows,
  onOpenFolder,
  onSaveEnvironment,
  onShowCall,
  subagent,
  covered = false,
  onUncover,
  onBeforeOpen,
  beside,
  wide = false,
  onReconnectMcp,
  remoteControl,
  onCompact,
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
  /// The pane's shell: Session Info measures it to float or push.
  shell?: HTMLElement | null;
  /// Opens a file's diff (App.tsx openOutput: beside the chat, else in place).
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  /// Opens a web address in the browser beside the chat (a server's port, a pull request).
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
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
  /// Saves the chat's machine and folder as an environment (`environment.save`).
  onSaveEnvironment?: () => Promise<unknown>;
  /// Shows the Bash call that started a background command in the transcript (App.tsx `showToolRow`).
  onShowCall?: (toolCallId: string) => boolean;
  /// The subagent whose own view the pane shows: Session Info lists its things, not the chat's.
  subagent?: SubagentScope;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Environment's Remote Control switch (App.tsx, remoteControl.ts): absent, no row.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Sends the chat's agent its `/compact` (Context's and Usage's Compact); unset where it cannot reach.
  onCompact?: () => void;
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
  const { sessionInfo: on, pullRequest } = useHeaderState();
  // This pane's state is its chat's: a relaunched pane shows Session Info as it left it, and a
  // toggle in another pane never reaches it (sessionInfoState.ts).
  // The chat's state is read from its first frame (`useSessionInfoOpen(paneSession)`), before the bind,
  // and the panel is keyed by the chat, so a pane switched to another chat shows that chat's
  // Session Info at once instead of playing the last chat's panel out.
  const paneSession = snapshot.sessionId ?? snapshot.summary?.sessionId;
  useLayoutEffect(() => bindSessionInfoPane(paneSession), [paneSession]);
  // Open alone: the width and the folds are the panel's (SessionInfoPresence), so a drag step or a fold
  // does not draw the whole chat pane again.
  const open = useSessionInfoOpen(paneSession);
  // Closed for now (not remembered): an output's diff split left no room beside the chat.
  const [suppressed, setSuppressed] = useState(false);
  const suppress = useCallback(() => setSuppressed(true), []);
  const shown = sessionInfoShown({ on, open, suppressed, covered });
  // The section a running line's count asked for, scrolled to once drawn.
  const [revealed, setRevealed] = useState<{ section: SessionInfoSectionId; at: number }>();
  const clearRevealed = useCallback(() => setRevealed(undefined), []);
  const openedOutputAt = useRef(0);
  const stableOnOpenOutput = useStableCallback(onOpenOutput);
  const stableOnOpenSourceFile = useStableCallback(onOpenSourceFile);
  const stableOnOpenUrl = useStableCallback(onOpenUrl);
  const stableOnOpenImage = useStableCallback(onOpenImage);
  const stableOnOpenDocument = useStableCallback(onOpenDocument);
  const stableOnOpenFolder = useStableCallback(onOpenFolder);
  const stableOnSaveEnvironment = useStableCallback(onSaveEnvironment);
  const stableOnReconnectMcp = useStableCallback(onReconnectMcp);
  const stableOnCompact = useStableCallback(onCompact);
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
      setSessionInfoOpen(true);
    });
  }, [on, label, onBeforeOpen]);
  // Esc closes it while the keyboard is in it or on its toggle (not in a text field there), before a
  // diff in place takes it (DiffPanel listens on the window, after the document). Anywhere else Esc
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
      setSessionInfoOpen(true);
    }
  };
  const reveal = (section: SessionInfoSectionId) => {
    onBeforeOpen?.();
    bringBack?.();
    setSuppressed(false);
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
        snapshot={snapshot}
        pullRequest={pullRequest}
        machineName={machineName}
        repository={repository}
        shell={shell}
        beside={beside}
        wide={wide}
        openedOutputAt={openedOutputAt}
        onSuppress={suppress}
        registry={registry}
        subagents={subagents}
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
        onOpenFolder={stableOnOpenFolder}
        onSaveEnvironment={stableOnSaveEnvironment}
        onReconnectMcp={stableOnReconnectMcp}
        remoteControl={remoteControl}
        onCompact={stableOnCompact}
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

const SESSION_INFO_TOGGLE = "button.acpmux-session-info-toggle";
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

/// What a press may land on without hiding the popover: a menu, popup or dialog the panel opened,
/// drawn outside it in a portal.
const DISMISS_KEEPERS =
  'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], .ui-popup';

/// Closes Session Info from Esc and gives the keyboard to its header toggle, so focus is
/// not dropped on the page when the panel it was in leaves. Over a diff in place the header, and the
/// toggle with it, is hidden and cannot take focus: the page gets it, as before.
const closeSessionInfo = () => {
  document.querySelector<HTMLElement>(SESSION_INFO_TOGGLE)?.focus({ preventScroll: true });
  setSessionInfoOpen(false);
};

/// Session Info while it is drawn: its presence, its width and folds, whether it floats or pushes,
/// and what it lists. Its own component, so its enter and exit phases, a drag step and a fold draw the panel
/// alone, not the chat pane that calls useSessionInfo (one Session Info open drew that pane five
/// times in a frame).
const SessionInfoPresence = memo(function SessionInfoPresence({
  chat,
  shown,
  snapshot,
  pullRequest,
  machineName,
  repository,
  shell,
  beside,
  wide,
  openedOutputAt,
  onSuppress,
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
  onOpenFolder,
  onSaveEnvironment,
  onReconnectMcp,
  remoteControl,
  onCompact,
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
  snapshot: AcpmuxSnapshot;
  /// What the App read of the chat's pull requests (header state), which the hook already follows.
  pullRequest: HeaderPullRequest | undefined;
  machineName?: string;
  repository?: string;
  shell?: HTMLElement | null;
  /// The side panel beside the chat, as it opens or closes: the chat's room is measured again.
  beside?: unknown;
  /// A handoff review's form shows: whether the panel lies over the chat is measured against it.
  wide?: boolean;
  /// When an output's diff was last opened (Date.now()).
  openedOutputAt: { readonly current: number };
  /// That diff's split left no room for the chat beside Session Info: Session Info steps aside.
  onSuppress: () => void;
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
  onOpenFolder?: (path: string) => void;
  onSaveEnvironment?: () => Promise<unknown>;
  onReconnectMcp?: (server: string) => Promise<unknown>;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onCompact?: () => void;
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
  const { width, sections } = useSessionInfoState(chat);
  const display = useChatDisplay();
  const sizing = useChatSizing();
  const column = chatColumnOf(sizing.width, display, sizing.scale);
  // It slides in from the pane's right edge and back out (ui/presence.ts), keeping its sections
  // while it leaves.
  const presence = usePresence(shown, "right");
  const drawn = presence.present;
  // The chat's room: the pane less the side panel beside it (a document), whose edge the floating
  // panel keeps clear of, so it never lies over the document.
  const { width: paneWidth, side, height: paneHeight } = usePaneRoom(shell, drawn, beside);
  const push = pushes(display.sessionInfo);
  const overChat = !push && sessionInfoOverChat(paneWidth, width, column, wide);
  // In a short pane, over the chat it is a popover that a click elsewhere hides (POPOVER_BELOW_HEIGHT).
  const popover = sessionInfoPopover(paneHeight, overChat);
  // Over the chat in a taller pane, the card stops above the composer's stack: its height, followed
  // while it lies over the chat (one ResizeObserver on the dock, disconnected when it no longer does,
  // turns popover, or the panel goes). The card's foot animates to it (sessionInfo.css).
  const stopsAboveComposer = overChat && !popover;
  const dockHeight = useDockHeight(shell, drawn && stopsAboveComposer);
  const tabRowHeight = useTabRow().height;
  const sessionInfoTop = sessionInfoTopOffset(tabRowHeight);
  // The placement marker: Push always's column narrows the transcript and not the header
  // (sessionInfo.css). Overlay moves nothing.
  useLayoutEffect(() => {
    if (!shell) return;
    if (!drawn) {
      delete shell.dataset.sessionInfoChatPlacement;
      shell.style.removeProperty("--acpmux-header-room");
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
      return;
    }
    shell.dataset.sessionInfoChatPlacement = push ? "push" : "overlay";
    shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
    // Push always narrows the transcript, not the header: native tabs reserve the tools at the
    // pane's trailing edge. Reuse the measured room (excluding an artifact beside the chat).
    if (paneWidth > 0) shell.style.setProperty("--acpmux-header-room", `${paneWidth}px`);
  }, [shell, drawn, push, paneWidth]);
  useLayoutEffect(() => {
    if (!shell) return;
    return () => {
      delete shell.dataset.sessionInfoChatPlacement;
      shell.style.removeProperty("--acpmux-header-room");
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
    };
  }, [shell]);
  // A card under the panel (the computer use live preview) reads where it goes from the shell.
  useUnderSessionInfo(shell, drawn, push, FLOAT_MARGIN, sessionInfoTop);
  // A subagent's panel reads its own rows only: its replies, thoughts and tool calls.
  const rows = scope?.rows ?? snapshot.rows;
  const scopedAgent = scope?.agent;
  const summary = useMemo(
    () => (drawn && scopedAgent ? subagentSummary(snapshot.summary, scopedAgent, rows) : snapshot.summary),
    [drawn, scopedAgent, snapshot.summary, rows],
  );
  const made = useMemo(
    () => (drawn ? sessionSummary(rows, repository ?? null, summary?.cwd) : undefined),
    [drawn, rows, repository, summary?.cwd],
  );
  const links = useMemo(() => (drawn ? outputLinks(rows) : []), [drawn, rows]);
  const artifacts = useMemo(() => (drawn ? chatGallery(rows).length : 0), [drawn, rows]);
  const documents = useMemo(() => (drawn ? outputArtifacts(rows) : []), [drawn, rows]);
  const views = subagents?.views;
  const asks = subagents?.asks;
  const scopedAgents = scope?.agents;
  const agents = useMemo(
    () => (drawn ? (scopedAgents ?? [...subagentsIn(rows, views).values()]) : []),
    [drawn, scopedAgents, rows, views],
  );
  const chatRows = snapshot.rows;
  const transcriptTasks = useMemo(
    () => (scope && made ? withChatEnds(made.backgroundTasks, chatRows) : made?.backgroundTasks),
    [scope, made, chatRows],
  );
  const allProcesses = registry?.processes;
  const processes = useMemo(
    () => (drawn && scope && allProcesses ? subagentProcesses(allProcesses, rows) : allProcesses),
    [drawn, scope, allProcesses, rows],
  );
  const waiting = useMemo(
    () => (drawn && asks ? waitingSubagents(asks, views) : new Set<string>()),
    [drawn, asks, views],
  );
  // Every pull request's title, state, lines and checks from the App's cache, the folder's live
  // read over it (changesStatus.ts); asked for only while Changes is unfolded.
  const changes = useMemo(() => visibleChanges(made?.pullRequests ?? [], {}), [made?.pullRequests]);
  const prUrls = useStableUrls(changes);
  const { statuses: cached } = useChangesStatuses(prUrls, drawn, drawn && sections.changes);
  const statuses = useMemo(() => withHeader(cached, headerStatus(pullRequest)), [cached, pullRequest]);
  // An output's diff opens beside the chat. Pushing (Settings Push always), when that split leaves too
  // little room for a readable chat beside Session Info, it steps aside until the toggle opens it
  // again. Floating, it takes no room from the chat and stays.
  const roomy = !push || paneWidth <= 0 || paneWidth - pushedWidth(paneWidth, width) - FLOAT_MARGIN >= PUSH_MIN_CHAT;
  const roomyRef = useRef(roomy);
  // Environment's project opens in Files as a tab right of the chat (App.tsx `onOpenFolder`). The panel
  // then steps aside when it lies over the chat, at the click or once the tab's split narrows the pane,
  // so the chat and its new tab are what show, never the card over them (Leo, 2026-10-27: "why am i
  // sent to a whole new thing instead of a tab opening on the right?").
  const openedFolderAt = useRef(0);
  const openFolder = useMemo(
    () =>
      onOpenFolder &&
      ((path: string) => {
        openedFolderAt.current = Date.now();
        onOpenFolder(path);
        if (overChat) onSuppress();
      }),
    [onOpenFolder, overChat, onSuppress],
  );
  useEffect(() => {
    if (overChat && Date.now() - openedFolderAt.current < SPLIT_SETTLE_MS) onSuppress();
  }, [overChat, onSuppress]);
  useEffect(() => {
    const was = roomyRef.current;
    roomyRef.current = roomy;
    const opened = Math.max(openedOutputAt.current, openedFolderAt.current);
    if (was && !roomy && Date.now() - opened < SPLIT_SETTLE_MS) onSuppress();
  }, [roomy, openedOutputAt, onSuppress]);
  if (!drawn) return null;
  return (
    <SessionInfoPanel
      title={scope && SUBAGENT_HEADER === "title" ? <SubagentTitle scope={scope} /> : undefined}
      width={push ? pushedWidth(paneWidth, width) : width}
      placement={push ? "push" : "overlay"}
      // Floating or pushing, it starts under the chat header (styles.css --acpmux-header-height; in the
      // pane's tab row, the row's height), so the header's tools, its own toggle among them, stay in reach.
      under={sessionInfoTop}
      side={push ? 0 : side}
      foot={stopsAboveComposer ? dockHeight : undefined}
      onDismiss={popover ? onSuppress : undefined}
      presence={presence}
    >
      {/* Another chat's sections start drawn with what that chat has: none of its rows drops in. */}
      <SessionInfo
        key={scope ? `${snapshot.sessionId}:subagent:${scope.agent.id}` : snapshot.sessionId}
        banner={
          scope && SUBAGENT_HEADER !== "title" ? <SubagentBanner scope={scope} variant={SUBAGENT_HEADER} /> : undefined
        }
        agent={scope?.agent}
        summary={summary}
        machineName={machineName}
        peerKinds={snapshot.peerKinds}
        repository={repository}
        made={made}
        links={links}
        artifacts={artifacts}
        documents={documents}
        rows={rows}
        agents={agents}
        waiting={waiting}
        onOpenSubagent={subagents?.onOpen}
        statuses={statuses}
        processes={processes}
        listed={registry?.listed}
        transcriptTasks={transcriptTasks}
        // The chats the chat's agent started are the chat's.
        sessions={scope ? undefined : sessions?.list}
        workflows={scope ? undefined : workflows?.list}
        onStopWorkflow={workflows?.onStop}
        onOpenWorkflowAgent={workflows?.onOpenAgent}
        onOpenSession={sessions?.onOpen}
        // Usage lists every chat acpmux lists; a subagent's own panel has no Usage.
        allSessions={scope ? undefined : snapshot.sessions}
        onOpenChat={onOpenChat}
        onShowUsage={scope ? undefined : onShowUsage}
        onSetRunningLimit={onSetRunningLimit}
        revealed={revealed}
        onRevealed={onRevealed}
        onStopProcess={onStopProcess}
        sections={sections}
        onSection={setSessionInfoSection}
        onOpenSourceFile={onOpenSourceFile}
        onOpenOutput={onOpenOutput}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
        onOpenFolder={openFolder}
        // Save keeps the chat's machine and folder, not a subagent's.
        onSaveEnvironment={scope ? undefined : onSaveEnvironment}
        onReconnectMcp={onReconnectMcp}
        remoteControl={scope ? undefined : remoteControl}
        // Compact ends the chat's context, not a subagent's.
        onCompact={scope ? undefined : onCompact}
        onOpenDocument={onOpenDocument}
        onShowCall={onShowCall}
      />
    </SessionInfoPanel>
  );
});

/// The panel's frame: its width, its place beside the chat (push) or floating in the chat's right
/// gutter (overlay), and the drag handle on its left edge (a double-click puts the width back). With
/// `presence`, it enters from and leaves toward the pane's right edge. The main panel has no head and
/// no close button: its header toggle and Esc close it (Leo, 2026-10-24: "you still didn't remove the,
/// like, top bit with the closing mark. It doesn't— it's not necessary"), and it steps aside whenever a
/// view takes the pane, so its toggle is always in reach. A scoped subagent supplies a title as its own
/// breadcrumb. It starts `under` (a CSS length: the chat header's height) below the pane's top, at the
/// top by default.
export function SessionInfoPanel({
  width,
  placement,
  under,
  foot,
  side = 0,
  onDismiss,
  presence,
  onClose,
  title,
  chrome = "close",
  children,
}: {
  width: number;
  placement: SessionInfoPlacement;
  under?: string;
  /// Over the chat's column, the composer's stack height in px: the card stops above it.
  foot?: number;
  /// A popover (sessionInfoPopover): a press anywhere but the panel, its toggle, or a menu, popup or
  /// dialog it opened hides it until the toggle opens it again.
  onDismiss?: () => void;
  /// Floating, how far from the pane's right edge the chat ends (the side panel's width): the panel
  /// floats in the chat's gutter, left of the side panel.
  side?: number;
  presence?: Presence;
  /// Its own close button, in the gallery's chrome choices only.
  onClose?: () => void;
  /// Its head's title in place of "Session Info": a subagent's panel names the subagent (SubagentTitle).
  title?: ReactNode;
  /// With `onClose`, the gallery's chrome choices: a floating close, the old title row, a compact
  /// close-only row.
  chrome?: "title" | "close" | "compact-close";
  children: ReactNode;
}) {
  const t = useT();
  const frame = useRef<HTMLElement | null>(null);
  const drag = useRef<{ right: number } | undefined>(undefined);
  // The foot animates only once it has been drawn at its first measure: the open draws it at once.
  const footKnown = foot !== undefined && foot > 0;
  const [footSettled, setFootSettled] = useState(false);
  useEffect(() => {
    if (!footKnown) {
      setFootSettled(false);
      return;
    }
    const frameId = requestAnimationFrame(() => setFootSettled(true));
    return () => cancelAnimationFrame(frameId);
  }, [footKnown]);
  // A popover hides on a press elsewhere: one capture listener on the document while it is one.
  useEffect(() => {
    const doc = frame.current?.ownerDocument;
    if (!onDismiss || !doc) return;
    const away = (event: PointerEvent) => {
      const target = event.target as Element | null;
      if (!target || typeof target.closest !== "function") return;
      if (frame.current?.contains(target)) return;
      if (target.closest(`${SESSION_INFO_TOGGLE}, ${DISMISS_KEEPERS}`)) return;
      onDismiss();
    };
    doc.addEventListener("pointerdown", away, true);
    return () => doc.removeEventListener("pointerdown", away, true);
  }, [onDismiss]);
  return (
    <aside
      {...presence?.props}
      ref={(node) => {
        frame.current = node;
        presence?.props.ref(node);
      }}
      inert={presence?.leaving}
      className="ui-glass ui-glass-floats acpmux-session-info"
      data-placement={placement}
      data-chrome={title ? "title" : onClose ? chrome : "none"}
      data-over-chat={foot !== undefined ? "" : undefined}
      data-popover={onDismiss ? "" : undefined}
      data-foot-moves={footKnown && footSettled ? "" : undefined}
      style={
        {
          width,
          // Pushing, its enter and exit run its right margin from minus this (sessionInfo.css).
          "--acpmux-session-info-width": `${width}px`,
          ...(under ? { "--acpmux-session-info-top": under } : {}),
          ...(foot !== undefined ? { "--acpmux-session-info-foot": `${foot}px` } : {}),
          ...(side > 0 ? { "--acpmux-session-info-side": `${side}px` } : {}),
        } as CSSProperties
      }
      aria-label={t("sessionInfo.title")}
    >
      <div
        className="acpmux-session-info__resize"
        aria-hidden="true"
        onPointerDown={(event) => {
          if (event.button !== 0 || !frame.current) return;
          event.preventDefault();
          event.currentTarget.setPointerCapture?.(event.pointerId);
          drag.current = { right: frame.current.getBoundingClientRect().right };
          frame.current.dataset.resizing = "";
        }}
        onPointerMove={(event) => {
          if (drag.current) setSessionInfoWidth(drag.current.right - event.clientX, false);
        }}
        onPointerUp={(event) => {
          if (!drag.current) return;
          setSessionInfoWidth(drag.current.right - event.clientX);
          drag.current = undefined;
          if (frame.current) delete frame.current.dataset.resizing;
        }}
        onPointerCancel={() => {
          drag.current = undefined;
          if (frame.current) delete frame.current.dataset.resizing;
        }}
        onDoubleClick={() => setSessionInfoWidth(SESSION_INFO_WIDTH.fallback)}
      />
      {title || (onClose && (chrome === "title" || chrome === "compact-close")) ? (
        <div className="acpmux-session-info__head">
          {title ??
            (chrome === "title" ? <span className="acpmux-session-info__title">{t("sessionInfo.title")}</span> : null)}
          {onClose && (
            <button
              type="button"
              className="acpmux-session-info-icon-button acpmux-session-info__close"
              aria-label={t("sessionInfo.close")}
              {...tooltipProps(t("sessionInfo.close"), undefined)}
              onClick={onClose}
            >
              <Icon name="action.close" size={12} />
            </button>
          )}
        </div>
      ) : (
        onClose && (
          <button
            type="button"
            className="acpmux-session-info-icon-button acpmux-session-info__close acpmux-session-info__close--floating"
            aria-label={t("sessionInfo.close")}
            {...tooltipProps(t("sessionInfo.close"), undefined)}
            onClick={onClose}
          >
            <Icon name="action.close" size={12} />
          </button>
        )
      )}
      {children}
    </aside>
  );
}

/// How the panel lays out its sections. Leo, 2026-10-22: "and this session rail is tmi and too many
/// boxes?". It drew eight hairline cards: two of them one line each (Context, Connectors), two of them
/// the same kind of thing (Servers and Background tasks, both background commands). No section is a
/// card now, and Servers' rows head Background tasks. The three ways the gallery shows
/// (`agent-pane.chat-inspector` `layout-*`):
/// - `glance`, shipped: three blocks with a hairline between them and no box. Where it runs: the
///   Environment's rows with no title over them, then Context and Connectors as one row each, which
///   open in place. What it made: Changes, Outputs. What it runs: Subagents, Background tasks.
/// - `rules`: every section keeps its title, Environment's too, with a hairline between each.
/// - `groups`: the same three blocks as `glance`, each one hairline card.
export type RailLayout = "glance" | "rules" | "groups";
export const RAIL_LAYOUT: RailLayout = "glance";

/// The sections for one chat.
export function SessionInfo({
  summary,
  machineName,
  peerKinds,
  repository,
  made,
  links = [],
  artifacts = 0,
  documents = [],
  rows = [],
  agents = [],
  waiting = new Set(),
  onOpenSubagent,
  statuses = {},
  processes = [],
  listed = false,
  transcriptTasks = [],
  sessions = [],
  workflows = [],
  onStopWorkflow,
  workflowAgentRowVariant,
  onOpenWorkflowAgent,
  onOpenSession,
  onSetRunningLimit,
  revealed,
  onRevealed,
  onStopProcess,
  sections,
  onSection,
  onOpenOutput,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  onOpenDocument,
  remoteControl,
  onSaveEnvironment,
  onReconnectMcp,
  onCompact,
  onOpenFolder,
  onShowCall,
  allSessions,
  onOpenChat,
  onShowUsage,
  banner,
  agent,
  layout = RAIL_LAYOUT,
  projectRowLook,
  remoteControlIcon,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  repository?: string;
  /// What the chat produced (sessionSummary).
  made?: Pick<SessionSummary, "outputs" | "pullRequests" | "scheduled"> & Partial<Pick<SessionSummary, "sources">>;
  links?: readonly OutputLink[];
  artifacts?: number;
  /// The documents the chat produced (OutputsSection `outputArtifacts`).
  documents?: readonly OutputArtifact[];
  /// Opens a document in the side panel beside the chat.
  onOpenDocument?: (artifact: Artifact) => void;
  /// The chat's rows, for its gallery.
  rows?: readonly AcpmuxRow[];
  agents?: readonly Subagent[];
  waiting?: ReadonlySet<string>;
  onOpenSubagent?: (id: string) => void;
  /// What the App read of the pull requests, by URL.
  statuses?: Readonly<Record<string, SessionInfoPullRequestStatus>>;
  /// The chat's background processes, in the order they started.
  processes?: readonly SessionInfoProcess[];
  /// The registry answered a listing for the chat: a transcript task it does not list no longer
  /// runs (processes.ts `backgroundCommands`).
  listed?: boolean;
  /// The background commands the transcript knows (sessionSummary `backgroundTasks`): Claude's
  /// background Bash, Ctrl-B's included, which the registry may not list.
  transcriptTasks?: readonly SummaryBackgroundTask[];
  /// The chats the agent started, listed under Subagents.
  sessions?: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
  /// Sets or drops the chat's running limit (SubagentLimitStepper.tsx); without it the limit only reads.
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  /// The chat's Claude workflows (Labs): they head Background tasks, and leave Subagents.
  workflows?: readonly WorkflowSummary[];
  onStopWorkflow?: (id: string) => Promise<unknown>;
  /// Gallery-only alternatives for the live workflow agent row.
  workflowAgentRowVariant?: WorkflowAgentRowVariant;
  /// Opens a workflow agent through its workflow transcript bridge.
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  /// The section a running line's count opened: scrolled into view (`at` tells one ask from the next).
  revealed?: { section: SessionInfoSectionId; at: number };
  /// The reveal has scrolled: the caller forgets it.
  onRevealed?: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  /// Which sections are open; uncontrolled without `onSection`.
  sections?: SessionInfoSections;
  onSection?: (id: SessionInfoSectionId, open: boolean) => void;
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onSaveEnvironment?: () => Promise<unknown> | void;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Sends the chat's agent its `/compact`: Context's Compact session (ContextSection), live while a
  /// turn runs (the /compact queues behind it), and Usage's next step for its context (UsageSection.tsx).
  onCompact?: () => void;
  /// Every chat acpmux lists, this Mac's and its peers', for Usage (UsageSection.tsx); unset in a
  /// subagent's own panel.
  allSessions?: readonly AcpmuxSessionEntry[];
  /// Opens one of them.
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  /// Opens the chat's project folder in the Files tree beside the chat.
  onOpenFolder?: (path: string) => void;
  /// Shows the Bash call that started a background command in the transcript: what its row opens
  /// in a chat whose terminal cannot open here (TasksSection).
  onShowCall?: (toolCallId: string) => boolean;
  /// The body's first line: whose panel it is (a subagent's, SubagentBanner).
  banner?: ReactNode;
  /// The subagent it lists: its Context is the tokens and tool uses the harness reports for it.
  agent?: Subagent;
  /// How its sections are laid out (`RAIL_LAYOUT`); the gallery shows the others.
  layout?: RailLayout;
  /// How Environment's project row reads (EnvironmentSection's `name`); the gallery shows the others.
  projectRowLook?: ProjectRowLook;
  /// Remote Control's row icon (EnvironmentSection's REMOTE_CONTROL_ICON); the gallery shows the others.
  remoteControlIcon?: string;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const sessionInfoState = useSessionInfoState();
  const stored = sessionInfoState.sections;
  const state = sections ?? stored;
  const fold = (id: SessionInfoSectionId) => (next: boolean) => (onSection ?? setSessionInfoSection)(id, next);
  const [gallery, setGallery] = useState(false);
  const usage = summary?.usage;
  const known = usage !== undefined && usage.size > 0;
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const percent = known ? Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) : 0;
  const { servers, tasks: commands } = sessionInfoLists(processes, transcriptTasks, listed);
  // A chat on this Mac opens a task's terminal; elsewhere a row shows the call that started it,
  // when the loaded transcript holds it. Read only then, so a local chat adds no pass over its rows.
  const local = opensProcessTerminal(summary);
  const showsCalls = !local && !!onShowCall && commands.some((command) => command.toolCallId);
  const calls = useMemo(
    () =>
      showsCalls
        ? new Set(rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool?.id ? [item.tool.id] : []))))
        : undefined,
    [showsCalls, rows],
  );
  const body = useRef<HTMLDivElement>(null);
  // Once: then it is done, so the palette or another pane opening Session Info again does not jump
  // back to this section.
  // The section lights for a moment (sessionInfo.css `[data-revealed]`), so a reveal of a section already
  // in view still shows it answered (the header's Environment line, Leo 2026-10-21: no dead clicks).
  // Not the reveal effect's cleanup: `onRevealed` clears the reveal at once, which would put it out.
  const lit = useRef<{ section: HTMLElement; timer: number }>(undefined);
  const unlight = useCallback(() => {
    if (!lit.current) return;
    window.clearTimeout(lit.current.timer);
    delete lit.current.section.dataset.revealed;
    lit.current = undefined;
  }, []);
  useEffect(() => unlight, [unlight]);
  const light = useCallback(
    (id: SessionInfoSectionId) => {
      const section = body.current?.querySelector<HTMLElement>(`[data-section="${id}"]`);
      section?.scrollIntoView?.({ block: "nearest" });
      if (!section) return;
      unlight();
      section.dataset.revealed = "";
      lit.current = { section, timer: window.setTimeout(unlight, REVEAL_LIT_MS) };
    },
    [unlight],
  );
  useEffect(() => {
    if (!revealed) return;
    light(revealed.section);
    onRevealed?.();
  }, [revealed, onRevealed, light]);
  // Usage's Show: Subagents opens, comes into view and lights, as a reveal does.
  const showSubagents = useCallback(() => {
    (onSection ?? setSessionInfoSection)("subagents", true);
    light("subagents");
  }, [onSection, light]);
  // The panel shows: Usage's numbers are read now, not left at whatever the list last carried.
  useEffect(() => onShowUsage?.(), [onShowUsage]);
  const anyUsage = useMemo(() => !!allSessions?.some((entry) => entry.usageStats), [allSessions]);
  const scheduled = made?.scheduled ?? [];
  const pullRequests = visibleChanges(made?.pullRequests ?? [], statuses);
  const sources = made?.sources ?? [];
  const outputs = (made?.outputs ?? []) as readonly TurnFile[];
  const mcp = summary?.mcpServers ?? [];
  const reconnect = mcp.filter((server) => server.status === "failed").length;
  const runningTasks = commands.filter((command) => command.state === "running").length;
  // Subagents shows only for a chat that has had subagents or sub-sessions, or whose running limit
  // someone set (its own, an ancestor's, the workspace's or the settings'): a chat that never used
  // them, at acpmux's default, shows nothing.
  const limits = summary?.subsessionLimits;
  const limitSet =
    limits !== undefined && limits.maxRunningSource !== undefined && limits.maxRunningSource !== "default";
  const chatId = summary?.sessionId;
  // A chat on another machine: its sub-sessions live on that machine's acpmux, which takes the
  // limit only from its own person, so the line only reads.
  const setRunningLimit =
    onSetRunningLimit && chatId && !summary?.peer
      ? (maxRunning: number | null, from?: number) => onSetRunningLimit(chatId, maxRunning, from)
      : undefined;
  const progress = !known && agent ? subagentProgress(t, language, agent) : [];
  const value = (text: string) => <span className="acpmux-session-info-section__value">{text}</span>;
  const glance = layout === "glance";
  // In the top block (glance), Context and Connectors are rows like the Environment's: an icon first.
  const rowIcon = (name: string) => (glance ? name : undefined);
  const environment = (
    <SessionInfoSection
      id="environment"
      title={t("rail.environment")}
      open={glance || state.environment}
      onOpenChange={fold("environment")}
      bare={glance}
    >
      <EnvironmentSection
        summary={summary}
        machineName={machineName}
        peerKinds={peerKinds}
        repository={repository}
        remoteControl={remoteControl}
        onSave={onSaveEnvironment}
        onOpenFolder={onOpenFolder}
        projectLook={projectRowLook}
        remoteControlIcon={remoteControlIcon}
      />
    </SessionInfoSection>
  );
  const context = known ? (
    <SessionInfoSection
      id="context"
      title={t("rail.context")}
      icon={rowIcon("context.usage")}
      open={state.context}
      onOpenChange={fold("context")}
      meta={
        <>
          {value(t("rail.percent", { percent }))}
          <span className="acpmux-session-info-meter" aria-hidden="true">
            <span style={{ width: `${percent}%` }} />
          </span>
        </>
      }
    >
      <ContextSection usage={usage} percent={percent} breakdown={summary?.contextBreakdown} onCompact={onCompact} />
    </SessionInfoSection>
  ) : (
    progress.length > 0 && (
      <SessionInfoSection
        id="context"
        title={t("rail.context")}
        icon={rowIcon("context.usage")}
        open
        meta={value(progress.join(" · "))}
      />
    )
  );
  const connectors = mcp.length > 0 && (
    <SessionInfoSection
      id="connectors"
      title={t("rail.connectors")}
      icon={rowIcon("extension")}
      open={state.connectors}
      onOpenChange={fold("connectors")}
      // As Claude Code desktop's: the servers to reconnect when any failed, else the connected ones.
      meta={value(
        reconnect > 0
          ? t("sessionInfo.connectors.reconnect", { count: reconnect })
          : t("rail.connected", { count: mcp.filter((server) => server.status === "connected").length }),
      )}
    >
      <ConnectorsSection servers={mcp} onReconnect={onReconnectMcp} />
    </SessionInfoSection>
  );
  const changes = pullRequests.length > 0 && (
    <SessionInfoSection
      id="changes"
      title={t("header.changes")}
      open={state.changes}
      onOpenChange={fold("changes")}
      meta={pullRequests.length > 0 ? value(String(pullRequests.length)) : undefined}
    >
      {pullRequests.length > 0 && (
        <ChangesSection pullRequests={pullRequests} statuses={statuses} onOpenBeside={onOpenUrl} />
      )}
    </SessionInfoSection>
  );
  const sourcesSection = sources.length > 0 && (
    <SessionInfoSection
      id="sources"
      title={t("summary.sources")}
      open={state.sources}
      onOpenChange={fold("sources")}
      meta={value(String(sources.length))}
    >
      <SourcesSection
        sources={sources}
        cwd={summary?.cwd}
        onOpenFile={onOpenSourceFile}
        onOpenBeside={onOpenUrl}
        expanded={sessionInfoState.sourcesAll}
        onExpandedChange={setSessionInfoSourcesAll}
      />
    </SessionInfoSection>
  );
  const outputsShown = outputs.length + links.length + artifacts + (onOpenDocument ? documents.length : 0) > 0;
  const outputsSection = outputsShown && (
    <SessionInfoSection id="outputs" title={t("rail.outputs")} open={state.outputs} onOpenChange={fold("outputs")}>
      <OutputsSection
        files={outputs}
        links={links}
        artifacts={artifacts}
        documents={documents}
        onOpenDocument={onOpenDocument}
        onOpenFile={onOpenOutput}
        onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
      />
    </SessionInfoSection>
  );
  // A workflow Background tasks lists (Labs) is not a Subagents row too.
  const workflowIds = new Set(workflows.map((workflow) => workflow.id));
  const listedAgents = workflowIds.size > 0 ? agents.filter((agent) => !workflowIds.has(agent.id)) : agents;
  const subagentsSection = (listedAgents.length + sessions.length > 0 || limitSet) && (
    <SessionInfoSection
      id="subagents"
      title={t("summary.subagents")}
      open={state.subagents}
      onOpenChange={fold("subagents")}
      meta={value(subagentCounts(t, listedAgents, waiting, sessions))}
    >
      <SubagentLimitStepper chatId={chatId} limits={limits} sessions={sessions} onSet={setRunningLimit} />
      {listedAgents.length + sessions.length > 0 && (
        <SubagentsSection
          agents={listedAgents}
          waiting={waiting}
          onOpen={onOpenSubagent}
          sessions={sessions}
          onOpenSession={onOpenSession}
          harness={summary?.harness}
        />
      )}
    </SessionInfoSection>
  );
  // The dev servers are background commands too: their rows head the one Background tasks section
  // (they were a card of their own, most often one row). Every server runs.
  const running = runningTasks + servers.length + workflows.filter((workflow) => workflow.state === "running").length;
  const tasks = servers.length + commands.length + scheduled.length + workflows.length > 0 && (
    <SessionInfoSection
      id="tasks"
      title={t("summary.backgroundTasks")}
      open={state.tasks}
      onOpenChange={fold("tasks")}
      meta={running > 0 ? value(t("rail.running", { count: running })) : undefined}
    >
      {workflows.length > 0 && (
        <WorkflowTasks
          workflows={workflows}
          onStop={onStopWorkflow}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
          agentRowVariant={workflowAgentRowVariant}
        />
      )}
      {servers.length > 0 && <ServersSection servers={servers} onStop={onStopProcess} onOpenUrl={onOpenUrl} />}
      {commands.length + scheduled.length > 0 && (
        <TasksSection
          commands={commands}
          scheduled={scheduled}
          onStop={onStopProcess}
          local={local}
          calls={calls}
          onShowCall={onShowCall}
        />
      )}
    </SessionInfoSection>
  );
  // Usage shows once acpmux reports what this chat or any listed chat spends.
  const ownUsage = summary?.usageStats;
  const usageValue = usageMeta(t, ownUsage, language);
  const usageSection = (ownUsage || anyUsage) && (
    <SessionInfoSection
      id="usage"
      title={t("sessionInfo.usage")}
      icon={rowIcon("agent.activity")}
      open={state.usage}
      onOpenChange={fold("usage")}
      meta={usageValue && value(usageValue)}
    >
      <UsageSection
        own={ownUsage}
        sessions={allSessions ?? []}
        chatId={chatId}
        onOpen={onOpenChat}
        onCompact={onCompact}
        onShowSubagents={subagentsSection ? showSubagents : undefined}
        locale={language}
      />
    </SessionInfoSection>
  );
  return (
    <div ref={body} className="acpmux-session-info__body" data-layout={layout}>
      {banner}
      {/* Where it runs, what it made, what it runs: one order the person drags (SessionInfoGroup.tsx). */}
      <SessionInfoSectionList
        sections={{
          environment,
          context,
          usage: usageSection,
          connectors,
          changes,
          sources: sourcesSection,
          outputs: outputsSection,
          subagents: subagentsSection,
          tasks,
        }}
      />
      {gallery && (
        <GalleryDialog
          rows={rows}
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
    </div>
  );
}
