// Session Info's Subagents as the App draws it (model.ts): what Session Info's `subagentsSection`,
// SubagentLimitStepper.tsx and SubagentsSection.tsx (with ChildSessionRows.tsx's started chats) show,
// as plain rows. The running limit's line first ("Started chats: 8 of 16 at once", − and +, the chats it started and not its subagents), then the running
// subagents and started chats (a nested subagent under its parent), past five a "Show more" row, then
// the ended ones' row ("94 done · 1 failed"), which opens into their lines. The lists, their order and
// their words come from the page's own helpers, so both panels say the same thing.
import { formatDuration } from "../../conversation/turns";
import type { PaneLanguage, Translate } from "../../i18n";
import { isRepeatedAgentKind } from "../../subagents/AgentIdentity";
import { agentTone } from "../../subagents/agentTones";
import { nestAgents } from "../../subagents/AgentsPill";
import { elapsed } from "../../subagents/SubagentGroup";
import { subagentProgress } from "../../subagents/subagentProgress";
import { retrying } from "../../subagents/retryState";
import { subagentStateText, subagentStatus, type SubagentStatus } from "../../summary/SubagentStatusList";
import { orderedSessions, sessionStatus, sessionStateText } from "../ChildSessionRows";
import type { SubsessionLimits } from "../../model";
import type { StartedSession } from "../../started/startedSessions";
import type { Subagent } from "../../subagents/subagentFold";
import { clampRunning, MAX_RUNNING, slotCounts } from "../../subsessionLimits";
import { SUBAGENTS_SHOWN, subagentCounts } from "../SubagentsSection";
import type { NativeInfoActions, NativeInfoButton, NativeInfoRow, NativeInfoSection, NativeInfoTone } from "./model";
import { nativeInfoWave } from "./wave";

export type SubagentsSectionInput = {
  /// The section is unfolded (Session Info's `state.subagents`).
  open: boolean;
  /// The chat's subagents; a workflow Background tasks lists (`workflows`) is left out, as there.
  agents: readonly Subagent[];
  /// Parent harness supplies ordinary child agents that do not name their own.
  harness?: string;
  workflows?: readonly { id: string }[];
  /// The pane language used by the shared progress formatter.
  language?: PaneLanguage;
  waiting: ReadonlySet<string>;
  /// The chats its agent started.
  sessions: readonly StartedSession[];
  /// acpmux's running limit (summary `subsessionLimits`); without it no limit line.
  limits?: SubsessionLimits;
  /// Sets or drops the chat's own limit (Session Info's `setRunningLimit`, already bound to the chat);
  /// without it the limit only reads.
  onSet?: (maxRunning: number | null, from?: number) => Promise<unknown>;
  onOpen?: (id: string) => void;
  onOpenSession?: (sessionId: string) => void;
  /// The clock the elapsed times read (the page's `useNow`).
  now: number;
  /// Every running line shows, not only the first five; `onShowAll` flips it.
  showAll?: boolean;
  onShowAll?: (showAll: boolean) => void;
  /// The ended lines show under their row; `onEndedOpen` flips it.
  endedOpen?: boolean;
  onEndedOpen?: (open: boolean) => void;
  /// Optional controller step keeps rapid native clicks on the latest optimistic value.
  onStep?: (by: number) => void;
  /// Optimistic limit state owned by the page while acpmux answers a limit change.
  limitState?: "pending" | "failed";
  pendingMax?: number;
};

const TONE: Record<SubagentStatus, NativeInfoTone> = {
  running: "running",
  waiting: "waiting",
  idle: "muted",
  done: "done",
  failed: "failed",
  stopped: "muted",
};

/// The ended list's order: a failed one first, then a stopped one, then the done ones.
const ENDED_RANK: Record<SubagentStatus, number> = { failed: 0, stopped: 1, done: 2, running: 3, waiting: 3, idle: 3 };

