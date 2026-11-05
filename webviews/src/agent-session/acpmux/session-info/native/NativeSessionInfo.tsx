// Session Info for the App to draw (model.ts): the page's sections as plain rows, sent as
// `pane.sessionInfo` whenever what they list changes, and none of the page's own panel. It takes
// what ChatSessionInfo takes and derives the same lists the same way; the per-section mappers turn them
// into rows. The person's choices the page's sections kept in their own state (a fold, Show more, a
// Reconnect under way) are kept here, since the App's rows have none.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { usePaneLanguage, useT, type Translate } from "../../i18n";
import type { AcpmuxRow } from "../../model";
import { planDone, type SessionInfoPlan } from "../ProgressSection";
import { postNative } from "../../native";
import { opensProcessTerminal } from "../../processTerminal";
import type { StartedSession } from "../../started/startedSessions";
import { useNow } from "../../subagents/SubagentGroup";
import type { Subagent } from "../../subagents/subagentFold";
import type { WorkflowAgent, WorkflowSummary } from "../../summary/workflow";
import type { Artifact } from "../../conversation/artifactPreview";
import type { TurnFile } from "../../diff";
import type { SessionSummary, SummaryBackgroundTask, SummaryWakeup } from "../../summary/sessionSummary";
import { useScheduledClock } from "../scheduled";
import { visibleChanges, type SessionInfoPullRequestStatus } from "../ChangesSection";
import type { OutputArtifact, OutputLink } from "../OutputsSection";
import { sessionInfoLists, type SessionInfoProcess } from "../processes";
import { useSectionOrder, sectionOrder } from "../sectionOrder";
import {
  claimSessionInfoIMessageReveal,
  setSessionInfoSection,
  setSessionInfoSourcesAll,
  useSessionInfoState,
  type SessionInfoSectionId,
} from "../sessionInfoState";
import { changesSection } from "./changes";
import { connectorsSection } from "./connectors";
import { contextSection } from "./context";
import { environmentSection } from "./environment";
import { setNativeSessionInfoActions, setNativeSessionInfoHost } from "./host";
import { useNativeOperations } from "./useNativeOperations";
import { useNativeSourceFiles } from "./useNativeSourceFiles";
import {
  NativeInfoActions,
  type NativeInfoRow,
  type NativeInfoSection,
  type NativeSessionInfo as NativeSessionInfoModel,
} from "./model";
import { outputsSection } from "./outputs";
import { useNativeOverlayReport } from "./overlays";
import { panelAction } from "./panelActions";
import { usageSection } from "./usage";
import type { AccessGrant } from "../EnvironmentSection";
import type { AcpmuxSessionEntry } from "../../sessionList";
import { byUsage, compactingUsage, type UsageSort } from "../../usageStats";
import { sourcesSection } from "./sources";
import { subagentsSection } from "./subagents";
import { tasksSection, useNativeWorkflowPhases } from "./tasks";
import { CloudRepositoryPicker } from "../CloudRepositoryPicker";
import { machineOf } from "../EnvironmentSection";
import { useCloudRepositories } from "./useCloudRepositories";
import { cloudEnvironmentRequest, openCloudEnvironment, subscribeCloudEnvironment } from "../../cloudEnvironment";
import { copyText } from "../../conversation/clipboard";
import { useSubagentLimitController } from "../SubagentLimitStepper";
import { useIMessage } from "../imessage";

const NO_SCHEDULED: readonly SummaryWakeup[] = [];

type Summary = Parameters<typeof environmentSection>[0]["summary"];

