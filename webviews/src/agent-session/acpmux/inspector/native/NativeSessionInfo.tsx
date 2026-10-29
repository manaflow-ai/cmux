// Session Info for the App to draw (model.ts): the page's sections as plain rows, sent as
// `pane.sessionInfo` whenever what they list changes, and none of the page's own panel. It takes
// what ChatInspector takes and derives the same lists the same way; the per-section mappers turn them
// into rows. The person's choices the page's sections kept in their own state (a fold, Show more, a
// Reconnect under way) are kept here, since the App's rows have none.
import { useEffect, useMemo, useRef, useState } from "react";
import { usePaneLanguage, useT } from "../../i18n";
import type { AcpmuxRow } from "../../model";
import { postNative } from "../../native";
import { opensProcessTerminal } from "../../processTerminal";
import type { StartedSession } from "../../started/startedSessions";
import { useNow } from "../../subagents/SubagentGroup";
import type { Subagent } from "../../subagents/subagentFold";
import type { WorkflowAgent, WorkflowSummary } from "../../summary/workflow";
import type { Artifact } from "../../conversation/artifactPreview";
import type { TurnFile } from "../../diff";
import type { SessionSummary, SummaryBackgroundTask } from "../../summary/sessionSummary";
import { visibleChanges, type InspectorPullRequestStatus } from "../ChangesSection";
import type { OutputArtifact, OutputLink } from "../OutputsSection";
import type { InspectorProcess } from "../processes";
import { GROUP_SECTIONS, groupOrder, useGroupOrder, type InspectorGroupId } from "../sectionOrder";
import {
  INSPECTOR_WIDTH,
  setInspectorOpen,
  setInspectorSection,
  setInspectorSourcesAll,
  setInspectorWidth,
  useInspectorState,
  type InspectorSectionId,
} from "../inspectorState";
import { changesSection } from "./changes";
import { connectorsSection } from "./connectors";
import { contextSection } from "./context";
import { environmentSection } from "./environment";
import { setNativeSessionInfoActions } from "./host";
import { NativeInfoActions, type NativeInfoSection, type NativeSessionInfo } from "./model";
import { outputsSection } from "./outputs";
import { sourcesSection } from "./sources";
import { subagentsSection } from "./subagents";
import { tasksSection } from "./tasks";

type Summary = Parameters<typeof environmentSection>[0]["summary"];

export type NativeSessionInfoProps = {
  /// The panel shows (on, open, nothing took the pane).
  shown: boolean;
  /// Its frame, CSS pixels (ChatInspector's InspectorPresence works them out).
  width: number;
  top: number;
  side: number;
  foot?: number;
  label: string;
  /// A subagent's panel names it.
  title?: string;
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  repository?: string;
  made?: Pick<SessionSummary, "outputs" | "pullRequests" | "scheduled"> & Partial<Pick<SessionSummary, "sources">>;
  links: readonly OutputLink[];
  artifacts: number;
  documents: readonly OutputArtifact[];
  rows: readonly AcpmuxRow[];
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  statuses: Readonly<Record<string, InspectorPullRequestStatus>>;
  processes: readonly InspectorProcess[];
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
  onSaveEnvironment?: () => Promise<unknown> | void;
  onReconnectMcp?: (server: string) => Promise<unknown>;
  onOpenFolder?: (path: string) => void;
  onShowCall?: (toolCallId: string) => boolean;
};

/// The panel's own actions, which no row names (AgentPaneSessionInfoPanel.swift): the width a drag of
/// its edge ended at, a section's fold, and Esc.
export function panelAction(id: string): boolean {
  if (id === "close") {
    setInspectorOpen(false);
    return true;
  }
  const width = /^width:(\d{1,4})$/.exec(id);
  if (width) {
    setInspectorWidth(Math.min(INSPECTOR_WIDTH.max, Math.max(INSPECTOR_WIDTH.min, Number(width[1]))));
    return true;
  }
  const fold = /^fold:([a-z]+):([01])$/.exec(id);
  if (fold && Object.values(GROUP_SECTIONS).some((ids) => ids.includes(fold[1] as InspectorSectionId))) {
    setInspectorSection(fold[1] as InspectorSectionId, fold[2] === "1");
    return true;
  }
  return false;
}

/// The sections in the person's order (sectionOrder.ts): where it runs, what it made, what it runs.
export function orderSections(
  sections: readonly (NativeInfoSection | undefined)[],
  order: (group: InspectorGroupId) => readonly InspectorSectionId[] = groupOrder,
): NativeInfoSection[] {
  const byId = new Map(sections.flatMap((section) => (section ? [[section.id, section] as const] : [])));
  return (Object.keys(GROUP_SECTIONS) as InspectorGroupId[]).flatMap((group) =>
    order(group).flatMap((id) => {
      const section = byId.get(id);
      return section ? [section] : [];
    }),
  );
}

