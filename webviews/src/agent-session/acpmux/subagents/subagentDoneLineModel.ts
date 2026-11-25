import { createContext } from "react";
import { type DoneReportLook } from "./doneReport.experiment";

/// Where a failed line's Retry sits: an inline button (the default), a link after the line's
/// time, or only in the ⋯ menu. The gallery compares them (SubagentRetry.gallery.tsx).
export type RetryAffordance = "button" | "link" | "menu";
export const RetryAffordanceContext = createContext<RetryAffordance>("button");

/// The report's look a gallery variant pins (SubagentDoneLine.gallery.tsx); the pane leaves it
/// unset and reads the experiment's arm.
export const DoneReportLookContext = createContext<DoneReportLook | undefined>(undefined);

/// What a finished subagent reported, for its line: its final reply, else its last message. Only
/// a completed line has one to show; a failed, stopped or retrying line says why on the line.
export function doneReport(agent: { state: string; result?: string; lastMessage?: string }): string | undefined {
  if (agent.state !== "completed") return undefined;
  return (agent.result ?? agent.lastMessage)?.trim() || undefined;
}

/// A failure's reason as a failed line shows it: its first sentence, the rest in the tooltip and the
/// button's name ("Agent terminated early due to an API error. Retry with …" reads its first part).
export function shortReason(error: string): string {
  const line = error.trim().split("\n")[0]!.trim();
  const sentence = /^(.+?[.!?])(?:\s|$)/u.exec(line);
  return (sentence ? sentence[1]! : line).replace(/[.]$/u, "");
}

/// How soon after its start a failed subagent that did no work counts as refused, not run.
export const REFUSED_WITHIN_MS = 1_000;

/// A subagent the harness refused to start (Claude Code's "Concurrent subagent limit reached", any
/// spawn error): it failed within a moment of its start, never worked (no tokens, no tool call, no
/// reply, no agent id, no chat of its own) and nothing retries it. It is the parent's own failed
/// tool call, which the parent already read and acts on: its line reads its name and one short
/// status, with no Retry, Restart, menu or time (Leo, 2026-11-11, on such a row with "Ask parent to
/// retry", ↺, ⋯ and "13ms": "this is kind of weird tbh").
export function spawnRefused(agent: {
  state: string;
  parent?: string | null;
  startedAt: number;
  endedAt?: number;
  tokens?: number;
  toolUses?: number;
  result?: string;
  lastMessage?: string;
  agentId?: string;
  child?: string;
  retry?: unknown;
  retriedOut?: unknown;
}): boolean {
  if (agent.state !== "failed" || agent.endedAt === undefined) return false;
  if (agent.endedAt - agent.startedAt > REFUSED_WITHIN_MS) return false;
  if (agent.tokens || agent.toolUses || agent.agentId || agent.child) return false;
  if (agent.result?.trim() || agent.lastMessage?.trim()) return false;
  return !agent.retry && !agent.retriedOut;
}

/// The controls an ended line offers. Retry and Restart both run it again, so a line offers one:
/// Retry where it failed and can be retried, else Restart. A control is either on the line or in
/// its ⋯ menu, never both (Leo, 2026-11-11: "why were all these added in the first place?", on
/// "Ask parent to retry" on the line and again as the menu's only item): the menu exists only for
/// the `menu` affordance, where the line has no inline Retry.
export type DoneLineControl = "retry" | "restart";
export function doneLineControls(options: {
  retry: boolean;
  restart: boolean;
  affordance: RetryAffordance;
  refused?: boolean;
}): { line: DoneLineControl[]; menu: DoneLineControl[] } {
  if (options.refused) return { line: [], menu: [] };
  if (options.retry)
    return options.affordance === "menu" ? { line: [], menu: ["retry"] } : { line: ["retry"], menu: [] };
  return { line: options.restart ? ["restart"] : [], menu: [] };
}