export type NativeSessionInfoProps = {
  /// The panel shows (on, open, nothing took the pane).
  shown: boolean;
  /// Its frame, CSS pixels (ChatSessionInfo's SessionInfoPresence works them out).
  width: number;
  top: number;
  side: number;
  foot?: number;
  /// It lies over the chat (model.ts `overChat`).
  overChat?: boolean;
  label: string;
  /// A subagent's panel names it.
  title?: string;
  onBack?: () => void;
  backLabel?: string;
  grants?: readonly AccessGrant[];
  cloudRepositoryAvailable?: boolean;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onCompact?: () => void;
  allSessions?: readonly AcpmuxSessionEntry[];
  onOpenChat?: (id: string) => void;
  onShowUsage?: () => void;
  revealed?: { section: SessionInfoSectionId; at: number };
  onRevealed?: () => void;
  summary?: Summary;
  /// The same compacted context usage shown by the web panel.
  usage?: { used: number; size: number };
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  repository?: string;
  made?: Pick<SessionSummary, "outputs" | "pullRequests" | "scheduled"> & Partial<Pick<SessionSummary, "sources">>;
  links: readonly OutputLink[];
  artifacts: number;
  documents: readonly OutputArtifact[];
  rows: readonly AcpmuxRow[];
  /// The agent's current plan, as the page's Progress draws it (ProgressSection.tsx).
  plan?: SessionInfoPlan;
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>;
  processes: readonly SessionInfoProcess[];
  listed: boolean;
  transcriptTasks: readonly SummaryBackgroundTask[];
  sessions: readonly StartedSession[];
  workflows: readonly WorkflowSummary[];
  agent?: Subagent;
  onOpenSubagent?: (id: string) => void;
  onOpenSession?: (sessionId: string) => void;
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  onStopWorkflow?: (id: string) => Promise<unknown>;
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenDocument?: (artifact: Artifact) => void;
  onOpenArtifacts?: () => void;
  onReconnectMcp?: (server: string) => Promise<unknown>;
  onOpenFolder?: (path: string) => void;
  onShowCall?: (toolCallId: string) => boolean;
};

/// Sections retain the person's single order, including drags across the three groups.
export function orderSections(sections: readonly (NativeInfoSection | undefined)[], t: Translate): NativeInfoSection[] {
  const byId = new Map(sections.flatMap((section) => (section ? [[section.id, section] as const] : [])));
  return sectionOrder().flatMap((id) => {
    const section = byId.get(id);
    return section
      ? [
          {
            ...section,
            reorderable: true,
            reorderLabel: t("sessionInfo.reorderSection", { section: section.title }),
          },
        ]
      : [];
  });
}

/// Sends the model when it changes, coalesced to a frame; withdraws it when the chat's panel goes.
function usePostSessionInfo(info: NativeSessionInfoModel, actions: NativeInfoActions, onRevealed?: () => void) {
  const sent = useRef<string>(undefined);
  const mounted = useRef(false);
  const posted = useRef(0);
  const reveal = useRef(info.reveal);
  const acknowledge = useRef(onRevealed);
  reveal.current = info.reveal;
  acknowledge.current = onRevealed;
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useLayoutEffect(() => {
    setNativeSessionInfoActions(actions, (id) => panelAction(id, info.sections));
    return () => setNativeSessionInfoActions(undefined);
  }, [actions, info.sections]);
  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      const text = JSON.stringify(info);
      if (text === sent.current) return;
      sent.current = text;
      const request = ++posted.current;
      void postNative("pane.sessionInfo", { info })
        .then(() => {
          if (
            mounted.current &&
            info.reveal &&
            reveal.current?.section === info.reveal.section &&
            reveal.current?.at === info.reveal.at
          )
            acknowledge.current?.();
        })
        .catch(() => {
          if (mounted.current && request === posted.current) setNativeSessionInfoHost(false);
        });
    });
    return () => {
      cancelAnimationFrame(frame);
    };
  }, [info, onRevealed]);
  useEffect(
    () => () => {
      void postNative("pane.sessionInfo", { info: null }).catch(() => undefined);
    },
    [],
  );
}

