// The Inspector: the right-hand panel of an agent chat, Chief included, opened by the header's
// top-right toggle (Claude Code desktop calls its own the session rail, ChatGPT its pinned
// summary). Leo, 2026-10-20: take the facts Claude Code's panel shows and ChatGPT's subagents row.
// Top to bottom, each section folding:
//
// - Environment: the machine, the folder, the repository, the branch or worktree (EnvironmentSection).
// - Context: how much of the context window the chat used, with a bar; open, the token counts.
// - Connectors: the MCP servers its harness loaded, with how many need reconnecting.
// - Changes: the pull requests it opened or touched (ChangesSection).
// - Servers: the dev servers it runs in the background (ServersSection).
// - Subagents: an avatar row with live counts that opens into the list: the harness's subagents and
//   the chats its agent started, a Cloud VM's or another machine's included (SubagentsSection).
// - Background tasks: its other background commands, the ones only the transcript knows included,
//   and its wakeups (TasksSection).
// - Outputs: the files, artifacts and links it produced (OutputsSection).
//
// Open, it pushes the chat aside and the chat reflows (Settings > Agent Chat > Inspector), unless
// the pane is too narrow for the chat beside it, when it lies over the chat instead; Overlay
// always lies over it. Its left edge drags to resize it. Open, width and folds are the viewer's
// and hold in every chat tab (inspectorState.ts). Debug Settings `agent.inspector` (on by default)
// turns it off, which brings back the summary card it replaces (summary/SummaryCard.tsx). It reads
// only acpmux's common snapshot and the App's header state, never one harness's own fields.
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
import { usePresence, type Presence } from "../../../ui/presence";
import { useChatDisplay } from "../chatDisplay";
import { HEADER_GLYPH } from "../header/ChatHeaderTools";
import { useHeaderState, type HeaderPullRequest } from "../header/headerState";
import { useTabRow } from "../header/tabRow";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { registerPicker } from "../pickerOpeners";
import { subagentsIn } from "../subagents/subagentRows";
import { chatGallery } from "../summary/chatGallery";
import { GalleryDialog } from "../summary/GalleryDialog";
import { sessionSummary, type SessionSummary, type SummaryBackgroundTask } from "../summary/sessionSummary";
import { waitingSubagents } from "../summary/SubagentStatusList";
import type { TurnFile } from "../diff";
import type { StartedSession } from "../started/startedSessions";
import { ChangesSection, headerStatus, type InspectorPullRequestStatus } from "./ChangesSection";
import { ContextSection } from "./ContextSection";
import { EnvironmentSection } from "./EnvironmentSection";
import { InspectorSection } from "./InspectorSection";
import {
  INSPECTOR_WIDTH,
  setInspectorOpen,
  setInspectorSection,
  setInspectorWidth,
  useInspectorOpen,
  useInspectorState,
  type InspectorSectionId,
  type InspectorSections,
} from "./inspectorState";
import { OutputsSection, outputLinks, type OutputLink } from "./OutputsSection";
import { inspectorLists, type InspectorProcess, type ProcessRegistry } from "./processes";
import { ServersSection } from "./ServersSection";
import { SubagentsSection, subagentCounts } from "./SubagentsSection";
import { TasksSection } from "./TasksSection";
import type { Subagent } from "../subagents/subagentFold";
import "./inspector.css";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
export type InspectorPlacement = "push" | "overlay";

/// The narrowest chat column the Inspector pushes aside; below it, it lies over the chat.
export const PUSH_MIN_CHAT = 440;
/// How long after an output click a narrowing counts as that diff's split.
const SPLIT_SETTLE_MS = 2000;

/// Whether the Inspector pushes the chat: the setting, unless the pane can't keep a readable chat
/// beside it.
export const pushes = (placement: InspectorPlacement, paneWidth: number, width: number) =>
  placement === "push" && (paneWidth <= 0 || paneWidth - width >= PUSH_MIN_CHAT);