/// Session Info's Subagents, or undefined when the chat never had subagents or started chats and
/// nobody set its running limit (Session Info's condition).
export function subagentsSection(
  input: SubagentsSectionInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { limits, sessions, waiting } = input;
  const workflowIds = new Set((input.workflows ?? []).map((workflow) => workflow.id));
  const agents = workflowIds.size > 0 ? input.agents.filter((agent) => !workflowIds.has(agent.id)) : input.agents;
  const limitSet = limits?.maxRunningSource !== undefined && limits.maxRunningSource !== "default";
  if (agents.length + sessions.length === 0 && !limitSet) return undefined;
  const rows: NativeInfoRow[] = [];
  if (limits)
    rows.push(limitRow(limits, sessions, input.onSet, actions, t, input.limitState, input.pendingMax, input.onStep));
  type SubagentLine = {
    key: string;
    identity: string;
    agent?: Subagent;
    name: string;
    detail?: string;
    status: SubagentStatus;
    state: string;
    time?: string;
    task?: string;
    progress?: string;
    kind?: string;
    harness?: string;
    working?: boolean;
    depth: number;
    at: number;
    open?: () => void;
  };
  const live = (status: SubagentStatus) => status === "running" || status === "waiting" || status === "idle";
  // An idle line keeps its place among the live ones but takes no part in the running shimmer.
  const working = (status: SubagentStatus) => status === "running" || status === "waiting";
  const now = input.now;
  const waitsFirst = (a: Subagent, b: Subagent) =>
    Number(subagentStatus(b, waiting) === "waiting") - Number(subagentStatus(a, waiting) === "waiting") ||
    a.startedAt - b.startedAt;
  const agentLine = (agent: Subagent, depth: number): SubagentLine => {
    const status = subagentStatus(agent, waiting, now);
    return {
      key: `agent:${agent.id}`,
      identity: agent.id,
      agent,
      name: agent.name,
      detail: working(status) ? agent.action : undefined,
      status,
      state: subagentStateText(t, agent, waiting, now),
      time: formatDuration(elapsed(agent, input.now)),
      progress: subagentProgress(t, input.language ?? "en", agent, { usage: false }).join(" · ") || undefined,
      task: agent.task && agent.task !== agent.name ? agent.task : undefined,
      kind: agent.kind && agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined,
      harness: agent.harness ?? input.harness,
      working: Boolean(retrying(agent)),
      depth,
      at: agent.endedAt ?? agent.startedAt,
      open: input.onOpen && (() => input.onOpen!(agent.id)),
    };
  };
  const sessionLine = (child: StartedSession): SubagentLine => {
    const state = sessionStateText(t, child);
    return {
      key: `session:${child.sessionId}`,
      identity: child.sessionId,
      name: child.title,
      status: sessionStatus(child),
      state: state.text,
      harness: child.harness,
      working: state.working,
      time: undefined,
      depth: 0,
      at: child.createdAt ?? 0,
      open: input.onOpenSession && (() => input.onOpenSession!(child.sessionId)),
    };
  };
  const runningAgents = nestAgents(
    agents.filter((agent) => live(subagentStatus(agent, waiting, now))).sort(waitsFirst),
  ).map(({ agent, depth }) => agentLine(agent, depth));
  const children = orderedSessions(sessions);
  const running: SubagentLine[] = [
    ...children.filter((child) => sessionStatus(child) === "waiting").map(sessionLine),
    ...runningAgents,
    ...children.filter((child) => sessionStatus(child) === "running").map(sessionLine),
  ];
  const ended: SubagentLine[] = [
    ...agents.filter((agent) => !live(subagentStatus(agent, waiting, now))).map((agent) => agentLine(agent, 0)),
    ...children.filter((child) => !live(sessionStatus(child))).map(sessionLine),
  ].sort((a, b) => ENDED_RANK[a.status] - ENDED_RANK[b.status] || b.at - a.at);
  const endedCounts = (lines: readonly SubagentLine[]): string => {
    const count = (status: SubagentStatus) => lines.filter((line) => line.status === status).length;
    return [
      count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
      count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
      count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
    ]
      .filter(Boolean)
      .join(" · ");
  };
  const line = (item: SubagentLine, waveIndex?: number): NativeInfoRow => ({
    id: item.key,
    symbol: item.agent ? "bubble.left" : "bubble.left.and.bubble.right",
    title: item.name,
    ...(item.detail && item.detail !== item.name ? { detail: item.detail } : {}),
    ...(item.progress ? { progress: item.progress } : {}),
    trailing: [item.time, item.state].filter(Boolean).join(" · "),
    tone: TONE[item.status],
    identityTone: agentTone(item.identity),
    ...(item.working ? { working: true } : {}),
    ...(waveIndex !== undefined ? { wave: nativeInfoWave(waveIndex) } : {}),
    ...(item.depth > 0 ? { indent: Math.min(item.depth, 3) } : {}),
    ...(item.open ? { action: actions.add(`subagents.open:${item.key}`, item.open) } : {}),
    ...([item.kind, item.task].filter(Boolean).length > 0
      ? { help: [item.kind, item.task].filter(Boolean).join("\n") }
      : {}),
    ...(item.harness ? { harness: item.harness } : {}),
  });
  const showAll = input.showAll ?? false;
  const shown = showAll ? running : running.slice(0, SUBAGENTS_SHOWN);
  let waveIndex = 0;
  rows.push(
    ...shown.map((item) => {
      const index = working(item.status) ? waveIndex++ : undefined;
      return line(item, index);
    }),
  );
  if (running.length > SUBAGENTS_SHOWN) {
    const onShowAll = input.onShowAll;
    rows.push({
      id: "more",
      symbol: showAll ? "chevron.up" : "chevron.down",
      title: showAll
        ? t("sessionInfo.subagents.less")
        : t("sessionInfo.subagents.more", { n: running.length - SUBAGENTS_SHOWN }),
      tone: "muted",
      ...(onShowAll ? { action: actions.add("subagents.more", () => onShowAll(!showAll)) } : {}),
    });
  }
  if (ended.length > 0) {
    const endedOpen = input.endedOpen ?? false;
    const onEndedOpen = input.onEndedOpen;
    rows.push({
      id: "ended",
      symbol: endedOpen ? "chevron.down" : "chevron.right",
      title: endedCounts(ended),
      ...(onEndedOpen ? { action: actions.add("subagents.ended", () => onEndedOpen(!endedOpen)) } : {}),
    });
    if (endedOpen) rows.push(...ended.map(line));
  }
  const meta = subagentCounts(t, agents, waiting, sessions, now);
  return {
    id: "subagents",
    group: "running",
    title: t("summary.subagents"),
    ...(meta ? { meta } : {}),
    open: input.open,
    foldable: true,
    rows,
  };
}