export function NativeSessionInfo(props: NativeSessionInfoProps) {
  const t = useT();
  const language = usePaneLanguage();
  const state = useSessionInfoState();
  const { shown, summary, onShowUsage } = props;
  const imessage = useIMessage(shown);
  const imessageStatus = imessage?.data.status;
  useEffect(() => {
    if (!imessageStatus || imessageStatus === "connected") return;
    // A persistent claim reveals Connect once across panels; later folds belong to the person.
    if (claimSessionInfoIMessageReveal()) setSessionInfoSection("connectors", true);
  }, [imessageStatus]);
  useEffect(() => {
    if (imessage?.expanded) setSessionInfoSection("connectors", true);
  }, [imessage?.expanded]);
  const contextUsage = props.usage ?? compactingUsage(summary?.usage, summary?.usageStats, summary?.contextBreakdown);
  const environmentEditor = useSyncExternalStore(subscribeCloudEnvironment, cloudEnvironmentRequest);
  const cloudSession =
    props.cloudRepositoryAvailable && machineOf(summary, props.machineName, props.peerKinds).kind === "cloud"
      ? summary?.sessionId
      : undefined;
  const cloud = useCloudRepositories(cloudSession, shown);
  const activeStops = useMemo(
    () => [
      ...props.processes.filter((process) => process.state === "running").map((process) => `process:${process.id}`),
      ...props.workflows
        .filter((workflow) => workflow.state === "running" || workflow.state === "pending")
        .map((workflow) => `workflow:${workflow.id}`),
    ],
    [props.processes, props.workflows],
  );
  const stops = useNativeOperations(activeStops);
  const sourceFiles = useNativeSourceFiles(props.onOpenSourceFile, t);
  const [localReveal, setLocalReveal] = useState<NativeSessionInfoModel["reveal"]>();
  // The person's choices inside the sections (the page's components keep these in their own state).
  const [openLists, setOpenLists] = useState<ReadonlySet<string>>(new Set());
  const [reconnecting, setReconnecting] = useState<Readonly<Record<string, "reconnecting" | "failed">>>({});
  const reconnectingServers = useRef(new Set<string>());
  const [changesAll, setChangesAll] = useState(false);
  const [outputsAll, setOutputsAll] = useState(false);
  const [usageAll, setUsageAll] = useState(false);
  const [usageSort, setUsageSort] = useState<UsageSort>("cost");
  const hasSessionUsage = useMemo(
    () => props.allSessions?.some((entry) => entry.usageStats) ?? false,
    [props.allSessions],
  );
  const usageRanked = useMemo(
    () => (shown && state.sections.usage ? byUsage(props.allSessions ?? [], usageSort) : []),
    [shown, state.sections.usage, props.allSessions, usageSort],
  );
  const [subagentsAll, setSubagentsAll] = useState(false);
  const [endedOpen, setEndedOpen] = useState(false);
  const [finishedOpen, setFinishedOpen] = useState(false);
  const { phases, onPhase } = useNativeWorkflowPhases(shown && state.sections.tasks ? props.workflows : []);
  // Order follows a drag in any pane.
  useSectionOrder();
  useEffect(() => {
    if (shown) onShowUsage?.();
  }, [shown, onShowUsage]);
  // Elapsed times tick while anything listed still runs, a workflow included.
  const live =
    shown &&
    (props.agents.some((agent) => agent.state === "running") ||
      props.sessions.some((session) => session.state === "running") ||
      props.processes.some((process) => process.state === "running") ||
      props.transcriptTasks.some((task) => task.state === "running") ||
      props.workflows.some((workflow) => workflow.state === "running" || workflow.state === "pending"));
  const tickingNow = useNow(live);
  // Moves once, when the earliest wakeup or cron job still ahead ends (no per-second poll).
  const scheduledNow = useScheduledClock(props.made?.scheduled ?? NO_SCHEDULED);
  const now = Math.max(tickingNow, scheduledNow);
  const chatId = summary?.sessionId;
  const { onSetRunningLimit, onReconnectMcp } = props;
  const setRunningLimit =
    onSetRunningLimit && chatId && !summary?.peer
      ? (maxRunning: number | null, from?: number) => onSetRunningLimit(chatId, maxRunning, from)
      : undefined;
  const limit = useSubagentLimitController({
    chatId,
    limits: summary?.subsessionLimits,
    onSet: setRunningLimit,
  });
  const local = opensProcessTerminal(summary);
  const showsCalls =
    shown &&
    !local &&
    !!props.onShowCall &&
    sessionInfoLists(props.processes, props.transcriptTasks, props.listed).tasks.some((task) => task.toolCallId);
  const calls = useMemo(
    () =>
      showsCalls
        ? new Set(
            props.rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool?.id ? [item.tool.id] : []))),
          )
        : undefined,
    [showsCalls, props.rows],
  );
  const reconnect = useMemo(
    () =>
      onReconnectMcp &&
      ((server: string) => {
        if (reconnectingServers.current.has(server)) return Promise.resolve();
        reconnectingServers.current.add(server);
        setReconnecting((was) => ({ ...was, [server]: "reconnecting" }));
        return Promise.resolve()
          .then(() => onReconnectMcp(server))
          .then(
            () =>
              setReconnecting((was) => {
                const { [server]: _, ...rest } = was;
                return rest;
              }),
            () => setReconnecting((was) => ({ ...was, [server]: "failed" })),
          )
          .finally(() => reconnectingServers.current.delete(server));
      }),
    [onReconnectMcp],
  );
  // The plan keeps its identity while tokens stream (liveProgress.ts): its rows are made once per
  // checklist change, so other activity does not remap every step on every frame.
  const progressRows = useMemo<NativeInfoRow[] | undefined>(
    () =>
      props.plan?.entries.map((entry, index) => ({
        id: `progress:${index}`,
        title: entry.content,
        tone: entry.status === "completed" ? "muted" : entry.status === "in_progress" ? "running" : "waiting",
        working: entry.status === "in_progress" && !props.plan?.ended,
      })),
    [props.plan],
  );
  const actions = new NativeInfoActions();
  const sections: (NativeInfoSection | undefined)[] = [];
  if (shown) {
    const sources = props.made?.sources ?? [];
    sections.push(
      environmentSection(
        {
          summary,
          machineName: props.machineName,
          peerKinds: props.peerKinds,
          repository: props.repository,
          grants: props.grants,
          remoteControl: props.remoteControl,
          cloudRepositoryAvailable: props.cloudRepositoryAvailable,
          onAddCloudRepository: cloud.open,
          onOpenCloudEnvironment: () => openCloudEnvironment({ section: "overview" }),
          attachedCloudRepos: cloud.attachedRepos,
          pendingCloudRepos: cloud.pendingRepos,
          onOpenFolder: props.onOpenFolder,
          onOpenUrl: props.onOpenUrl,
        },
        actions,
        t,
      ),
      contextSection(
        {
          usage: contextUsage,
          breakdown: summary?.contextBreakdown,
          agent: props.agent,
          language,
          open: state.sections.context,
          onCompact: props.onCompact,
          openLists,
          onToggleList: (id) =>
            setOpenLists((was) => {
              const next = new Set(was);
              if (!next.delete(id)) next.add(id);
              return next;
            }),
        },
        actions,
        t,
      ),
      props.plan && props.plan.entries.length > 0
        ? {
            id: "progress",
            group: "running",
            title: t("sessionInfo.progress"),
            meta: t("sessionInfo.progress.count", { done: planDone(props.plan), total: props.plan.entries.length }),
            open: state.sections.progress,
            foldable: true,
            reorderable: true,
            rows: progressRows ?? [],
          }
        : undefined,
      connectorsSection(
        {
          servers: summary?.mcpServers ?? [],
          onReconnect: reconnect,
          open: state.sections.connectors,
          reconnecting,
          imessage,
        },
        actions,
        t,
      ),
      changesSection(
        {
          pullRequests: visibleChanges(props.made?.pullRequests ?? [], props.statuses),
          statuses: props.statuses,
          onOpenBeside: props.onOpenUrl,
          onCopyText: (text) => postNative("pane.copyText", { text }).catch(() => copyText(text)),
          open: state.sections.changes,
          expanded: changesAll,
          onExpandedChange: setChangesAll,
        },
        actions,
        t,
      ),
      sourcesSection(
        {
          sources,
          ...(summary?.additionalDirectories ? { folders: summary.additionalDirectories } : {}),
          cwd: summary?.cwd,
          onOpenFile: sourceFiles.open,
          failures: sourceFiles.failures,
          onOpenBeside: props.onOpenUrl,
          expanded: state.sourcesAll,
          onExpandedChange: setSessionInfoSourcesAll,
          open: state.sections.sources,
        },
        actions,
        t,
      ),
      outputsSection(
        {
          files: (props.made?.outputs ?? []) as readonly TurnFile[],
          links: props.links,
          artifacts: props.artifacts,
          documents: props.documents,
          onOpenFile: props.onOpenOutput,
          onOpenArtifacts: props.onOpenArtifacts,
          onOpenDocument: props.onOpenDocument,
          onOpenUrl: props.onOpenUrl,
          open: state.sections.outputs,
          expanded: outputsAll,
          onExpandedChange: setOutputsAll,
        },
        actions,
        t,
      ),
      subagentsSection(
        {
          language,
          open: state.sections.subagents,
          agents: props.agents,
          harness: summary?.harness,
          workflows: props.workflows,
          waiting: props.waiting,
          sessions: props.sessions,
          limits: summary?.subsessionLimits,
          onSet: setRunningLimit
            ? (max, from) => {
                limit.set(max, from);
                return Promise.resolve();
              }
            : undefined,
          onStep: setRunningLimit ? limit.step : undefined,
          pendingMax: limit.pendingMax,
          limitState: limit.state,
          onOpen: props.onOpenSubagent,
          onOpenSession: props.onOpenSession,
          now,
          showAll: subagentsAll,
          onShowAll: setSubagentsAll,
          endedOpen,
          onEndedOpen: setEndedOpen,
        },
        actions,
        t,
      ),
      tasksSection(
        {
          open: state.sections.tasks,
          processes: props.processes,
          transcriptTasks: props.transcriptTasks,
          listed: props.listed,
          scheduled: props.made?.scheduled ?? NO_SCHEDULED,
          language,
          workflows: props.workflows,
          local,
          calls,
          onShowCall: props.onShowCall,
          onStopProcess:
            props.onStopProcess &&
            ((id) => stops.run(`process:${id}`, () => props.onStopProcess!(id)) ?? Promise.resolve()),
          onStopWorkflow:
            props.onStopWorkflow &&
            ((id) => stops.run(`workflow:${id}`, () => props.onStopWorkflow!(id)) ?? Promise.resolve()),
          operations: stops.operations,
          onOpenWorkflowAgent: props.onOpenWorkflowAgent,
          onOpenUrl: props.onOpenUrl,
          now,
          finishedOpen,
          onFinishedOpen: setFinishedOpen,
          phases,
          onPhase,
        },
        actions,
        t,
      ),
    );
  }
  if (shown)
    sections.push(
      usageSection(
        {
          own: summary?.usageStats,
          planLimits: typeof summary?.usageLimits === "object" ? summary.usageLimits : undefined,
          sessions: props.allSessions ?? [],
          chatId,
          onOpen: props.onOpenChat,
          onCompact: props.onCompact,
          onShowSubagents: sections.some((section) => section?.id === "subagents")
            ? () => {
                setSessionInfoSection("subagents", true);
                setLocalReveal({ section: "subagents", at: Date.now() });
              }
            : undefined,
          locale: language,
          open: state.sections.usage,
          expanded: usageAll,
          onExpandedChange: setUsageAll,
          sort: usageSort,
          onSortChange: setUsageSort,
          ranked: usageRanked,
          hasSessionUsage,
        },
        actions,
        t,
      ),
    );
  const info: NativeSessionInfoModel = {
    open: shown && !cloud.picker && !environmentEditor,
    width: props.width,
    top: props.top,
    side: props.side,
    ...(props.foot !== undefined ? { foot: props.foot } : {}),
    ...(props.overChat ? { overChat: true } : {}),
    label: props.label,
    ...(props.title ? { title: props.title } : {}),
    ...(props.onBack ? { back: actions.add("scope.back", props.onBack), backLabel: props.backLabel } : {}),
    ...((props.revealed ?? localReveal) ? { reveal: props.revealed ?? localReveal } : {}),
    sections: orderSections(sections, t),
  };
  // The page's popups over the App's panel: it steps behind them (overlays.ts).
  useNativeOverlayReport(info.open);
  usePostSessionInfo(info, actions, () => {
    if (props.revealed) props.onRevealed?.();
    else setLocalReveal(undefined);
  });
  return cloudSession && cloud.picker ? (
    <CloudRepositoryPicker
      session={cloudSession}
      anchor={cloud.anchor}
      point={cloud.picker}
      open
      onOpenChange={(open) => {
        if (!open) cloud.close();
      }}
      onAttached={cloud.attached}
    />
  ) : null;
}
