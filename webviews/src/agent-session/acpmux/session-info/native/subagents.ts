// Session Info's Subagents as the App draws it (model.ts): what Session Info's `subagentsSection`,
// SubagentLimitStepper.tsx and SubagentsSection.tsx (with ChildSessionRows.tsx's started chats) show,
// as plain rows. The running limit's line first ("Running 8 / 16 max", − and +), then the running
// subagents and started chats (a nested subagent under its parent), past five a "Show more" row, then
// the ended ones' row ("94 done · 1 failed"), which opens into their lines. The lists, their order and
// their words come from the page's own helpers, so both panels say the same thing.
import { formatDuration } from "../../conversation/turns";
import type { Translate } from "../../i18n";
import { nestAgents } from "../../subagents/AgentsPill";
import { elapsed } from "../../subagents/SubagentGroup";
import { subagentStateText, subagentStatus, type SubagentStatus } from "../../summary/SubagentStatusList";
import { orderedSessions, sessionStatus, sessionStateText } from "../ChildSessionRows";
import type { SubsessionLimits } from "../../model";
import type { StartedSession } from "../../started/startedSessions";
import type { Subagent } from "../../subagents/subagentFold";
import { clampRunning, MAX_RUNNING, slotCounts } from "../../subsessionLimits";
import { SUBAGENTS_SHOWN, subagentCounts } from "../SubagentsSection";
import type { NativeInfoActions, NativeInfoButton, NativeInfoRow, NativeInfoSection, NativeInfoTone } from "./model";

export type SubagentsSectionInput = {
  /// The section is unfolded (Session Info's `state.subagents`).
  open: boolean;
  /// The chat's subagents; a workflow Background tasks lists (`workflows`) is left out, as there.
  agents: readonly Subagent[];
  workflows?: readonly { id: string }[];
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
  done: "done",
  failed: "failed",
  stopped: "muted",
};

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
    harness?: string;
    depth: number;
    at: number;
    open?: () => void;
  };
  const live = (status: SubagentStatus) => status === "running" || status === "waiting";
  const waitsFirst = (a: Subagent, b: Subagent) =>
    Number(subagentStatus(b, waiting) === "waiting") - Number(subagentStatus(a, waiting) === "waiting") ||
    a.startedAt - b.startedAt;
  const agentLine = (agent: Subagent, depth: number): SubagentLine => {
    const status = subagentStatus(agent, waiting);
    return {
      key: `agent:${agent.id}`,
      identity: agent.id,
      agent,
      name: agent.name,
      detail: live(status) ? agent.action : undefined,
      status,
      state: subagentStateText(t, agent, waiting),
      time: formatDuration(elapsed(agent, input.now)),
      task: agent.task,
      harness: agent.harness,
      depth,
      at: agent.endedAt ?? agent.startedAt,
      open: input.onOpen && (() => input.onOpen!(agent.id)),
    };
  };
  const sessionLine = (child: StartedSession): SubagentLine => ({
    key: `session:${child.sessionId}`,
    identity: child.sessionId,
    name: child.title,
    status: sessionStatus(child),
    state: sessionStateText(t, child).text,
    harness: child.harness,
    time: undefined,
    depth: 0,
    at: child.createdAt ?? 0,
    open: input.onOpenSession && (() => input.onOpenSession!(child.sessionId)),
  });
  const runningAgents = nestAgents(agents.filter((agent) => live(subagentStatus(agent, waiting))).sort(waitsFirst)).map(
    ({ agent, depth }) => agentLine(agent, depth),
  );
  const children = orderedSessions(sessions);
  const running: SubagentLine[] = [
    ...children.filter((child) => sessionStatus(child) === "waiting").map(sessionLine),
    ...runningAgents,
    ...children.filter((child) => sessionStatus(child) === "running").map(sessionLine),
  ];
  const ended: SubagentLine[] = [
    ...agents.filter((agent) => !live(subagentStatus(agent, waiting))).map((agent) => agentLine(agent, 0)),
    ...children.filter((child) => !live(sessionStatus(child))).map(sessionLine),
  ].sort(
    (a, b) =>
      ({ failed: 0, stopped: 1, done: 2, running: 3, waiting: 3 } as Record<SubagentStatus, number>)[a.status] -
        ({ failed: 0, stopped: 1, done: 2, running: 3, waiting: 3 } as Record<SubagentStatus, number>)[b.status] ||
      b.at - a.at,
  );
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
  const line = (item: SubagentLine): NativeInfoRow => ({
    id: item.key,
    symbol: item.agent ? "bubble.left" : "bubble.left.and.bubble.right",
    title: item.name,
    ...(item.detail && item.detail !== item.name ? { detail: item.detail } : {}),
    trailing: [item.time, item.state].filter(Boolean).join(" · "),
    tone: TONE[item.status],
    ...(item.depth > 0 ? { indent: Math.min(item.depth, 3) } : {}),
    ...(item.open ? { action: actions.add(`subagents.open:${item.key}`, item.open) } : {}),
    ...(item.task && item.task !== item.name ? { help: item.task } : {}),
    ...(item.harness ? { harness: item.harness } : {}),
  });
  const showAll = input.showAll ?? false;
  rows.push(...(showAll ? running : running.slice(0, SUBAGENTS_SHOWN)).map(line));
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
  const meta = subagentCounts(t, agents, waiting, sessions);
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

/// SubagentLimitStepper's line: "Running 8 / 16 max", "3 queued" while some wait, Reset when the
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
  if (onSet) {
    if (limits.maxRunningSource === "session")
      buttons.push({
        label: t("sessionInfo.subagents.limit.resetLabel"),
        symbol: "arrow.uturn.backward",
        action: actions.add("subagents.limitReset", () => onSet(null)),
      });
    const lower = clampRunning(max - 1);
    const raise = clampRunning(max + 1);
    buttons.push(
      {
        label: t("sessionInfo.subagents.limit.lower", { n: lower }),
        symbol: "minus",
        action: actions.add("subagents.limitLower", () => (onStep ? onStep(-1) : onSet(lower, max))),
        ...(max <= MAX_RUNNING.min ? { disabled: true } : {}),
      },
      {
        label: t("sessionInfo.subagents.limit.raise", { n: raise }),
        symbol: "plus",
        action: actions.add("subagents.limitRaise", () => (onStep ? onStep(1) : onSet(raise, max))),
        ...(max >= MAX_RUNNING.max ? { disabled: true } : {}),
      },
    );
  }
  return {
    id: "limit",
    symbol: "gauge.with.dots.needle.33percent",
    title: t("sessionInfo.subagents.limit.running", { running, max }),
    ...(state === "failed"
      ? { detail: t("sessionInfo.subagents.limit.refused") }
      : queued > 0
        ? { detail: t("sessionInfo.subagents.limit.queued", { n: queued }) }
        : {}),
    trailing: String(max),
    ...(buttons.length > 0 ? { buttons } : {}),
  };
}