/// SubagentLimitStepper's line: "Started chats: 8 of 16 at once", "3 queued" while some wait, Reset when the
/// chat set its own, − and + one lower or higher (named `from` the limit they step).
function limitRow(
  limits: SubsessionLimits,
  sessions: readonly StartedSession[],
  onSet: SubagentsSectionInput["onSet"],
  actions: NativeInfoActions,
  t: Translate,
  state?: "pending" | "failed",
  pendingMax?: number,
  onStep?: (by: number) => void,
): NativeInfoRow {
  const max = pendingMax ?? limits.maxRunning;
  const { running, queued } = slotCounts(limits, sessions);
  const buttons: NativeInfoButton[] = [];
  if (onSet || onStep) {
    if (limits.maxRunningSource === "session" && onSet)
      buttons.push({
        label: t("sessionInfo.subagents.limit.resetLabel"),
        symbol: "arrow.uturn.backward",
        action: actions.add("subagents.limitReset", () => onSet(null)),
      });
    const lower = clampRunning(max - 1);
    const raise = clampRunning(max + 1);
    const lowerAction = onStep ? () => onStep(-1) : onSet ? () => onSet(lower, max) : undefined;
    const raiseAction = onStep ? () => onStep(1) : onSet ? () => onSet(raise, max) : undefined;
    if (lowerAction)
      buttons.push({
        label: t("sessionInfo.subagents.limit.lower", { n: lower }),
        symbol: "minus",
        action: actions.add("subagents.limitLower", lowerAction),
        ...(max <= MAX_RUNNING.min ? { disabled: true } : {}),
      });
    if (raiseAction)
      buttons.push({
        label: t("sessionInfo.subagents.limit.raise", { n: raise }),
        symbol: "plus",
        action: actions.add("subagents.limitRaise", raiseAction),
        ...(max >= MAX_RUNNING.max ? { disabled: true } : {}),
      });
  }
  return {
    id: "limit",
    symbol: "gauge.with.dots.needle.33percent",
    title: t("sessionInfo.subagents.limit.startedChats", { running, max }),
    ...(state === "failed"
      ? { detail: t("sessionInfo.subagents.limit.refused") }
      : queued > 0
        ? { detail: t("sessionInfo.subagents.limit.queued", { n: queued }) }
        : {}),
    trailing: String(max),
    ...(buttons.length > 0 ? { buttons } : {}),
  };
}
