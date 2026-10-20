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
// - Subagents: an avatar row with live counts that opens into the list (SubagentsSection).
// - Background tasks: its other background commands and its wakeups (TasksSection).
// - Outputs: the files, artifacts and links it produced (OutputsSection).
//
// Open, it pushes the chat aside and the chat reflows (Settings > Agent Chat > Inspector), unless
// the pane is too narrow for the chat beside it, when it lies over the chat instead; Overlay
// always lies over it. Its left edge drags to resize it. Open, width and folds are the viewer's
// and hold in every chat tab (inspectorState.ts). Debug Settings `agent.inspector` (on by default)
// turns it off, which brings back the summary card it replaces (summary/SummaryCard.tsx). It reads
// only acpmux's common snapshot and the App's header state, never one harness's own fields.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useChatDisplay } from "../chatDisplay";
import { useHeaderState } from "../header/headerState";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { registerPicker } from "../pickerOpeners";
import { subagentsIn } from "../subagents/subagentRows";
import { chatGallery } from "../summary/chatGallery";
import { GalleryDialog } from "../summary/GalleryDialog";
import { sessionSummary, type SessionSummary } from "../summary/sessionSummary";
import { waitingSubagents } from "../summary/SubagentStatusList";
import type { TurnFile } from "../diff";
import { ChangesSection, headerStatus, type InspectorPullRequestStatus } from "./ChangesSection";
import { EnvironmentSection } from "./EnvironmentSection";
import { InspectorSection } from "./InspectorSection";
import {
  INSPECTOR_WIDTH,
  setInspectorOpen,
  setInspectorSection,
  setInspectorWidth,
  useInspectorState,
  type InspectorSectionId,
  type InspectorSections,
} from "./inspectorState";
import { OutputsSection, outputLinks, type OutputLink } from "./OutputsSection";
import {
  splitServers,
  useInspectorProcesses,
  type InspectorProcess,
  type InspectorServer,
  type ProcessSource,
} from "./processes";
import { ServersSection } from "./ServersSection";
import { SubagentsSection, subagentCounts } from "./SubagentsSection";
import { isRunning, TasksSection } from "./TasksSection";
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
  processSource,
  sessionId,
  onStopProcess,
  subagents,
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
  /// acpmux's background-process registry for the chat, from the pane's client.
  processSource?: ProcessSource;
  sessionId?: string;
  /// `_acpmux/process/kill`.
  onStopProcess?: (id: string) => Promise<unknown>;
  subagents?: {
    views: Record<string, AcpmuxRow[]> | undefined;
    /// The tool calls the chat's open asks are about (SubagentStatusList.tsx `pendingToolCalls`).
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
  };
}): { on: boolean; button?: ReactNode; panel?: ReactNode } {
  const t = useT();
  const { inspector: on, pullRequest } = useHeaderState();
  const { open, width, sections } = useInspectorState();
  const placement = useChatDisplay().inspector;
  // Closed for now (not remembered): an output's diff split left no room beside the chat.
  const [suppressed, setSuppressed] = useState(false);
  const shown = on && open && !suppressed;
  const paneWidth = usePaneWidth(shell, shown);
  const push = pushes(placement, paneWidth, width);
  const rows = snapshot.rows;
  const made = useMemo(() => (shown ? sessionSummary(rows) : undefined), [shown, rows]);
  const links = useMemo(() => (shown ? outputLinks(rows) : []), [shown, rows]);
  const artifacts = useMemo(() => (shown ? chatGallery(rows).length : 0), [shown, rows]);
  const views = subagents?.views;
  const asks = subagents?.asks;
  const agents = useMemo(() => (shown ? [...subagentsIn(rows, views).values()] : []), [shown, rows, views]);
  const waiting = useMemo(
    () => (shown && asks ? waitingSubagents(asks, views) : new Set<string>()),
    [shown, asks, views],
  );
  const statuses = useMemo(() => headerStatus(pullRequest), [pullRequest]);
  const processes = useInspectorProcesses(processSource, sessionId, shown);
  const openedOutputAt = useRef(0);
  // An output's diff opens beside the chat. When that split leaves too little room to push the
  // chat, the Inspector would cover it, so it steps aside until the toggle opens it again.
  const pushRef = useRef(push);
  useEffect(() => {
    const was = pushRef.current;
    pushRef.current = push;
    if (was && !push && placement === "push" && Date.now() - openedOutputAt.current < SPLIT_SETTLE_MS)
      setSuppressed(true);
  }, [push, placement]);
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
  const openOutput = onOpenOutput
    ? (path: string) => {
        openedOutputAt.current = Date.now();
        onOpenOutput(path);
      }
    : undefined;
  return {
    on: true,
    button: (
      <button
        type="button"
        className="acpmux-header-tool acpmux-inspector-toggle"
        aria-label={label}
        aria-pressed={shown}
        title={label}
        onClick={toggle}
      >
        <Icon name="pane.split.right" size={15} />
      </button>
    ),
    panel: shown ? (
      <InspectorPanel width={width} placement={push ? "push" : "overlay"}>
        <ChatInspector
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
          processes={processes}
          onStopProcess={onStopProcess}
          sections={sections}
          onSection={setInspectorSection}
          onOpenOutput={openOutput}
          onOpenUrl={onOpenUrl}
          onOpenImage={onOpenImage}
        />
      </InspectorPanel>
    ) : undefined,
  };
}

