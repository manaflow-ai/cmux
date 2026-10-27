// The Inspector: the right-hand panel of an agent chat, Chief included, opened by the header's
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
// centered column, so opening, closing or updating it never reflows the chat. When that gutter has
// no room for it, it pushes the chat aside and the chat reflows, so it never lies over the
// transcript's text (Leo, 2026-10-21: "a popup ... that DOESN'T shift the layout. OR it shifts the
// layout if there isn't enough space"). Settings > Agent Chat > Inspector: Push always pushes.
// It shows only over the chat, where its toggle is: while a view takes the pane in the chat's place
// (a turn's diff in place, the event Inspector) it steps aside and comes back when that view closes,
// and with the side panel open beside the chat it floats in the chat's gutter, never over the
// document (Leo, 2026-10-22: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING
// CLOSABLE!?"). Its left edge drags to resize it. Open, width and folds are each pane's own
// (Leo, 2026-10-25: "they should all be individual per pane"), kept under the chat's session
// (inspectorState.ts). Debug Settings `agent.inspector` (on by default)
// turns it off, which brings back the summary card it replaces (summary/SummaryCard.tsx). It reads
// only acpmux's common snapshot and the App's header state, never one harness's own fields.
// While the pane shows a subagent's own view, it lists that subagent's things alone, under
// "Subagent · <name>" with a back button (subagentScope.ts, SubagentScopeHeader.tsx).
import {
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
import { chatColumnOf, useChatWidth, type ChatColumn } from "../chatWidth";
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
import { ChangesSection, headerStatus, visibleChanges, type InspectorPullRequestStatus } from "./ChangesSection";
import { useChangesStatuses, useStableUrls, withHeader } from "./changesStatus";
import { ConnectorsSection } from "./ConnectorsSection";
import { ContextSection } from "./ContextSection";
import { EnvironmentSection, type ProjectRowLook } from "./EnvironmentSection";
import { InspectorSection } from "./InspectorSection";
import { SourcesSection } from "./SourcesSection";
import { SUBAGENT_HEADER, SubagentBanner, SubagentTitle } from "./SubagentScopeHeader";
import { subagentProcesses, subagentSummary, withChatEnds, type SubagentScope } from "./subagentScope";
import {
  bindInspectorPane,
  INSPECTOR_WIDTH,
  setInspectorOpen,
  setInspectorSection,
  setInspectorSourcesAll,
  setInspectorWidth,
  useInspectorOpen,
  useInspectorState,
  type InspectorSectionId,
  type InspectorSections,
} from "./inspectorState";
import { OutputsSection, outputArtifacts, outputLinks, type OutputArtifact, type OutputLink } from "./OutputsSection";
import { inspectorLists, type InspectorProcess, type ProcessRegistry } from "./processes";
import { ServersSection } from "./ServersSection";
import { SubagentLimitStepper } from "./SubagentLimitStepper";
import { SubagentsSection, subagentCounts } from "./SubagentsSection";
import { TasksSection } from "./TasksSection";
import { WorkflowTasks } from "./WorkflowTasks";
import type { WorkflowSummary } from "../summary/workflow";
import type { Subagent } from "../subagents/subagentFold";
import { subagentProgress } from "../subagents/subagentProgress";
import { RAIL_MIN_GUTTER } from "../threadMinimap/model";
import "./inspector.css";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
export type InspectorPlacement = "push" | "overlay";

/// The narrowest chat the Inspector pushes aside: a pushed panel narrows to keep it, down to the
/// panel's own narrowest width.
export const PUSH_MIN_CHAT = 440;
/// The room the panel keeps from the pane's right edge, floating or pushing, and from the
/// transcript's column when it floats (inspector.css --acpmux-inspector-inset).
export const FLOAT_MARGIN = 8;
/// How long after an output click a narrowing counts as that diff's split.
const SPLIT_SETTLE_MS = 2000;

/// Whether the Inspector pushes the chat: only with Settings Push always. By default it floats
/// outside the pane's layout and never takes a column (Leo, 2026-10-24: "it was never supposed to be
/// a sidebar; y'all kept doing sidebars").
export const pushes = (placement: InspectorPlacement) => placement === "push";

/// A pushed panel's width: its own, narrowed so the chat keeps PUSH_MIN_CHAT beside it and its
/// right margin, down to the panel's narrowest.
export const pushedWidth = (paneWidth: number, width: number) =>
  paneWidth <= 0 ? width : Math.min(width, Math.max(INSPECTOR_WIDTH.min, paneWidth - PUSH_MIN_CHAT - FLOAT_MARGIN));

/// How far the chat's column moves left for the floating panel. Leo, 2026-10-24: "making it not a
/// part of the true agent pane area except in the case when both would fit if only the agent pane
/// shifted left". When the right gutter (model.ts transcriptColumn) holds the panel and its margins,
/// nothing moves; when the two gutters together hold it, the column moves left by what the right one
/// lacks; otherwise nothing moves and the panel floats over the chat. The left gutter keeps the
/// thread rail's usable gutter (threadMinimap/model.ts RAIL_MIN_GUTTER), so the column only slides
/// as far as the rail can follow it. The rail itself moves toward the text as the gutter shrinks.
/// A handoff review's form (handoff/styles.css: 760px, 18px from each edge) is wider than the column:
/// with `wide`, the gutter is the form's. The form takes the transcript's place, so no thread rail
/// draws beside it: the shift keeps the form's own edge clearance instead of the rail's room.
export const HANDOFF_FORM_WIDTH = 760;
/// The form's clearance from each pane edge (handoff/styles.css `min(760px, calc(100% - 36px))`).
export const HANDOFF_FORM_EDGE = 18;
export const inspectorChatShift = (paneWidth: number, width: number, column?: ChatColumn, wide = false) => {
  if (paneWidth <= 0 || width <= 0) return 0;
  const columnInset = transcriptColumn(paneWidth, column).inset;
  const inset = wide
    ? Math.min(columnInset, (paneWidth - Math.min(HANDOFF_FORM_WIDTH, paneWidth - 2 * HANDOFF_FORM_EDGE)) / 2)
    : columnInset;
  const lacks = width + 2 * FLOAT_MARGIN - inset;
  const room = inset - (wide ? HANDOFF_FORM_EDGE : RAIL_MIN_GUTTER);
  return lacks > 0 && lacks <= room ? lacks : 0;
};

/// Whether the floating panel lies over the chat's column: the right gutter cannot hold it and the
/// column cannot move left far enough (inspectorChatShift is 0 though it lacks room). Then the card,
/// full length otherwise, stops above the composer's stack so it never covers the composer.
export const inspectorOverChat = (paneWidth: number, width: number, column?: ChatColumn, wide = false) => {
  if (paneWidth <= 0 || width <= 0) return false;
  const columnInset = transcriptColumn(paneWidth, column).inset;
  const inset = wide
    ? Math.min(columnInset, (paneWidth - Math.min(HANDOFF_FORM_WIDTH, paneWidth - 2 * HANDOFF_FORM_EDGE)) / 2)
    : columnInset;
  return width + 2 * FLOAT_MARGIN - inset > 0 && inspectorChatShift(paneWidth, width, column, wide) === 0;
};

/// Whether the Inspector shows: on (Debug Settings `agent.inspector`), open (the viewer's, in every
/// chat tab), not stepped aside for a diff split, and only over the chat: never while a view takes
/// the pane in its place (`covered`: a turn's diff in place hides the header, and the toggle with it).
export const inspectorShown = ({
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

/// The side panel beside the chat (conversation/ArtifactPanel.tsx), a child of the pane's shell.
const SIDE_PANEL = ":scope > .acpmux-artifact";

/// The Inspector starts right below the header: the pane's tab row when the header is in it.
export function inspectorTopOffset(tabRowHeight: number): string {
  return tabRowHeight > 0 ? `${tabRowHeight}px` : "var(--acpmux-header-height, 44px)";
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
/// panel's width, which the floating Inspector keeps clear of.
export type PaneRoom = { width: number; side: number };
const UNMEASURED: PaneRoom = { width: 0, side: 0 };
export function paneRoom(shell: HTMLElement): PaneRoom {
  const side = shell.querySelector<HTMLElement>(SIDE_PANEL)?.offsetWidth ?? 0;
  return { width: Math.max(0, shell.clientWidth - side), side };
}

/// The chat's room, followed as the pane resizes and as the side panel opens, closes or resizes
/// (`beside` changes with it); width 0 before it is measured. A resize draws in the frame that has
/// the new width: the observer runs after that frame's layout and before its paint, and `flushSync`
/// renders the panel's place there (state set plainly drew a frame or more later, the panel floating
/// over the narrowed transcript before the chat jumped aside: "WHY DOES IT FLICKER").
type PaneRoomState = PaneRoom & { shellWidth: number; suppressShiftTransition: boolean };

function usePaneRoom(shell: HTMLElement | null | undefined, live: boolean, beside: unknown): PaneRoomState {
  const [room, setRoom] = useState<PaneRoomState>({ ...UNMEASURED, shellWidth: 0, suppressShiftTransition: false });
  useLayoutEffect(() => {
    if (!shell || !live) return;
    let lastShellWidth = shell.clientWidth;
    const measure = () => {
      const next = paneRoom(shell);
      const shellWidth = shell.clientWidth;
      const suppressShiftTransition = lastShellWidth !== shellWidth;
      setRoom((current) =>
        current.width === next.width && current.side === next.side && current.shellWidth === shellWidth
          ? current
          : {
              ...next,
              shellWidth,
              // A native pane changes the shell's own width. An artifact only changes `side`, so it
              // keeps the Session Info shift transition and its normal floating motion.
              suppressShiftTransition,
            },
      );
      lastShellWidth = shellWidth;
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(() => flushSync(measure));
    observer.observe(shell);
    const side = shell.querySelector<HTMLElement>(SIDE_PANEL);
    if (side) observer.observe(side);
    return () => observer.disconnect();
  }, [shell, live, beside]);
  useLayoutEffect(() => {
    if (!room.suppressShiftTransition) return;
    const frame = requestAnimationFrame(() =>
      setRoom((current) =>
        current.suppressShiftTransition ? { ...current, suppressShiftTransition: false } : current,
      ),
    );
    return () => cancelAnimationFrame(frame);
  }, [room]);
  return room;
}

/// How long a revealed section stays lit.
const REVEAL_LIT_MS = 1200;

/// The header's toggle and the Inspector for the chat's pane. `on` is Debug Settings
/// `agent.inspector`: off, there is neither, and the App shows its summary card instead.
export function useChatInspector({
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
  beside,
  wide = false,
  onReconnectMcp,
}: {
  snapshot: AcpmuxSnapshot;
  /// A view has the pane in the chat's place (App.tsx: a turn's diff in place, the event Inspector):
  /// the panel steps aside, its open state kept, and is back when that view closes.
  covered?: boolean;
  /// Closes that view: opening the Inspector (its toggle, the palette, a running line's count)
  /// brings the chat back first.
  onUncover?: () => void;
  /// The side panel beside the chat, changing as it opens or closes (App.tsx `artifact.opened`):
  /// the panel measures the chat's room without it.
  beside?: unknown;
  /// What the chat shows under its header is a handoff review's form, wider than the transcript's
  /// column (App.tsx): the chat's shift left is measured against the form. It never pushes.
  wide?: boolean;
  /// This Mac's name from the handshake, for a local chat.
  machineName?: string;
  /// The chat folder's GitHub repository (`git.githubRepository`), `owner/name`.
  repository?: string;
  /// The pane's shell: the Inspector measures it to float or push.
  shell?: HTMLElement | null;
  /// Opens a file's diff (App.tsx openOutput: beside the chat, else in place).
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  /// Opens a web address in the browser beside the chat (a server's port, a pull request).
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
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
  workflows?: { list: readonly WorkflowSummary[]; onStop?: (id: string) => Promise<unknown> };
  /// Opens one of the chat's folders in the Files tree beside the chat (a chat on this Mac).
  onOpenFolder?: (path: string) => void;
  /// Saves the chat's machine and folder as an environment (`environment.save`).
  onSaveEnvironment?: () => Promise<unknown>;
  /// Shows the Bash call that started a background command in the transcript (App.tsx `showToolRow`).
  onShowCall?: (toolCallId: string) => boolean;
  /// The subagent whose own view the pane shows: the Inspector lists its things, not the chat's.
  subagent?: SubagentScope;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
}): {
  on: boolean;
  button?: ReactNode;
  panel?: ReactNode;
  // The native command palette shares the header's visibility and uncover behavior.
  toggle?: () => void;
  // Opens the Inspector with `section` unfolded (the running line's counts: App.tsx).
  reveal?: (section: InspectorSectionId) => void;
} {
  const t = useT();
  const { inspector: on, pullRequest } = useHeaderState();
  // This pane's state is its chat's: a relaunched pane shows its Inspector as it left it, and a
  // toggle in another pane never reaches it (inspectorState.ts).
  // The chat's state is read from its first frame (`useInspectorOpen(paneSession)`), before the bind,
  // and the panel is keyed by the chat, so a pane switched to another chat shows that chat's
  // Inspector at once instead of playing the last chat's panel out.
  const paneSession = snapshot.sessionId ?? snapshot.summary?.sessionId;
  useLayoutEffect(() => bindInspectorPane(paneSession), [paneSession]);
  // Open alone: the width and the folds are the panel's (InspectorPresence), so a drag step or a fold
  // does not draw the whole chat pane again.
  const open = useInspectorOpen(paneSession);
  // Closed for now (not remembered): an output's diff split left no room beside the chat.
  const [suppressed, setSuppressed] = useState(false);
  const suppress = useCallback(() => setSuppressed(true), []);
  const shown = inspectorShown({ on, open, suppressed, covered });
  // The section a running line's count asked for, scrolled to once drawn.
  const [revealed, setRevealed] = useState<{ section: InspectorSectionId; at: number }>();
  const clearRevealed = useCallback(() => setRevealed(undefined), []);
  const openedOutputAt = useRef(0);
  const label = t("chatInspector.title");
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
      uncover.current?.();
      setSuppressed(false);
      setInspectorOpen(true);
    });
  }, [on, label]);
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
      if (!(focus instanceof HTMLElement) || !focus.closest(`aside.acpmux-chat-inspector, ${INSPECTOR_TOGGLE}`)) return;
      if (focus.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])")) return;
      if (
        document.querySelector(
          'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], .ui-popup',
        )
      )
        return;
      event.preventDefault();
      closeInspector();
    };
    document.addEventListener("keydown", escape);
    return () => document.removeEventListener("keydown", escape);
  }, [shown]);
  if (!on) return { on: false };
  const toggle = () => {
    if (shown) setInspectorOpen(false);
    else {
      bringBack?.();
      setSuppressed(false);
      setInspectorOpen(true);
    }
  };
  const reveal = (section: InspectorSectionId) => {
    bringBack?.();
    setSuppressed(false);
    setInspectorSection(section, true);
    setInspectorOpen(true);
    setRevealed({ section, at: Date.now() });
  };
  const openOutput = onOpenOutput
    ? (path: string) => {
        openedOutputAt.current = Date.now();
        onOpenOutput(path);
      }
    : undefined;
  return {
    on: true,
    toggle,
    reveal,
    button: <PanelToggle className="acpmux-chat-inspector-toggle" label={label} shown={shown} onToggle={toggle} />,
    panel: (
      <InspectorPresence
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
        onStopProcess={onStopProcess}
        onOpenSourceFile={onOpenSourceFile}
        onOpenOutput={openOutput}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
        onOpenFolder={onOpenFolder}
        onSaveEnvironment={onSaveEnvironment}
        onReconnectMcp={onReconnectMcp}
        onOpenDocument={onOpenDocument}
        onShowCall={onShowCall}
        scope={subagent}
      />
    ),
  };
}