/// The pane's width, followed as it resizes; 0 before it is measured.
function usePaneWidth(shell: HTMLElement | null | undefined, live: boolean): number {
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    if (!shell || !live) return;
    const measure = () => setWidth(shell.clientWidth);
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(shell);
    return () => observer.disconnect();
  }, [shell, live]);
  return width;
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
  onOpenUrl,
  onOpenImage,
  processes: registry,
  onStopProcess,
  subagents,
  sessions,
}: {
  snapshot: AcpmuxSnapshot;
  /// This Mac's name from the handshake, for a local chat.
  machineName?: string;
  /// The chat folder's GitHub repository (`git.githubRepository`), `owner/name`.
  repository?: string;
  /// The pane's shell: the Inspector measures it to choose push or overlay.
  shell?: HTMLElement | null;
  /// Opens a file's diff (App.tsx openOutput: beside the chat, else in place).
  onOpenOutput?: (path: string) => void;
  /// Opens a web address in the browser beside the chat (a server's port, a pull request).
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
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
}): {
  on: boolean;
  button?: ReactNode;
  panel?: ReactNode;
  // Opens the Inspector with `section` unfolded (the running line's counts: App.tsx).
  reveal?: (section: InspectorSectionId) => void;
} {
  const t = useT();
  const { inspector: on, pullRequest } = useHeaderState();
  // Open alone: the width and the folds are the panel's (InspectorPresence), so a drag step or a fold
  // does not draw the whole chat pane again.
  const open = useInspectorOpen();
  // Closed for now (not remembered): an output's diff split left no room beside the chat.
  const [suppressed, setSuppressed] = useState(false);
  const suppress = useCallback(() => setSuppressed(true), []);
  const shown = on && open && !suppressed;
  // The section a running line's count asked for, scrolled to once drawn.
  const [revealed, setRevealed] = useState<{ section: InspectorSectionId; at: number }>();
  const clearRevealed = useCallback(() => setRevealed(undefined), []);
  const openedOutputAt = useRef(0);
  const label = t("chatInspector.title");
  useEffect(() => {
    if (!on) return;
    return registerPicker(label, () => {
      setSuppressed(false);
      setInspectorOpen(true);
    });
  }, [on, label]);
  if (!on) return { on: false };
  const toggle = () => {
    if (shown) setInspectorOpen(false);
    else {
      setSuppressed(false);
      setInspectorOpen(true);
    }
  };
  const reveal = (section: InspectorSectionId) => {
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
    reveal,
    button: (
      <button
        type="button"
        className="acpmux-header-tool acpmux-chat-inspector-toggle"
        aria-label={label}
        aria-pressed={shown}
        title={label}
        onClick={toggle}
      >
        <Icon name="view.inspector" size={HEADER_GLYPH} />
      </button>
    ),
    panel: (
      <InspectorPresence
        shown={shown}
        snapshot={snapshot}
        pullRequest={pullRequest}
        machineName={machineName}
        repository={repository}
        shell={shell}
        openedOutputAt={openedOutputAt}
        onSuppress={suppress}
        registry={registry}
        subagents={subagents}
        sessions={sessions}
        revealed={revealed}
        onRevealed={clearRevealed}
        onStopProcess={onStopProcess}
        onOpenOutput={openOutput}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
      />
    ),
  };
}