/// Sends the model when it changes, coalesced to a frame; withdraws it when the chat's panel goes.
function usePostSessionInfo(info: NativeSessionInfo, actions: NativeInfoActions) {
  const sent = useRef<string>(undefined);
  const frame = useRef<number>(undefined);
  const latest = useRef(info);
  latest.current = info;
  setNativeSessionInfoActions(actions, panelAction);
  useEffect(() => {
    if (frame.current !== undefined) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = undefined;
      const text = JSON.stringify(latest.current);
      if (text === sent.current) return;
      sent.current = text;
      void postNative("pane.sessionInfo", { info: latest.current }).catch(() => undefined);
    });
  });
  useEffect(
    () => () => {
      if (frame.current !== undefined) cancelAnimationFrame(frame.current);
      setNativeSessionInfoActions(undefined);
      void postNative("pane.sessionInfo", { info: null }).catch(() => undefined);
    },
    [],
  );
}

export function NativeSessionInfo(props: NativeSessionInfoProps) {
  const t = useT();
  const language = usePaneLanguage();
  const state = useInspectorState();
  const { shown, summary } = props;
  // The person's choices inside the sections (the page's components keep these in their own state).
  const [saved, setSaved] = useState(false);
  const [openLists, setOpenLists] = useState<ReadonlySet<string>>(new Set());
  const [reconnecting, setReconnecting] = useState<Readonly<Record<string, "reconnecting" | "failed">>>({});
  const [changesAll, setChangesAll] = useState(false);
  const [subagentsAll, setSubagentsAll] = useState(false);
  const [endedOpen, setEndedOpen] = useState(false);
  const [finishedOpen, setFinishedOpen] = useState(false);
  const [phases, setPhases] = useState<Readonly<Record<string, boolean>>>({});
  // Order follows a drag in any pane.
  useGroupOrder("about");
  useGroupOrder("made");
  useGroupOrder("running");
  const live =
    shown && (props.agents.length > 0 || props.processes.length > 0 || props.transcriptTasks.length > 0);
  const now = useNow(live);
  const chatId = summary?.sessionId;
  const { onSetRunningLimit, onReconnectMcp } = props;
  const setRunningLimit =
    onSetRunningLimit && chatId && !summary?.peer
      ? (maxRunning: number | null, from?: number) => onSetRunningLimit(chatId, maxRunning, from)
      : undefined;
  const local = opensProcessTerminal(summary);
  const calls = useMemo(
    () =>
      shown && !local && props.onShowCall
        ? new Set(props.rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool?.id ? [item.tool.id] : []))))
        : undefined,
    [shown, local, props.onShowCall, props.rows],
  );
  const reconnect = useMemo(
    () =>
      onReconnectMcp &&
      ((server: string) => {
        setReconnecting((was) => ({ ...was, [server]: "reconnecting" }));
        return onReconnectMcp(server).then(
          () =>
            setReconnecting((was) => {
              const { [server]: _, ...rest } = was;
              return rest;
            }),
          () => setReconnecting((was) => ({ ...was, [server]: "failed" })),
        );
      }),
    [onReconnectMcp],
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
          onSave: props.onSaveEnvironment,
          onOpenFolder: props.onOpenFolder,
          onOpenUrl: props.onOpenUrl,
          saved,
          onSaved: () => setSaved(true),
        },
        actions,
        t,
      ),
      contextSection(
        {
          usage: summary?.usage,
          breakdown: summary?.contextBreakdown,
          agent: props.agent,
          language,
          open: state.sections.context,
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
      connectorsSection(
        { servers: summary?.mcpServers ?? [], onReconnect: reconnect, open: state.sections.connectors, reconnecting },
        actions,
        t,
      ),
      changesSection(
        {
          pullRequests: visibleChanges(props.made?.pullRequests ?? [], props.statuses),
          statuses: props.statuses,
          onOpenBeside: props.onOpenUrl,
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
          cwd: summary?.cwd,
          onOpenFile: props.onOpenSourceFile,
          onOpenBeside: props.onOpenUrl,
          expanded: state.sourcesAll,
          onExpandedChange: setInspectorSourcesAll,
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
        },
        actions,
        t,
      ),
      subagentsSection(
        {
          open: state.sections.subagents,
          agents: props.agents,
          workflows: props.workflows,
          waiting: props.waiting,
          sessions: props.sessions,
          limits: summary?.subsessionLimits,
          onSet: setRunningLimit,
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
          scheduled: props.made?.scheduled ?? [],
          workflows: props.workflows,
          local,
          calls,
          onShowCall: props.onShowCall,
          onStopProcess: props.onStopProcess,
          onStopWorkflow: props.onStopWorkflow,
          onOpenWorkflowAgent: props.onOpenWorkflowAgent,
          onOpenUrl: props.onOpenUrl,
          now,
          finishedOpen,
          onFinishedOpen: setFinishedOpen,
          phases,
          onPhase: (key, open) => setPhases((was) => ({ ...was, [key]: open })),
        },
        actions,
        t,
      ),
    );
  }
  const info: NativeSessionInfo = {
    open: shown,
    width: props.width,
    top: props.top,
    side: props.side,
    ...(props.foot !== undefined ? { foot: props.foot } : {}),
    label: props.label,
    ...(props.title ? { title: props.title } : {}),
    sections: orderSections(sections),
  };
  usePostSessionInfo(info, actions);
  return null;
}