const INSPECTOR_TOGGLE = "button.acpmux-chat-inspector-toggle";

/// Closes the Inspector from Esc and gives the keyboard to its header toggle, so focus is
/// not dropped on the page when the panel it was in leaves. Over a diff in place the header, and the
/// toggle with it, is hidden and cannot take focus: the page gets it, as before.
const closeInspector = () => {
  document.querySelector<HTMLElement>(INSPECTOR_TOGGLE)?.focus({ preventScroll: true });
  setInspectorOpen(false);
};

/// The Inspector while it is drawn: its presence, its width and folds, whether it floats or pushes,
/// and what it lists. Its own component, so its enter and exit phases, a drag step and a fold draw the panel
/// alone, not the chat pane that calls useChatInspector (one Inspector open drew that pane five
/// times in a frame).
function InspectorPresence({
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
  onOpenDocument,
  onShowCall,
  scope,
}: {
  /// The chat whose width and folds it draws (inspectorState.ts `useInspectorState`).
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
  /// A handoff review's form shows: the shift is measured against it.
  wide?: boolean;
  /// When an output's diff was last opened (Date.now()).
  openedOutputAt: { readonly current: number };
  /// That diff's split left no room for the chat beside the Inspector: the Inspector steps aside.
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
  workflows?: { list: readonly WorkflowSummary[]; onStop?: (id: string) => Promise<unknown> };
  revealed?: { section: InspectorSectionId; at: number };
  onRevealed: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  onOpenFolder?: (path: string) => void;
  onSaveEnvironment?: () => Promise<unknown>;
  onReconnectMcp?: (server: string) => Promise<unknown>;
  onOpenDocument?: (artifact: Artifact) => void;
  onShowCall?: (toolCallId: string) => boolean;
  /// The subagent it lists, while the pane shows one's own view.
  scope?: SubagentScope;
}) {
  const { width, sections } = useInspectorState(chat);
  const display = useChatDisplay();
  const column = chatColumnOf(useChatWidth(), display);
  // It slides in from the pane's right edge and back out (ui/presence.ts), keeping its sections
  // while it leaves.
  const presence = usePresence(shown, "right");
  const drawn = presence.present;
  // The chat's room: the pane less the side panel beside it (a document), whose edge the floating
  // panel keeps clear of, so it never lies over the document.
  const { width: paneWidth, side, suppressShiftTransition } = usePaneRoom(shell, drawn, beside);
  const push = pushes(display.inspector);
  const chatShift = push ? 0 : inspectorChatShift(paneWidth, width, column, wide);
  const overChat = !push && inspectorOverChat(paneWidth, width, column, wide);
  // Over the chat, the card stops above the composer's stack: its height, followed while it lies over
  // the chat (one ResizeObserver on the dock, disconnected when it no longer does or the panel goes).
  const dockHeight = useDockHeight(shell, drawn && overChat);
  const tabRowHeight = useTabRow().height;
  const inspectorTop = inspectorTopOffset(tabRowHeight);
  // The overlay handoff is a layout assist, not panel motion. Set the placement marker before the
  // shift so the overlay transition is disabled for the one frame where flex layout takes the panel's
  // room; otherwise the old overlay shift would animate back and briefly move the chat right again.
  useLayoutEffect(() => {
    if (!shell) return;
    if (!drawn) {
      delete shell.dataset.inspectorChatPlacement;
      delete shell.dataset.inspectorChatResizing;
      shell.style.removeProperty("--acpmux-chat-shift");
      return;
    }
    shell.dataset.inspectorChatPlacement = push ? "push" : "overlay";
    if (suppressShiftTransition) shell.dataset.inspectorChatResizing = "true";
    else delete shell.dataset.inspectorChatResizing;
    shell.style.setProperty("--acpmux-chat-shift", `${chatShift}px`);
  }, [shell, drawn, push, chatShift, suppressShiftTransition]);
  useLayoutEffect(() => {
    if (!shell) return;
    return () => {
      delete shell.dataset.inspectorChatPlacement;
      delete shell.dataset.inspectorChatResizing;
      shell.style.removeProperty("--acpmux-chat-shift");
    };
  }, [shell]);
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
  // little room for a readable chat beside the Inspector, it steps aside until the toggle opens it
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
    <InspectorPanel
      title={scope && SUBAGENT_HEADER === "title" ? <SubagentTitle scope={scope} /> : undefined}
      width={push ? pushedWidth(paneWidth, width) : width}
      placement={push ? "push" : "overlay"}
      // Floating or pushing, it starts under the chat header (styles.css --acpmux-header-height; in the
      // pane's tab row, the row's height), so the header's tools, its own toggle among them, stay in reach.
      under={inspectorTop}
      side={push ? 0 : side}
      foot={overChat ? dockHeight : undefined}
      presence={presence}
    >
      {/* Another chat's sections start drawn with what that chat has: none of its rows drops in. */}
      <ChatInspector
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
        onOpenSession={sessions?.onOpen}
        onSetRunningLimit={onSetRunningLimit}
        revealed={revealed}
        onRevealed={onRevealed}
        onStopProcess={onStopProcess}
        sections={sections}
        onSection={setInspectorSection}
        onOpenSourceFile={onOpenSourceFile}
        onOpenOutput={onOpenOutput}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
        onOpenFolder={openFolder}
        // Save keeps the chat's machine and folder, not a subagent's.
        onSaveEnvironment={scope ? undefined : onSaveEnvironment}
        onReconnectMcp={onReconnectMcp}
        onOpenDocument={onOpenDocument}
        onShowCall={onShowCall}
      />
    </InspectorPanel>
  );
}