/// The Inspector while it is drawn: its presence, its width and folds, its push or overlay and what
/// it lists. Its own component, so its enter and exit phases, a drag step and a fold draw the panel
/// alone, not the chat pane that calls useChatInspector (one Inspector open drew that pane five
/// times in a frame).
function InspectorPresence({
  shown,
  snapshot,
  pullRequest,
  machineName,
  repository,
  shell,
  openedOutputAt,
  onSuppress,
  registry,
  subagents,
  sessions,
  revealed,
  onRevealed,
  onStopProcess,
  onOpenOutput,
  onOpenUrl,
  onOpenImage,
}: {
  shown: boolean;
  snapshot: AcpmuxSnapshot;
  /// What the App read of the chat's pull requests (header state), which the hook already follows.
  pullRequest: HeaderPullRequest | undefined;
  machineName?: string;
  repository?: string;
  shell?: HTMLElement | null;
  /// When an output's diff was last opened (Date.now()).
  openedOutputAt: { readonly current: number };
  /// That diff's split left no room to push the chat: the Inspector steps aside.
  onSuppress: () => void;
  registry?: ProcessRegistry;
  subagents?: {
    views: Record<string, AcpmuxRow[]> | undefined;
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
  };
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  revealed?: { section: InspectorSectionId; at: number };
  onRevealed: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  onOpenOutput?: (path: string) => void;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
}) {
  const { width, sections } = useInspectorState();
  const placement = useChatDisplay().inspector;
  // It slides in from the pane's right edge and back out (ui/presence.ts), keeping its sections
  // while it leaves.
  const presence = usePresence(shown, "right");
  const drawn = presence.present;
  const paneWidth = usePaneWidth(shell, drawn);
  const push = pushes(placement, paneWidth, width);
  const tabRowHeight = useTabRow().height;
  const rows = snapshot.rows;
  const made = useMemo(() => (drawn ? sessionSummary(rows) : undefined), [drawn, rows]);
  const links = useMemo(() => (drawn ? outputLinks(rows) : []), [drawn, rows]);
  const artifacts = useMemo(() => (drawn ? chatGallery(rows).length : 0), [drawn, rows]);
  const views = subagents?.views;
  const asks = subagents?.asks;
  const agents = useMemo(() => (drawn ? [...subagentsIn(rows, views).values()] : []), [drawn, rows, views]);
  const waiting = useMemo(
    () => (drawn && asks ? waitingSubagents(asks, views) : new Set<string>()),
    [drawn, asks, views],
  );
  const statuses = useMemo(() => headerStatus(pullRequest), [pullRequest]);
  // An output's diff opens beside the chat. When that split leaves too little room to push the
  // chat, the Inspector would cover it, so it steps aside until the toggle opens it again.
  const pushRef = useRef(push);
  useEffect(() => {
    const was = pushRef.current;
    pushRef.current = push;
    if (was && !push && placement === "push" && Date.now() - openedOutputAt.current < SPLIT_SETTLE_MS) onSuppress();
  }, [push, placement, openedOutputAt, onSuppress]);
  if (!drawn) return null;
  return (
    <InspectorPanel
      width={width}
      placement={push ? "push" : "overlay"}
      // Over the chat it starts under the chat header (styles.css --acpmux-header-height; in the
      // pane's tab row, the row's height), so the header's tools, its own toggle among them, stay in reach.
      under={tabRowHeight > 0 ? `${tabRowHeight}px` : "var(--acpmux-header-height, 44px)"}
      presence={presence}
    >
      {/* Another chat's sections start drawn with what that chat has: none of its rows drops in. */}
      <ChatInspector
        key={snapshot.sessionId}
        summary={snapshot.summary}
        machineName={machineName}
        peerKinds={snapshot.peerKinds}
        repository={repository}
        made={made}
        links={links}
        artifacts={artifacts}
        rows={rows}
        agents={agents}
        waiting={waiting}
        onOpenSubagent={subagents?.onOpen}
        statuses={statuses}
        processes={registry?.processes}
        listed={registry?.listed}
        transcriptTasks={made?.backgroundTasks}
        sessions={sessions?.list}
        onOpenSession={sessions?.onOpen}
        revealed={revealed}
        onRevealed={onRevealed}
        onStopProcess={onStopProcess}
        sections={sections}
        onSection={setInspectorSection}
        onOpenOutput={onOpenOutput}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
      />
    </InspectorPanel>
  );
}

/// The panel's frame: its width, its place beside or over the chat, and the drag handle on its
/// left edge (a double-click puts the width back). With `presence`, it enters from and leaves toward
/// the pane's right edge. Over the chat it starts `under` (a CSS length: the chat header's height)
/// below the pane's top, at the top by default.
export function InspectorPanel({
  width,
  placement,
  under,
  presence,
  children,
}: {
  width: number;
  placement: InspectorPlacement;
  under?: string;
  presence?: Presence;
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
      className={placement === "overlay" ? "ui-glass acpmux-chat-inspector" : "acpmux-chat-inspector"}
      data-placement={placement}
      style={under ? ({ width, "--acpmux-inspector-top": under } as CSSProperties) : { width }}
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
      {children}
    </aside>
  );
}