/// The panel's frame: its width, its place beside or over the chat, and the drag handle on its
/// left edge (a double-click puts the width back).
export function InspectorPanel({
  width,
  placement,
  children,
}: {
  width: number;
  placement: InspectorPlacement;
  children: ReactNode;
}) {
  const t = useT();
  const frame = useRef<HTMLElement>(null);
  const drag = useRef<{ right: number } | undefined>(undefined);
  return (
    <aside
      ref={frame}
      className="acpmux-inspector"
      data-placement={placement}
      style={{ width }}
      aria-label={t("chatInspector.title")}
    >
      <div
        className="acpmux-inspector__resize"
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
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const servers: InspectorServer[] = [];
  const tasks: InspectorProcess[] = [];
  const split = splitServers(processes);
  servers.push(...split.servers);
  tasks.push(...split.tasks);
  const scheduled = made?.scheduled ?? [];
  const pullRequests = made?.pullRequests ?? [];
  const mcp = summary?.mcpServers ?? [];
  const reconnect = mcp.filter((server) => server.status === "failed").length;
  const runningTasks = tasks.filter(isRunning).length;
  const value = (text: string) => <span className="acpmux-inspector-section__value">{text}</span>;
  return (
    <div className="acpmux-inspector__body">
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
      <InspectorSection
        id="context"
        title={t("rail.context")}
        open={known && state.context}
        onOpenChange={known ? fold("context") : undefined}
        meta={
          known ? (
            <>
              {value(t("rail.percent", { percent }))}
              <span className="acpmux-inspector-meter" aria-hidden="true">
                <span style={{ width: `${percent}%` }} />
              </span>
            </>
          ) : (
            value("—")
          )
        }
      >
        {known && (
          <ul className="acpmux-inspector-list">
            <li className="acpmux-inspector-row">
              <span className="acpmux-inspector-row__name">{t("chatInspector.context.used")}</span>
              <span className="acpmux-inspector-row__end">
                {t("context.tokens", { used: tokens.format(usage.used), size: tokens.format(usage.size) })}
              </span>
            </li>
            <li className="acpmux-inspector-row">
              <span className="acpmux-inspector-row__name">{t("chatInspector.context.left")}</span>
              <span className="acpmux-inspector-row__end">{tokens.format(Math.max(0, usage.size - usage.used))}</span>
            </li>
          </ul>
        )}
      </InspectorSection>
      {mcp.length > 0 && (
        <InspectorSection
          id="connectors"
          title={t("rail.connectors")}
          open={state.connectors}
          onOpenChange={fold("connectors")}
          meta={value(
            [
              t("rail.connected", { count: mcp.filter((server) => server.status === "connected").length }),
              reconnect > 0 && t("chatInspector.connectors.reconnect", { count: reconnect }),
            ]
              .filter(Boolean)
              .join(" · "),
          )}
        >
          <ul className="acpmux-inspector-list">
            {mcp.map((server) => (
              <li key={server.name} className="acpmux-inspector-row">
                <Icon name="extension" size={12} row />
                <span className="acpmux-inspector-row__name">{server.name}</span>
                {server.status !== "connected" && (
                  <span className="acpmux-inspector-row__end" data-state={server.status}>
                    {t(
                      server.status === "failed" ? "chatInspector.connectors.needsReconnect" : "rail.connectorPending",
                    )}
                  </span>
                )}
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
      {agents.length > 0 && (
        <InspectorSection
          id="subagents"
          title={t("summary.subagents")}
          open={state.subagents}
          onOpenChange={fold("subagents")}
          meta={value(subagentCounts(t, agents, waiting))}
        >
          <SubagentsSection agents={agents} waiting={waiting} onOpen={onOpenSubagent ?? (() => undefined)} />
        </InspectorSection>
      )}
      {(tasks.length > 0 || scheduled.length > 0) && (
        <InspectorSection
          id="tasks"
          title={t("summary.backgroundTasks")}
          open={state.tasks}
          onOpenChange={fold("tasks")}
          meta={runningTasks > 0 ? value(t("rail.running", { count: runningTasks })) : undefined}
        >
          <TasksSection processes={tasks} scheduled={scheduled} onStop={onStopProcess} />
        </InspectorSection>
      )}
      <InspectorSection id="outputs" title={t("rail.outputs")} open={state.outputs} onOpenChange={fold("outputs")}>
        <OutputsSection
          files={(made?.outputs ?? []) as readonly TurnFile[]}
          links={links}
          artifacts={artifacts}
          onOpenFile={onOpenOutput}
          onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
        />
      </InspectorSection>
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
