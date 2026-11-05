// A Claude Code Task or Agent call that no subagent record claimed, read as the subagent it ran: its
// kind (`subagent_type`), what it was asked to do (`description`), the prompt it got and the report
// it gave back. acpmux's own Claude driver sends a subagent before its call (claude_stdio/inbound.rs),
// which the subagent fold draws as its group row and drops the call; a chat acpmux adopted replays
// its past calls without one (adopt_tools.rs), as ACP kind `think` titled "Agent: …", and those
// drew as a plain tool row with the prompt nowhere and the report as raw text (AgentCallCard.tsx).
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type AgentCall = {
  /// The kind of agent, as Claude names it (`Explore`, `general-purpose`, a user agent).
  type?: string;
  /// Its few words of what it does ("Find the parser"), else the prompt's first line.
  description: string;
  prompt?: string;
  /// Its final report, without Claude Code's trailer (`agentId: …`, `<usage>…</usage>`).
  report?: string;
  running: boolean;
  failed: boolean;
  /// How long it ran and what it used, from the result's `<usage>` when it carries one.
  durationMs?: number;
  toolUses?: number;
  tokens?: number;
};

/// The Claude Code tool names that start a subagent, as the call's title says them.
const AGENT_TITLE = /^(?:Task|Agent)(?:\b|:)/u;

/// `tool` as a Claude subagent call, or undefined for any other call. It needs the call's input:
/// a `prompt`, and a `subagent_type` or a title that names the Task or Agent tool. A Workflow or
/// SendMessage call has no prompt, so never reads as one.
export function agentCall(tool: Tool): AgentCall | undefined {
  if (tool.command || (tool.kind !== undefined && tool.kind !== "think" && tool.kind !== "other")) return undefined;
  const input = parse(tool.inputSummary);
  const prompt = text(input?.prompt);
  if (!input || !prompt) return undefined;
  const type = text(input.subagent_type);
  if (!type && !AGENT_TITLE.test(tool.title.trim())) return undefined;
  const running = tool.status === "pending" || tool.status === "in_progress";
  const failed = tool.status === "failed";
  const split = running ? undefined : splitReport(tool.output ?? "");
  return {
    ...(type ? { type } : {}),
    description: text(input.description) ?? firstLine(prompt),
    prompt,
    ...(split?.report ? { report: split.report } : {}),
    running,
    failed,
    ...split?.usage,
  };
}

/// Claude Code's Agent result: the report, then a trailer of its own (the agentId a SendMessage
/// names, the worktree it used, and a `<usage>` block). The trailer is never the report.
export function splitReport(output: string): {
  report?: string;
  usage: Pick<AgentCall, "durationMs" | "toolUses" | "tokens">;
} {
  const usage: Pick<AgentCall, "durationMs" | "toolUses" | "tokens"> = {};
  const block = /<usage>([\s\S]*?)<\/usage>/u.exec(output);
  if (block) {
    const field = (name: string) => {
      const value = new RegExp(`\\b${name}:\\s*(\\d+)`, "u").exec(block[1]!)?.[1];
      return value === undefined ? undefined : Number(value);
    };
    const durationMs = field("duration_ms");
    const toolUses = field("tool_uses");
    const tokens = field("total_tokens");
    if (durationMs !== undefined) usage.durationMs = durationMs;
    if (toolUses !== undefined) usage.toolUses = toolUses;
    if (tokens !== undefined) usage.tokens = tokens;
  }
  // Only the trailing lines are the trailer: a report that itself says `agentId: …` keeps it.
  const lines = output.replace(/<usage>[\s\S]*?<\/usage>\s*$/u, "").split("\n");
  while (lines.length && (!lines.at(-1)!.trim() || TRAILER.test(lines.at(-1)!))) lines.pop();
  const report = lines.join("\n").trim();
  return { ...(report ? { report } : {}), usage };
}

const TRAILER = /^\s*(?:agentId|worktreePath|worktreeBranch):\s/u;

function parse(summary: string | undefined): Record<string, unknown> | undefined {
  if (!summary) return undefined;
  try {
    const value: unknown = JSON.parse(summary);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);

const firstLine = (value: string) =>
  value
    .split("\n", 1)[0]!
    .replace(/^#+\s*/u, "")
    .trim();