/// The sections for one chat.
export function ChatInspector({
  summary,
  machineName,
  peerKinds,
  repository,
  made,
  links = [],
  artifacts = 0,
  rows = [],
  agents = [],
  waiting = new Set(),
  onOpenSubagent,
  statuses = {},
  processes = [],
  listed = false,
  transcriptTasks = [],
  sessions = [],
  onOpenSession,
  revealed,
  onRevealed,
  onStopProcess,
  sections,
  onSection,
  onOpenOutput,
  onOpenUrl,
  onOpenImage,
  remoteControl,
  onSaveEnvironment,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  repository?: string;
  /// What the chat produced (sessionSummary).
  made?: Pick<SessionSummary, "outputs" | "pullRequests" | "scheduled">;
  links?: readonly OutputLink[];
  artifacts?: number;
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
  /// The section a running line's count opened: scrolled into view (`at` tells one ask from the next).
  revealed?: { section: InspectorSectionId; at: number };
  /// The reveal has scrolled: the caller forgets it.
  onRevealed?: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  /// Which sections are open; uncontrolled without `onSection`.
  sections?: InspectorSections;
  onSection?: (id: InspectorSectionId, open: boolean) => void;
  onOpenOutput?: (path: string) => void;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onSaveEnvironment?: () => void;
}) {
  const t = useT();
  const stored = useInspectorState().sections;
  const state = sections ?? stored;
  const fold = (id: InspectorSectionId) => (next: boolean) => (onSection ?? setInspectorSection)(id, next);
  const [gallery, setGallery] = useState(false);
  const usage = summary?.usage;
  const known = usage !== undefined && usage.size > 0;
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const percent = known ? Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) : 0;
  const { servers, tasks: commands } = inspectorLists(processes, transcriptTasks, listed);
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
  const pullRequests = made?.pullRequests ?? [];
  const outputs = (made?.outputs ?? []) as readonly TurnFile[];
  const mcp = summary?.mcpServers ?? [];
  const reconnect = mcp.filter((server) => server.status === "failed").length;
  const runningTasks = commands.filter((command) => command.state === "running").length;
  const value = (text: string) => <span className="acpmux-chat-inspector-section__value">{text}</span>;
  return (
    <div ref={body} className="acpmux-chat-inspector__body">
      <InspectorSection
        id="environment"
        title={t("rail.environment")}
        open={state.environment}
        onOpenChange={fold("environment")}
      >
        <EnvironmentSection
          summary={summary}
          machineName={machineName}
          peerKinds={peerKinds}
          repository={repository}
          remoteControl={remoteControl}
          onSave={onSaveEnvironment}
        />
      </InspectorSection>
      {known && (
        <InspectorSection
          id="context"
          title={t("rail.context")}
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
          <ContextSection usage={usage} percent={percent} />
        </InspectorSection>
      )}
      {mcp.length > 0 && (
        <InspectorSection
          id="connectors"
          title={t("rail.connectors")}
          open={state.connectors}
          onOpenChange={fold("connectors")}
          // As Claude Code desktop's: the servers to reconnect when any failed, else the connected ones.
          meta={value(
            reconnect > 0
              ? t("chatInspector.connectors.reconnect", { count: reconnect })
              : t("rail.connected", { count: mcp.filter((server) => server.status === "connected").length }),
          )}
        >
          <ul className="acpmux-chat-inspector-list">
            {mcp.map((server) => (
              <li key={server.name} className="acpmux-chat-inspector-row">
                <Icon name="extension" size={12} row />
                <span className="acpmux-chat-inspector-row__name">{server.name}</span>
                <span className="acpmux-chat-inspector-row__end" data-state={server.status}>
                  {t(
                    server.status === "failed"
                      ? "chatInspector.connectors.needsReconnect"
                      : server.status === "pending"
                        ? "rail.connectorPending"
                        : "composer.envConnected",
                  )}
                </span>
              </li>
            ))}
          </ul>
        </InspectorSection>
      )}
      {pullRequests.length > 0 && (
        <InspectorSection
          id="changes"
          title={t("header.changes")}
          open={state.changes}
          onOpenChange={fold("changes")}
          meta={value(String(pullRequests.length))}
        >
          <ChangesSection pullRequests={pullRequests} statuses={statuses} onOpenBeside={onOpenUrl} />
        </InspectorSection>
      )}
      {servers.length > 0 && (
        <InspectorSection
          id="servers"
          title={t("chatInspector.servers")}
          open={state.servers}
          onOpenChange={fold("servers")}
          meta={value(t("rail.running", { count: servers.length }))}
        >
          <ServersSection servers={servers} onStop={onStopProcess} onOpenUrl={onOpenUrl} />
        </InspectorSection>
      )}
      {agents.length + sessions.length > 0 && (
        <InspectorSection
          id="subagents"
          title={t("summary.subagents")}
          open={state.subagents}
          onOpenChange={fold("subagents")}
          meta={value(subagentCounts(t, agents, waiting, sessions))}
        >
          <SubagentsSection
            agents={agents}
            waiting={waiting}
            onOpen={onOpenSubagent ?? (() => undefined)}
            sessions={sessions}
            onOpenSession={onOpenSession}
          />
        </InspectorSection>
      )}
      {(commands.length > 0 || scheduled.length > 0) && (
        <InspectorSection
          id="tasks"
          title={t("summary.backgroundTasks")}
          open={state.tasks}
          onOpenChange={fold("tasks")}
          meta={runningTasks > 0 ? value(t("rail.running", { count: runningTasks })) : undefined}
        >
          <TasksSection commands={commands} scheduled={scheduled} onStop={onStopProcess} />
        </InspectorSection>
      )}
      {outputs.length + links.length + artifacts > 0 && (
        <InspectorSection id="outputs" title={t("rail.outputs")} open={state.outputs} onOpenChange={fold("outputs")}>
          <OutputsSection
            files={outputs}
            links={links}
            artifacts={artifacts}
            onOpenFile={onOpenOutput}
            onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
          />
        </InspectorSection>
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
