import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { type StringKey, type Translate } from "../i18n";
import { running, STATE_LABEL } from "../subagents/SubagentGroup";
import { awaitsOwnWork, type Subagent } from "../subagents/subagentFold";
import { IDLE_AFTER_MS } from "../subagents/idle";
import { retrying, retryLabel } from "../subagents/retryState";
import { type SubsessionState } from "../subagents/subsessions";

/// What a row says of its subagent: a subagent that asks the user for a permission or an answer
/// is waiting on them, not running; a cancelled (stopped by the person) or disconnected (lost by
/// acpmux) one is stopped: it ended without its result, but did not fail.
/// An idle one runs but has done nothing for a while with no call open (``IDLE_AFTER_MS``): it
/// stopped and waits on background work of its own. Only a caller that passes the clock asks.
export type SubagentStatus = "running" | "waiting" | "idle" | "done" | "failed" | "stopped";

export const STATUS_LABEL: Record<SubagentStatus, StringKey> = {
  running: "subagents.state.running",
  waiting: "subagents.state.waiting",
  idle: "subagents.state.idle",
  done: "subagents.state.completed",
  failed: "subagents.state.failed",
  stopped: "subagents.state.cancelled",
};

export function subagentStatus(agent: Subagent, waiting: ReadonlySet<string>, now?: number): SubagentStatus {
  // Its end was interim: it waits on background work of its own, its report still to come.
  if (awaitsOwnWork(agent)) return waiting.has(agent.id) ? "waiting" : "idle";
  if (running(agent)) {
    if (waiting.has(agent.id)) return "waiting";
    return now !== undefined && isIdle(agent, now) ? "idle" : "running";
  }
  // acpmux waits to retry it (subagents/retryState.ts): it is about to run again.
  if (retrying(agent)) return "running";
  if (agent.state === "completed") return "done";
  return agent.state === "cancelled" || agent.state === "disconnected" ? "stopped" : "failed";
}

/// The label of a subagent's status: a stopped one says how it stopped (Cancelled, Disconnected),
/// as its transcript row does.
/// A running subagent quiet past ``IDLE_AFTER_MS`` with no call open, and not retrying.
export function isIdle(agent: Subagent, now: number): boolean {
  return agent.quietSince !== undefined && !retrying(agent) && now - agent.quietSince >= IDLE_AFTER_MS;
}

export function subagentStatusLabel(agent: Subagent, waiting: ReadonlySet<string>, now?: number): StringKey {
  const status = subagentStatus(agent, waiting, now);
  // One whose end was interim says what it waits on; one only quiet past the window stays Idle.
  if (status === "idle" && awaitsOwnWork(agent)) return "subagents.state.ownWork";
  if (status !== "stopped") return STATUS_LABEL[status];
  return agent.state === "disconnected" ? STATE_LABEL.disconnected : STATE_LABEL.cancelled;
}

/// What a subagent's line says of its state: acpmux's retry while one waits ("Retrying (2/4) after a
/// capacity error"), else its status's word.
export function subagentStateText(t: Translate, agent: Subagent, waiting: ReadonlySet<string>, now?: number): string {
  const retry = retrying(agent);
  return retry ? retryLabel(t, retry) : t(subagentStatusLabel(agent, waiting, now));
}

/// The tool calls the chat's open asks are about: the pending permission (`snapshot.permission`),
/// the pending items of permission groups, and permission rows still pending.
export function pendingToolCalls(
  snapshot: Pick<AcpmuxSnapshot, "rows" | "permission" | "permissionGroups">,
): Set<string> {
  const calls = new Set<string>();
  const add = (value: unknown) => {
    if (typeof value === "string" && value) calls.add(value);
  };
  if (snapshot.permission?.pending) add(snapshot.permission.toolCallId);
  for (const group of snapshot.permissionGroups?.groups ?? [])
    for (const item of group.items)
      if (item.state === "pending") {
        const request = item.request as {
          toolCall?: { toolCallId?: unknown };
          subject?: { type?: unknown; toolCall?: { toolCallId?: unknown } };
        };
        add(
          request.toolCall?.toolCallId ??
            (request.subject?.type === "tool_call" ? request.subject.toolCall?.toolCallId : undefined),
        );
      }
  for (const row of snapshot.rows)
    if (row.kind === "permission" && row.permission?.pending) add(row.permission.toolCallId);
  return calls;
}

/// The subagents that wait on the user: an open ask about one of their own tool calls (their
/// view's tool calls).
export function waitingSubagents(
  calls: ReadonlySet<string>,
  views: Record<string, AcpmuxRow[]> | undefined,
): Set<string> {
  const waiting = new Set<string>();
  if (calls.size === 0 || !views) return waiting;
  for (const [id, own] of Object.entries(views))
    if (own.some((row) => row.items?.some((item) => item.tool && calls.has(item.tool.id)))) waiting.add(id);
  return waiting;
}

/// A sub-session's state as a subagent row's status, for the row's dot and the card's counts.
export const SUBSESSION_STATUS: Record<SubsessionState, SubagentStatus> = {
  working: "running",
  input: "waiting",
  failed: "failed",
  done: "done",
};