/// The panel's frame: its width, its place beside the chat (push) or floating in the chat's right
/// gutter (overlay), and the drag handle on its left edge (a double-click puts the width back). With
/// `presence`, it enters from and leaves toward the pane's right edge. The main panel has no head and
/// no close button: its header toggle and Esc close it (Leo, 2026-10-24: "you still didn't remove the,
/// like, top bit with the closing mark. It doesn't— it's not necessary"), and it steps aside whenever a
/// view takes the pane, so its toggle is always in reach. A scoped subagent supplies a title as its own
/// breadcrumb. It starts `under` (a CSS length: the chat header's height) below the pane's top, at the
/// top by default.
export function InspectorPanel({
  width,
  placement,
  under,
  foot,
  side = 0,
  presence,
  onClose,
  title,
  chrome = "close",
  children,
}: {
  width: number;
  placement: InspectorPlacement;
  under?: string;
  /// Over the chat's column, the composer's stack height in px: the card stops above it.
  foot?: number;
  /// Floating, how far from the pane's right edge the chat ends (the side panel's width): the panel
  /// floats in the chat's gutter, left of the side panel.
  side?: number;
  presence?: Presence;
  /// Its own close button, in the gallery's chrome choices only.
  onClose?: () => void;
  /// Its head's title in place of "Inspector": a subagent's panel names the subagent (SubagentTitle).
  title?: ReactNode;
  /// With `onClose`, the gallery's chrome choices: a floating close, the old title row, a compact
  /// close-only row.
  chrome?: "title" | "close" | "compact-close";
  children: ReactNode;
}) {
  const t = useT();
  const frame = useRef<HTMLElement | null>(null);
  const drag = useRef<{ right: number } | undefined>(undefined);
  return (
    <aside
      {...presence?.props}
      ref={(node) => {
        frame.current = node;
        presence?.props.ref(node);
      }}
      inert={presence?.leaving}
      className="ui-glass ui-glass-floats acpmux-chat-inspector"
      data-placement={placement}
      data-chrome={title ? "title" : onClose ? chrome : "none"}
      data-over-chat={foot !== undefined ? "" : undefined}
      style={
        {
          width,
          // Pushing, its enter and exit run its right margin from minus this (inspector.css).
          "--acpmux-inspector-width": `${width}px`,
          ...(under ? { "--acpmux-inspector-top": under } : {}),
          ...(foot !== undefined ? { "--acpmux-inspector-foot": `${foot}px` } : {}),
          ...(side > 0 ? { "--acpmux-inspector-side": `${side}px` } : {}),
        } as CSSProperties
      }
      aria-label={t("chatInspector.title")}
    >
      <div
        className="acpmux-chat-inspector__resize"
        aria-hidden="true"
        onPointerDown={(event) => {
          if (event.button !== 0 || !frame.current) return;
          event.preventDefault();
          event.currentTarget.setPointerCapture?.(event.pointerId);
          drag.current = { right: frame.current.getBoundingClientRect().right };
          frame.current.dataset.resizing = "";
        }}
        onPointerMove={(event) => {
          if (drag.current) setInspectorWidth(drag.current.right - event.clientX, false);
        }}
        onPointerUp={(event) => {
          if (!drag.current) return;
          setInspectorWidth(drag.current.right - event.clientX);
          drag.current = undefined;
          if (frame.current) delete frame.current.dataset.resizing;
        }}
        onPointerCancel={() => {
          drag.current = undefined;
          if (frame.current) delete frame.current.dataset.resizing;
        }}
        onDoubleClick={() => setInspectorWidth(INSPECTOR_WIDTH.fallback)}
      />
      {title || (onClose && (chrome === "title" || chrome === "compact-close")) ? (
        <div className="acpmux-chat-inspector__head">
          {title ??
            (chrome === "title" ? (
              <span className="acpmux-chat-inspector__title">{t("chatInspector.title")}</span>
            ) : null)}
          {onClose && (
            <button
              type="button"
              className="acpmux-chat-inspector-icon-button acpmux-chat-inspector__close"
              aria-label={t("chatInspector.close")}
              {...tooltipProps(t("chatInspector.close"), undefined)}
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
            className="acpmux-chat-inspector-icon-button acpmux-chat-inspector__close acpmux-chat-inspector__close--floating"
            aria-label={t("chatInspector.close")}
            {...tooltipProps(t("chatInspector.close"), undefined)}
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
export function ChatInspector({
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
  onOpenFolder,
  onShowCall,
  banner,
  agent,
  layout = RAIL_LAYOUT,
  projectRowLook,
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
  statuses?: Readonly<Record<string, InspectorPullRequestStatus>>;
  /// The chat's background processes, in the order they started.
  processes?: readonly InspectorProcess[];
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
  /// The section a running line's count opened: scrolled into view (`at` tells one ask from the next).
  revealed?: { section: InspectorSectionId; at: number };
  /// The reveal has scrolled: the caller forgets it.
  onRevealed?: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  /// Which sections are open; uncontrolled without `onSection`.
  sections?: InspectorSections;
  onSection?: (id: InspectorSectionId, open: boolean) => void;
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onSaveEnvironment?: () => Promise<unknown> | void;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
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
}) {
  const t = useT();
  const language = usePaneLanguage();
  const inspectorState = useInspectorState();
  const stored = inspectorState.sections;
  const state = sections ?? stored;
  const fold = (id: InspectorSectionId) => (next: boolean) => (onSection ?? setInspectorSection)(id, next);
  const [gallery, setGallery] = useState(false);
  const usage = summary?.usage;
  const known = usage !== undefined && usage.size > 0;
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const percent = known ? Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) : 0;
  const { servers, tasks: commands } = inspectorLists(processes, transcriptTasks, listed);
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
  // Once: then it is done, so the palette or another pane opening the Inspector again does not jump
  // back to this section.
  // The section lights for a moment (inspector.css `[data-revealed]`), so a reveal of a section already
  // in view still shows it answered (the header's Environment line, Leo 2026-10-21: no dead clicks).
  // Not the reveal effect's cleanup: `onRevealed` clears the reveal at once, which would put it out.
  const lit = useRef<{ section: HTMLElement; timer: number }>(undefined);
  const unlight = () => {
    if (!lit.current) return;
    window.clearTimeout(lit.current.timer);
    delete lit.current.section.dataset.revealed;
    lit.current = undefined;
  };
  useEffect(() => unlight, []);
  useEffect(() => {
    if (!revealed) return;
    const section = body.current?.querySelector<HTMLElement>(`[data-section="${revealed.section}"]`);
    section?.scrollIntoView?.({ block: "nearest" });
    onRevealed?.();
    if (!section) return;
    unlight();
    section.dataset.revealed = "";
    lit.current = { section, timer: window.setTimeout(unlight, REVEAL_LIT_MS) };
  }, [revealed, onRevealed]);
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
  const value = (text: string) => <span className="acpmux-chat-inspector-section__value">{text}</span>;
  const glance = layout === "glance";
  // In the top block (glance), Context and Connectors are rows like the Environment's: an icon first.
  const rowIcon = (name: string) => (glance ? name : undefined);
  const environment = (
    <InspectorSection
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
      />
    </InspectorSection>
  );
  const context = known ? (
    <InspectorSection
      id="context"
      title={t("rail.context")}
      icon={rowIcon("context.usage")}
      open={state.context}
      onOpenChange={fold("context")}
      meta={
        <>
          {value(t("rail.percent", { percent }))}
          <span className="acpmux-chat-inspector-meter" aria-hidden="true">
            <span style={{ width: `${percent}%` }} />
          </span>
        </>
      }
    >
      <ContextSection usage={usage} percent={percent} breakdown={summary?.contextBreakdown} />
    </InspectorSection>
  ) : (
    progress.length > 0 && (
      <InspectorSection
        id="context"
        title={t("rail.context")}
        icon={rowIcon("context.usage")}
        open
        meta={value(progress.join(" · "))}
      />
    )
  );
  const connectors = mcp.length > 0 && (
    <InspectorSection
      id="connectors"
      title={t("rail.connectors")}
      icon={rowIcon("extension")}
      open={state.connectors}
      onOpenChange={fold("connectors")}
      // As Claude Code desktop's: the servers to reconnect when any failed, else the connected ones.
      meta={value(
        reconnect > 0
          ? t("chatInspector.connectors.reconnect", { count: reconnect })
          : t("rail.connected", { count: mcp.filter((server) => server.status === "connected").length }),
      )}
    >
      <ConnectorsSection servers={mcp} onReconnect={onReconnectMcp} />
    </InspectorSection>
  );
  const changes = pullRequests.length > 0 && (
    <InspectorSection
      id="changes"
      title={t("header.changes")}
      open={state.changes}
      onOpenChange={fold("changes")}
      meta={pullRequests.length > 0 ? value(String(pullRequests.length)) : undefined}
    >
      {pullRequests.length > 0 && (
        <ChangesSection pullRequests={pullRequests} statuses={statuses} onOpenBeside={onOpenUrl} />
      )}
    </InspectorSection>
  );
  const sourcesSection = sources.length > 0 && (
    <InspectorSection
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
        expanded={inspectorState.sourcesAll}
        onExpandedChange={setInspectorSourcesAll}
      />
    </InspectorSection>
  );
  const outputsShown = outputs.length + links.length + artifacts + (onOpenDocument ? documents.length : 0) > 0;
  const outputsSection = outputsShown && (
    <InspectorSection id="outputs" title={t("rail.outputs")} open={state.outputs} onOpenChange={fold("outputs")}>
      <OutputsSection
        files={outputs}
        links={links}
        artifacts={artifacts}
        documents={documents}
        onOpenDocument={onOpenDocument}
        onOpenFile={onOpenOutput}
        onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
      />
    </InspectorSection>
  );
  // A workflow Background tasks lists (Labs) is not a Subagents row too.
  const workflowIds = new Set(workflows.map((workflow) => workflow.id));
  const listedAgents = workflowIds.size > 0 ? agents.filter((agent) => !workflowIds.has(agent.id)) : agents;
  const subagentsSection = (listedAgents.length + sessions.length > 0 || limitSet) && (
    <InspectorSection
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
        />
      )}
    </InspectorSection>
  );
  // The dev servers are background commands too: their rows head the one Background tasks section
  // (they were a card of their own, most often one row). Every server runs.
  const running = runningTasks + servers.length + workflows.filter((workflow) => workflow.state === "running").length;
  const tasks = servers.length + commands.length + scheduled.length + workflows.length > 0 && (
    <InspectorSection
      id="tasks"
      title={t("summary.backgroundTasks")}
      open={state.tasks}
      onOpenChange={fold("tasks")}
      meta={running > 0 ? value(t("rail.running", { count: running })) : undefined}
    >
      {workflows.length > 0 && <WorkflowTasks workflows={workflows} onStop={onStopWorkflow} />}
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
    </InspectorSection>
  );
  return (
    <div ref={body} className="acpmux-chat-inspector__body" data-layout={layout}>
      {banner}
      {/* Where it runs. */}
      <div className="acpmux-chat-inspector-group" data-group="about">
        {environment}
        {context}
        {connectors}
      </div>
      {/* What it made. */}
      {(changes || sourcesSection || outputsSection) && (
        <div className="acpmux-chat-inspector-group" data-group="made">
          {changes}
          {sourcesSection}
          {outputsSection}
        </div>
      )}
      {/* What it runs. */}
      {(subagentsSection || tasks) && (
        <div className="acpmux-chat-inspector-group" data-group="running">
          {subagentsSection}
          {tasks}
        </div>
      )}
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={() => setGallery(false)}
          onOpenImage={
            onOpenImage &&
            ((src, alt) => {
              setGallery(false);
              onOpenImage(src, alt);
            })
          }
        />
      )}
    </div>
  );
}
