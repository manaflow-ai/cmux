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
//   (ChangesSection); Outputs, the pull requests, issues and commits, files and artifacts it produced
//   (OutputsSection).
// - What it runs: Subagents, each running subagent and started chat on its own line, the ended ones
//   folded into one row: the harness's subagents and the chats its agent started, a Cloud VM's or
//   another machine's included (SubagentsSection); Background tasks, the dev servers it runs first
//   (ServersSection), then its other background commands, the ones only the transcript knows
//   included, and its wakeups (TasksSection).
//
// Open, it takes one of three places by the pane's width (sessionInfoStage; Leo, 2026-11-03: "not
// affecting layout at all -> gradually pushing into the chat layout -> overlay"). Wide, it floats under
// the header's toggle in the pane's right gutter, beside the transcript's centered column, so opening,
// closing or updating it moves nothing. Where that gutter cannot hold it, it pushes into the chat
// gradually: the page keeps only the room the gutter lacks (pushedRoom), so the transcript's column moves
// left, never narrower (pushKeepsColumn). Where a push would narrow the column, and so wrap its lines
// anew, it lies over the chat and stops above the composer, and in a short pane it is a popover instead.
// Settings > Agent Chat > Session Info: Push always pushes wherever its whole room keeps the column.
// It shows only over the chat, where its toggle is: while a view takes the pane in the chat's place
// (a turn's diff in place, the event Inspector) it steps aside and comes back when that view closes,
// and with the side panel open beside the chat it floats in the chat's gutter, never over the
// document (Leo, 2026-10-22: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING
// CLOSABLE!?"). Its left edge drags to resize it. Open, width and folds are each pane's own
// (Leo, 2026-10-25: "they should all be individual per pane"), kept under the chat's session
// (sessionInfoState.ts). Debug Settings `agent.sessionInfo` (on by default)
// turns it off, which brings back the summary card it replaces (summary/SummaryCard.tsx). It reads
// only acpmux's common snapshot and the App's header state, never one harness's own fields.
// While the pane shows a subagent's own view, it lists that subagent's things alone, under
// "Subagent · <name>" with a back button (subagentScope.ts, SubagentScopeHeader.tsx).
import { memo, useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { useSeeThroughBlur } from "../../../ui/glass/seeThroughBlur";
import "../../../ui/controls.css";
import { useChatCut } from "./chatCut";
import { chatGlass, chatUnderGlass } from "../chatUnderGlass";
import { type Presence } from "../../../ui/presence";
import { useCountedRender } from "../perfRender";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { compactingUsage, type UsageCacheLayout } from "../usageStats";
import { ContextSection } from "./ContextSection";
import { opensProcessTerminal } from "../processTerminal";
import { GalleryDialog } from "../summary/GalleryDialog";
import { useScrollEdges } from "../summary/scrollEdges";
import { type SessionSummary, type SummaryBackgroundTask } from "../summary/sessionSummary";
import type { Artifact } from "../conversation/artifactPreview";
import type { StartedSession } from "../started/startedSessions";
import { ChangesSection } from "./ChangesSection";
import { visibleChanges, type SessionInfoPullRequestStatus } from "./changesSectionModel";
import { ConnectorsSection } from "./ConnectorsSection";
import { summarizeConnectors } from "./connectorState";
import { useIMessage, type IMessageView } from "./imessage";
import { EnvironmentSection, type ProjectRowLook } from "./EnvironmentSection";
import { SessionInfoSectionList, type SessionInfoCompactLook } from "./SessionInfoGroup";
import { sectionOrder, tuckedSections } from "./sectionOrder";
import { SessionInfoSection } from "./SessionInfoSection";
import { SourcesSection } from "./SourcesSection";
import {
  claimSessionInfoIMessageReveal,
  SESSION_INFO_WIDTH,
  setSessionInfoMore,
  setSessionInfoSection,
  setSessionInfoSourcesAll,
  setSessionInfoWidth,
  useSessionInfoState,
  type SessionInfoSectionId,
  type SessionInfoSections,
} from "./sessionInfoState";
import { OutputsSection } from "./OutputsSection";
import { sessionInfoLists, type SessionInfoProcess } from "./processes";
import type { OutputArtifact } from "./outputsSectionModel";
import { ServersSection } from "./ServersSection";
import { SubagentLimitStepper } from "./SubagentLimitStepper";
import { SubagentCountsMeta, SubagentsSection } from "./SubagentsSection";
import { AlsoHereSection } from "./AlsoHereSection";
import { useAlsoHere } from "./alsoHereSectionModel";
import { sessionStatus } from "./childSessionRowsModel";
import { chatOutputs } from "./chatOutputs";
import { producedLinks, type ProducedLink } from "./producedLinks";
import { openOnGitHub } from "./pullRequestDiff";
import { useMissingPaths } from "../chips/linkStore";
import { TasksSection } from "./TasksSection";
import { ProgressSection } from "./ProgressSection";
import { planDone, type SessionInfoPlan } from "./progressSectionModel";
import { attributeCommands } from "../summary/workflowView";
import { WorkflowTasks, type WorkflowAgentRowVariant } from "./WorkflowTasks";
import { UsageSection, type UsageOwnRowLayout } from "./UsageSection";
import { usageMeta } from "./usageSectionModel";
import { AppPanelSection, useAppPanelSections } from "../../../apps/scene/panels";
import type { AcpmuxSessionEntry } from "../sessionList";
import type { WorkflowAgent, WorkflowSummary } from "../summary/workflow";
import type { Subagent } from "../subagents/subagentFold";
import { subagentProgress } from "../subagents/subagentProgress";
import { type UsageEntry } from "./usageEntries";
import type { ChatPlace } from "../chatMachine";
import { samePanelProps } from "./samePanelProps";
import type { AlsoHere } from "./alsoHere";
import "./sessionInfo.css";
import {
  type SessionInfoPlacement,
  type RailLayout,
  DISMISS_KEEPERS,
  RAIL_LAYOUT,
  SESSION_INFO_TOGGLE,
  toolCallIds,
  openOutputFile,
} from "./sessionInfoModel";
import { tooltipProps } from "../shortcuts";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
/// A chat with no folders beside its own (one shared empty list, so the section's props keep their identity).
const NO_FOLDERS: readonly string[] = [];

/// How long a revealed section stays lit.
const REVEAL_LIT_MS = 1200;

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
  overlap = 0,
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
  /// Pushing, how much of its width and margin lies over the chat's own gutter instead of taking room
  /// from the chat (SessionInfo.tsx pushedRoom): a negative left margin (sessionInfo.css).
  overlap?: number;
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
  useCountedRender("session-info:panel");
  const t = useT();
  const frame = useRef<HTMLElement | null>(null);
  const drag = useRef<{ right: number } | undefined>(undefined);
  // Glass only where the chat runs under it: floating over the chat's column (a foot) or as a popover.
  // Pushed beside the chat, or in the empty gutter, its sections sit on the pane with no card behind
  // them, as the native panel draws it (#32661; Leo, 2026-11-02: "we still HAVE AN ASININE BACKGROUND").
  const glass = placement === "overlay" && (foot !== undefined || onDismiss !== undefined);
  // Floating over the chat (the narrow pane's Summary popover), the chat under it blurs itself there in
  // a see-through Chromium page (ui/glass/seeThroughBlur.ts), as WebKit's backdrop draws it, so its
  // text never reads through the glass (Leo 2026-10-30: "I don't like the non-glassness"). Pushing,
  // or in the gutter, it covers nothing.
  useSeeThroughBlur(frame, glass, chatUnderGlass, chatGlass);
  // The transcript leaves the panel's box out while it shows (chatCut.ts), so nothing scrolls under
  // it: its pixels hold still while the chat scrolls (Leo, 2026-11-03: "the session info thing not
  // flicker EVER when im scrolling"). Its place re-measures when it moves.
  useChatCut(frame, !presence?.leaving, `${placement}:${width}:${foot ?? ""}:${side}:${overlap}:${under ?? ""}`);
  // The foot animates only once it has been drawn at its first measure: the open draws it at once.
  const footKnown = foot !== undefined && foot > 0;
  // Only a foot that goes down (the composer's stack shrank) glides. One that rises (the stack grew: the
  // running tray coming in, a queued prompt, a taller draft) moves in the frame the stack moved, with it:
  // gliding, the card's lower part lay over the grown stack for the glide, and that overlap switched
  // its glass between the App's and the page's own (data-glass-keeps-underlay, seeThroughBlur.ts) and
  // back, a flash each time a tool call brought the tray in or out (Leo, 2026-11-07: "im still seeing
  // session info flash ... when im slowly scrolling down as you're doing the thinking/tool calls").
  const [footWas, setFootWas] = useState(foot);
  const [footRises, setFootRises] = useState(false);
  if (foot !== footWas) {
    setFootWas(foot);
    setFootRises(foot !== undefined && footWas !== undefined && foot > footWas);
  }
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
      if (target.closest(SESSION_INFO_TOGGLE)) return;
      const layer = target.closest(DISMISS_KEEPERS);
      // A containing dialog is below this panel, so pressing its content can dismiss the panel.
      if (layer && !layer.contains(frame.current)) return;
      // Capture precedes a child popup's outside-press handler. Let that popup consume this
      // dismissal even though its popup is portalled; only triggers owned by this panel count.
      if (frame.current?.querySelector('[aria-haspopup][data-popup-open], [aria-haspopup][aria-expanded="true"]'))
        return;
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
      className={glass ? "ui-glass ui-glass-floats acpmux-session-info" : "acpmux-session-info"}
      // Its glass is the App's own popover glass, drawn under the page (ui/glass/hostGlass.ts; Leo,
      // 2026-11-06: "the f***ing session info. Like, wait, why the f*** is this not glass?").
      data-host-glass={glass ? "popover" : undefined}
      data-placement={placement}
      data-chrome={title ? "title" : onClose ? chrome : "none"}
      data-over-chat={foot !== undefined ? "" : undefined}
      data-popover={onDismiss ? "" : undefined}
      data-foot-moves={footKnown && footSettled && !footRises ? "" : undefined}
      style={
        {
          width,
          // Pushing, its enter and exit run its right margin from minus this (sessionInfo.css).
          "--acpmux-session-info-width": `${width}px`,
          ...(under ? { "--acpmux-session-info-top": under } : {}),
          ...(foot !== undefined ? { "--acpmux-session-info-foot": `${foot}px` } : {}),
          ...(side > 0 ? { "--acpmux-session-info-side": `${side}px` } : {}),
          ...(overlap > 0 ? { "--acpmux-session-info-overlap": `${overlap}px` } : {}),
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

/// The panel frame for SessionInfoPresence, drawn again only when what it is handed changes
/// (samePanelProps.ts): a snapshot that changes nothing it draws leaves the frame and its sections be.
export const MemoSessionInfoPanel = memo(function MemoSessionInfoPanel(props: Parameters<typeof SessionInfoPanel>[0]) {
  return <SessionInfoPanel {...props} />;
}, samePanelProps);

/// The sections for one chat, drawn again only when a prop changes: SessionInfoPresence hands it the
/// same lists while they hold the same things, so a streamed token, a tool call that makes nothing or a
/// usage tick draws nothing here.
export const MemoSessionInfoSections = memo(function MemoSessionInfoSections(props: Parameters<typeof SessionInfo>[0]) {
  useCountedRender("session-info:sections");
  return <SessionInfo {...props} />;
});

/// The sections for one chat.
export function SessionInfo({
  summary,
  machineName,
  peerKinds,
  place,
  repository,
  cloudRepositoryAvailable,
  made,
  artifacts = 0,
  documents = [],
  rows = [],
  outputFiles,
  produced: givenProduced,
  plan,
  toolCalls,
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
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  readPromptImage,
  onOpenDocument,
  remoteControl,
  onSaveEnvironment,
  onReconnectMcp,
  onCompact,
  onViewPrompt,
  onOpenFolder,
  edits,
  onOpenChanges,
  onOpenOutputFile,
  onShowCall,
  allSessions,
  usageSessions = allSessions,
  alsoHere: shownAlsoHere,
  onOpenChat,
  onShowUsage,
  usageOwnRowLayout,
  usageCacheLayout,
  banner,
  agent,
  layout = RAIL_LAYOUT,
  projectRowLook,
  remoteControlIcon,
  more,
  onMore,
  compactLook = "more",
  imessage: imessageFixture,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The page's route to the chat (chatMachine.ts `chatPlace`).
  place?: ChatPlace;
  repository?: string;
  cloudRepositoryAvailable?: boolean;
  /// What the chat produced (sessionSummary).
  made?: Pick<SessionSummary, "outputs" | "pullRequests" | "scheduled"> & Partial<Pick<SessionSummary, "sources">>;
  artifacts?: number;
  /// The documents the chat produced (OutputsSection `outputArtifacts`).
  documents?: readonly OutputArtifact[];
  /// Opens a document in the side panel beside the chat.
  onOpenDocument?: (artifact: Artifact) => void;
  /// The chat's rows, for its gallery.
  rows?: readonly AcpmuxRow[];
  /// What the chat made for the person (chatOutputs.ts), where the caller reads it; else read from `rows`.
  outputFiles?: ReturnType<typeof chatOutputs>;
  /// The pull requests, issues and commits the chat produced (producedLinks.ts), where the caller reads
  /// them; else read from `rows`.
  produced?: readonly ProducedLink[];
  /// The agent's current plan (ProgressSection.tsx `currentPlan`); without one, no Progress.
  plan?: SessionInfoPlan;
  /// The tool calls the loaded transcript holds (toolCallIds), where the caller reads them; else read
  /// from `rows`.
  toolCalls?: ReadonlySet<string>;
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
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  /// A pasted image's bytes by its id, for its Sources row (direct.ts `promptImage`).
  readPromptImage?: (id: string) => Promise<string | undefined>;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onSaveEnvironment?: () => Promise<unknown> | void;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Sends the chat's agent its `/compact`: Context's Compact session (ContextSection), live while a
  /// turn runs (the /compact queues behind it), and Usage's next step for its context (UsageSection.tsx).
  onCompact?: () => void;
  /// Context's View Prompt (useSessionInfo's).
  onViewPrompt?: () => void;
  /// Every chat acpmux lists, this Mac's and its peers', for Usage (UsageSection.tsx); unset in a
  /// subagent's own panel.
  allSessions?: readonly AcpmuxSessionEntry[];
  /// In place of `allSessions`, what the sections draw of it (SessionInfoPresence): Usage's chats
  /// (usageEntries.ts) and the chats working here (alsoHere.ts).
  usageSessions?: readonly UsageEntry[];
  alsoHere?: readonly AlsoHere[];
  /// Opens one of them.
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  /// Gallery-only alternatives for the Usage section's own-metrics leading column.
  usageOwnRowLayout?: UsageOwnRowLayout;
  /// Gallery-only alternatives for Usage's prompt cache numbers (two rows, or one).
  usageCacheLayout?: UsageCacheLayout;
  /// Opens the chat's project folder in the Files tree beside the chat.
  onOpenFolder?: (path: string) => void;
  /// Opens an Outputs file (the panel's own: Session Info steps aside for it); the host's path open
  /// without it.
  onOpenOutputFile?: (path: string) => void;
  /// The chat folder's git changes (changeCounts.ts): Environment's Changes row, with `onOpenChanges`
  /// opening the chat folder's diff beside the chat.
  edits?: { additions: number; deletions: number };
  onOpenChanges?: () => void;
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
  /// The panel's Show more is open (its less-used sections show); the pane's saved choice without it.
  more?: boolean;
  onMore?: (more: boolean) => void;
  /// How the default view stays short (SessionInfoGroup.tsx); the gallery shows the others.
  compactLook?: SessionInfoCompactLook;
  /// Gallery fixtures; false suppresses the Mac-only connector.
  imessage?: IMessageView | false;
}) {
  const t = useT();
  const liveIMessage = useIMessage(imessageFixture === undefined);
  const imessage = imessageFixture || liveIMessage;
  const language = usePaneLanguage();
  const sessionInfoState = useSessionInfoState();
  const showMore = more ?? sessionInfoState.more;
  const setMore = onMore ?? setSessionInfoMore;
  const stored = sessionInfoState.sections;
  const state = sections ?? stored;
  const fold = (id: SessionInfoSectionId) => (next: boolean) => (onSection ?? setSessionInfoSection)(id, next);
  const imessageStatus = imessage?.data.status;
  useEffect(() => {
    if (!imessageStatus || imessageStatus === "connected" || !claimSessionInfoIMessageReveal()) return;
    (onSection ?? setSessionInfoSection)("connectors", true);
  }, [imessageStatus, onSection]);
  useEffect(() => {
    if (imessage?.expanded) (onSection ?? setSessionInfoSection)("connectors", true);
  }, [imessage?.expanded, onSection]);
  const [gallery, setGallery] = useState(false);
  const usage = compactingUsage(summary?.usage, summary?.usageStats, summary?.contextBreakdown);
  const known = usage !== undefined && usage.size > 0;
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const percent = known ? Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) : 0;
  const { servers, tasks: commands } = sessionInfoLists(processes, transcriptTasks, listed);
  // A chat on this Mac opens a task's terminal; elsewhere a row shows the call that started it,
  // when the loaded transcript holds it. A wakeup or cron job shows the call that made it on any
  // chat (TasksSection `scheduledRow`). Read only then, so a local chat with nothing scheduled adds
  // no pass over its rows.
  const local = opensProcessTerminal(summary);
  const showsCalls =
    !!onShowCall && ((!local && commands.some((command) => command.toolCallId)) || (made?.scheduled?.length ?? 0) > 0);
  const calls = useMemo(
    () => (showsCalls ? (toolCalls ?? toolCallIds(rows)) : undefined),
    [showsCalls, toolCalls, rows],
  );
  const body = useRef<HTMLDivElement>(null);
  // Rows scrolled past the body's top or bottom fade at that edge (scrollEdges.ts, sessionInfo.css)
  // instead of being cut off. It stops following when the body unmounts.
  const edges = useScrollEdges();
  const bodyRef = useCallback(
    (node: HTMLDivElement | null) => {
      body.current = node;
      edges(node);
    },
    [edges],
  );
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
    // A section behind Show more: Show more opens first, and the reveal lights it once drawn.
    if (compactLook === "more" && !showMore && tuckedSections([revealed.section], sectionOrder()).length > 0) {
      setMore(true);
      return;
    }
    light(revealed.section);
    onRevealed?.();
  }, [revealed, onRevealed, light, compactLook, showMore, setMore]);
  // Usage's Show: Subagents opens, comes into view and lights, as a reveal does.
  const showSubagents = useCallback(() => {
    (onSection ?? setSessionInfoSection)("subagents", true);
    light("subagents");
  }, [onSection, light]);
  // The panel shows: Usage's numbers are read now, not left at whatever the list last carried.
  useEffect(() => onShowUsage?.(), [onShowUsage]);
  const anyUsage = useMemo(() => !!usageSessions?.some((entry) => entry.usageStats), [usageSessions]);
  const scheduled = made?.scheduled ?? [];
  const pullRequests = visibleChanges(made?.pullRequests ?? [], statuses);
  const sources = made?.sources ?? [];
  const folders = summary?.additionalDirectories ?? NO_FOLDERS;
  // What the chat made for the person (chatOutputs.ts): the documents its replies link to and the
  // deliverables its file tools created, never its code edits (the Changes row has those).
  const cwd = summary?.cwd;
  const madeFiles = useMemo(() => outputFiles ?? chatOutputs(rows, cwd), [outputFiles, rows, cwd]);
  const produced = useMemo(() => givenProduced ?? producedLinks(rows, repository), [givenProduced, rows, repository]);
  // A file made and then deleted drops off, as the host answers for it (only on this Mac: another
  // machine's files are asked about nowhere).
  const missing = useMissingPaths(
    useMemo(() => (local ? madeFiles.map((output) => output.path) : []), [local, madeFiles]),
  );
  const outputs = useMemo(
    () => (missing.size === 0 ? madeFiles : madeFiles.filter((output) => !missing.has(output.path))),
    [madeFiles, missing],
  );
  const mcp = summary?.mcpServers ?? [];
  const connectorSummary = summarizeConnectors(mcp);
  const runningTasks = commands.filter((command) => command.state === "running").length;
  // Subagents shows only for a chat that has subagents or started chats: one that never used them
  // shows nothing.
  const limits = summary?.subsessionLimits;
  const chatId = summary?.sessionId;
  const appPanels = useAppPanelSections(
    chatId
      ? { session_id: chatId, cwd: summary?.cwd ?? "", branch: summary?.branch, harness: summary?.harness }
      : undefined,
  );
  const [appOpen, setAppOpen] = useState<Record<string, boolean>>({});
  const appNodes = Object.fromEntries(
    appPanels.map((section) => [
      section.id,
      <AppPanelSection
        key={section.id}
        section={section}
        open={appOpen[section.id] ?? true}
        onOpenChange={(open) => setAppOpen((current) => ({ ...current, [section.id]: open }))}
      />,
    ]),
  );
  // A chat on another machine: its sub-sessions live on that machine's acpmux, which takes the
  // limit only from its own person, so the line only reads.
  const setRunningLimit =
    onSetRunningLimit && chatId && !summary?.peer
      ? (maxRunning: number | null, from?: number) => onSetRunningLimit(chatId, maxRunning, from)
      : undefined;
  const progress = !known && agent ? subagentProgress(t, language, agent) : [];
  const value = (text: string) => <span className="acpmux-session-info-section__value">{text}</span>;
  const glance = layout === "glance";
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
        place={place}
        repository={repository}
        cloudRepositoryAvailable={cloudRepositoryAvailable}
        remoteControl={remoteControl}
        // No grant rows: Revoke Granted Access in the chat menu lists them (Lucas, 2026-11-05: ChatGPT's
        // panel has none, and "Trusted this chat's private folder" read as noise).
        onSave={onSaveEnvironment}
        onOpenFolder={onOpenFolder}
        edits={edits}
        onOpenChanges={onOpenChanges}
        projectLook={projectRowLook}
        remoteControlIcon={remoteControlIcon}
      />
    </SessionInfoSection>
  );
  // Context is one line, the window's share on a meter and its tokens used of its size; a click unfolds
  // its breakdown from Messages down (Lucas, 2026-11-06: "clicking on context should no longer open the
  // context modal. instead it will just expand"). The composer's context card's Details opens Session
  // Info on it, unfolded and lit (App.tsx `onOpenContext`, as main has it).
  const contextTokens = new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 });
  const context = known ? (
    <SessionInfoSection
      id="context"
      title={t("rail.context")}
      open={state.context}
      onOpenChange={fold("context")}
      meta={
        <>
          <span className="acpmux-session-info-meter" aria-hidden="true">
            <span style={{ width: `${percent}%` }} />
          </span>
          {value(`${contextTokens.format(usage.used)} / ${contextTokens.format(usage.size)}`)}
        </>
      }
    >
      <ContextSection
        usage={usage}
        percent={percent}
        breakdown={summary?.contextBreakdown}
        rowsOnly
        onViewPrompt={onViewPrompt}
      />
    </SessionInfoSection>
  ) : (
    progress.length > 0 && (
      <SessionInfoSection id="context" title={t("rail.context")} open meta={value(progress.join(" · "))} />
    )
  );
  // Usage and Connectors always show in the chat's own panel, folded, so the list under the Show more
  // line reads the same in every chat (Lucas, 2026-11-05). With nothing to list, one plain line: None.
  const hasConnectors = mcp.length > 0 || !!imessage;
  const connectors = (hasConnectors || !agent) && (
    <SessionInfoSection
      id="connectors"
      title={t("rail.connectors")}
      open={hasConnectors && state.connectors}
      onOpenChange={hasConnectors ? fold("connectors") : undefined}
      // This count describes the attached harness inventory. A loaded MCP server is not proof
      // of provider authentication or authorization, so never present it as a green connected count.
      meta={value(
        !hasConnectors
          ? t("sessionInfo.none")
          : mcp.length === 0 && imessage
            ? imessage.data.status === "connected"
              ? t("rail.connected", { count: 1 })
              : t("imessage.connect")
            : connectorSummary.kind === "reconnect"
              ? t("sessionInfo.connectors.reconnect", { count: connectorSummary.count })
              : connectorSummary.kind === "connecting"
                ? t("sessionInfo.connectors.connecting", { count: connectorSummary.count })
                : t("sessionInfo.connectors.loaded", { count: connectorSummary.count }),
      )}
    >
      <ConnectorsSection servers={mcp} onReconnect={onReconnectMcp} imessage={imessage} />
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
  const sourcesSection = sources.length + folders.length > 0 && (
    <SessionInfoSection
      id="sources"
      title={t("summary.sources")}
      open={state.sources}
      onOpenChange={fold("sources")}
      meta={value(String(sources.length + folders.length))}
    >
      <SourcesSection
        sources={sources}
        folders={folders}
        cwd={summary?.cwd}
        onOpenFile={onOpenSourceFile}
        onOpenBeside={onOpenUrl}
        onOpenImage={onOpenImage}
        readImage={readPromptImage}
        expanded={sessionInfoState.sourcesAll}
        onExpandedChange={setSessionInfoSourcesAll}
      />
    </SessionInfoSection>
  );
  // The rows Outputs lists (OutputsSection): its documents, the gallery's one row and its files.
  const outputCount =
    produced.length +
    outputs.length +
    (onOpenDocument ? documents.length : 0) +
    (artifacts > 0 && rows.length > 0 ? 1 : 0);
  const outputsShown = produced.length + outputs.length + artifacts + (onOpenDocument ? documents.length : 0) > 0;
  const outputsSection = outputsShown && (
    <SessionInfoSection
      id="outputs"
      title={t("rail.outputs")}
      open={state.outputs}
      onOpenChange={fold("outputs")}
      meta={outputCount > 0 ? value(String(outputCount)) : undefined}
    >
      <OutputsSection
        produced={produced}
        repository={repository}
        onOpenProduced={openOnGitHub}
        files={outputs}
        artifacts={artifacts}
        documents={documents}
        onOpenDocument={onOpenDocument}
        // Opens as the reply's path chip opens it (chips/LinkChips.tsx): through the host, which checks
        // the path; a chat on another machine has its files there, so they only read.
        onOpenFile={local ? (onOpenOutputFile ?? ((path) => void openOutputFile(path))) : undefined}
        onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
      />
    </SessionInfoSection>
  );
  // The agent's plan, live: its steps done of its steps, on Context's meter.
  const planSteps = plan?.entries.length ?? 0;
  const stepsDone = plan ? planDone(plan) : 0;
  const progressSection = plan && planSteps > 0 && (
    <SessionInfoSection
      id="progress"
      title={t("sessionInfo.progress")}
      open={state.progress ?? true}
      onOpenChange={fold("progress")}
      meta={
        <>
          {value(t("sessionInfo.progress.count", { done: stepsDone, total: planSteps }))}
          <span className="acpmux-session-info-meter" aria-hidden="true">
            <span style={{ width: `${Math.round((stepsDone / planSteps) * 100)}%` }} />
          </span>
        </>
      }
    >
      <ProgressSection plan={plan} />
    </SessionInfoSection>
  );
  // A workflow Background tasks lists (Labs) is not a Subagents row too.
  const workflowIds = new Set(workflows.map((workflow) => workflow.id));
  const listedAgents = workflowIds.size > 0 ? agents.filter((agent) => !workflowIds.has(agent.id)) : agents;
  // The running limit's line ("Started chats: 2 of 16 at once") shows only while started chats run or
  // wait for a slot: it counts started chats, not subagents, so beside subagents alone it read as
  // theirs (Lucas, 2026-11-05, Session Info lab: "we should hide it by default then").
  const limitInUse = sessions.some((child) => child.waitsForSlot || sessionStatus(child) === "running");
  const subagentsSection = listedAgents.length + sessions.length > 0 && (
    <SessionInfoSection
      id="subagents"
      title={t("summary.subagents")}
      open={state.subagents}
      onOpenChange={fold("subagents")}
      meta={<SubagentCountsMeta agents={listedAgents} waiting={waiting} sessions={sessions} />}
    >
      {limitInUse && (
        <SubagentLimitStepper chatId={chatId} limits={limits} sessions={sessions} onSet={setRunningLimit} />
      )}
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
  // A command a workflow's agent started is listed under that agent, not as the chat's own.
  const { own: ownCommands, workflows: workflowCommands } = attributeCommands(commands, workflows);
  // The other chats in this chat's worktree or on its branch (alsoHere.ts), shown only when there are.
  // A chat that goes a day idle leaves the list while Session Info stays open (useAlsoHere).
  const ownAlsoHere = useAlsoHere(chatId, shownAlsoHere ? undefined : allSessions);
  const alsoHereRows = shownAlsoHere ?? ownAlsoHere;
  const alsoHereSection = alsoHereRows.length > 0 && (
    <SessionInfoSection
      id="alsoHere"
      title={t("sessionInfo.alsoHere")}
      open={state.alsoHere}
      onOpenChange={fold("alsoHere")}
      meta={value(String(alsoHereRows.length))}
    >
      <AlsoHereSection rows={alsoHereRows} onOpen={onOpenChat} />
    </SessionInfoSection>
  );
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
          commands={workflowCommands}
          onStopCommand={onStopProcess}
          onStop={onStopWorkflow}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
          agentRowVariant={workflowAgentRowVariant}
        />
      )}
      {servers.length > 0 && <ServersSection servers={servers} onStop={onStopProcess} onOpenUrl={onOpenUrl} />}
      {ownCommands.length + scheduled.length > 0 && (
        <TasksSection
          commands={ownCommands}
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
  const planLimits = typeof summary?.usageLimits === "object" ? summary.usageLimits : undefined;
  // acpmux reads a chat's spend from its harness records, so a new chat has none for a few minutes.
  const hasUsage = Boolean(ownUsage || anyUsage || planLimits);
  const usageSection = (hasUsage || !agent) && (
    <SessionInfoSection
      id="usage"
      title={t("sessionInfo.usage")}
      open={hasUsage && state.usage}
      onOpenChange={hasUsage ? fold("usage") : undefined}
      // No number of its own while another chat reports some: no value rather than a made-up one.
      meta={hasUsage ? usageValue && value(usageValue) : value(t("sessionInfo.none"))}
    >
      <UsageSection
        own={ownUsage}
        planLimits={planLimits}
        sessions={usageSessions ?? []}
        chatId={chatId}
        onOpen={onOpenChat}
        onCompact={onCompact}
        onShowSubagents={subagentsSection ? showSubagents : undefined}
        locale={language}
        ownRowLayout={usageOwnRowLayout}
        cacheLayout={usageCacheLayout}
      />
    </SessionInfoSection>
  );
  return (
    <div ref={bodyRef} className="acpmux-session-info__body" data-layout={layout}>
      {banner}
      {/* Where it runs, what it made, what it runs: one order the person drags (SessionInfoGroup.tsx). */}
      <SessionInfoSectionList
        look={compactLook}
        more={compactLook !== "more" || showMore}
        onMoreChange={compactLook === "more" ? setMore : undefined}
        sections={{
          environment,
          context,
          usage: usageSection,
          connectors,
          changes,
          sources: sourcesSection,
          outputs: outputsSection,
          progress: progressSection,
          subagents: subagentsSection,
          tasks,
          alsoHere: alsoHereSection,
          ...appNodes,
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
