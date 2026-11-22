// The acpmux MCP server's `wrap_up` tool (acpmux_mcp.rs): the agent's own end-of-turn box, typed.
// The agent calls it as the last step of a turn with `{recap, ask?, actions?}`. It arrives in the
// transcript as an ordinary tool call; this reads it back out, so the turn draws it as the
// next-step card (NextStepCard.tsx) under its answer, and drops the call's own row. Leo,
// 2026-11-03, watching Claude Code Desktop's next-step box: "yo wtf i want this kind of feature in
// cmux-next too". Reference: claude/web/october-recap-card (cmux-design-references).
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { isCmuxExec, readAnswer } from "./cmuxExec";
import { mcpCall } from "./mcpCalls";
import type { NextStepAsk, NextStepOption } from "./nextStepAsk";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The tool's name on acpmux's own server; behind the folding `cmux` server it is `acpmux_wrap_up`,
/// which a code-mode chat calls from a `cmux_exec` script.
export const WRAP_UP = "wrap_up";
const FOLDED = "acpmux_wrap_up";
/// The most answers a card draws; the tool asks for one or two.
const MAX_ACTIONS = 4;
const MAX_LABEL = 80;

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const words = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

function parse(summary: string | undefined): unknown {
  if (!summary?.trimStart().startsWith("{")) return undefined;
  try {
    return JSON.parse(summary);
  } catch {
    return undefined;
  }
}

/// Whether a tool call is the wrap-up call, under any of the names a harness gives it
/// (`mcp__acpmux__wrap_up`, `mcp__cmux__acpmux_wrap_up`, Codex's `{server, tool}` or a dotted name).
/// A `cmux_exec` script that called it is not: it may have done other work (`execWrapUp`).
export function isWrapUp(tool: Tool | undefined): tool is Tool {
  if (!tool || tool.command) return false;
  // Cheap first: every name it goes by, and Codex's `{server, tool}` input, holds the words.
  if (!tool.title.includes(WRAP_UP) && !tool.inputSummary?.includes(WRAP_UP)) return false;
  const call = mcpCall(tool);
  if (call)
    return (call.server === "acpmux" && call.tool === WRAP_UP) || (call.server === "cmux" && call.tool === FOLDED);
  return /^(?:(?:acpmux\.)?wrap_up|(?:cmux\.)?acpmux_wrap_up)$/.test(tool.title.trim());
}

/// A finished `cmux_exec` script that called the wrap-up (the default code-mode chat calls
/// `cmux.acpmux_wrap_up(...)` from one): what its last such call showed, and whether that call was
/// all the script did, so its row can go.
export function execWrapUp(tool: Tool | undefined): { shown: Record<string, unknown>; only: boolean } | undefined {
  if (!tool?.output || tool.command || !tool.inputSummary?.includes(FOLDED)) return undefined;
  const call = mcpCall(tool);
  if (!call || !isCmuxExec(call)) return undefined;
  const log = readAnswer(tool.output)?.callLog ?? [];
  const last = [...log].reverse().find((entry) => entry.name === FOLDED && entry.ok && entry.shown);
  return last?.shown ? { shown: last.shown, only: log.every((entry) => entry.name === FOLDED) } : undefined;
}

/// The call's card: its recap, and its question with one to four answers. A question without
/// answers gets Yes and Not now, as a yes-or-no tagged ask does. Undefined when the call carries no
/// recap and no question, or failed.
export function wrapUpAsk(tool: Tool): NextStepAsk | undefined {
  if (tool.status === "failed") return undefined;
  const exec = execWrapUp(tool);
  if (exec) return askOf(exec.shown);
  const call = mcpCall(tool);
  const args = record(call ? call.args : parse(tool.inputSummary));
  return args ? askOf(args) : undefined;
}

function askOf(args: Record<string, unknown>): NextStepAsk | undefined {
  const recap = words(args.recap);
  const question = words(args.ask);
  if (!recap && !question) return undefined;
  let options: NextStepOption[] = [];
  if (question) {
    const labels = Array.isArray(args.actions)
      ? args.actions
          .map((action) => words(typeof action === "string" ? action : record(action)?.label))
          .filter((label): label is string => label !== undefined && label.length <= MAX_LABEL)
      : [];
    const unique = [...new Set(labels)].slice(0, MAX_ACTIONS);
    options = unique.length
      ? unique.map((label) => ({ label }))
      : [
          { label: "Yes", key: "recap.yes" }, // l10n-allow: a prompt to the agent, not UI
          { label: "Not now", key: "recap.notNow" }, // l10n-allow: a prompt to the agent, not UI
        ];
  }
  return { tag: WRAP_UP, question: question ?? "", options, rest: "", ...(recap && { recap }) };
}

/// The last wrap-up call among a turn's rows, read as its card.
export function lastWrapUp(rows: readonly AcpmuxRow[]): NextStepAsk | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind !== "activity") continue;
    const items = row.items ?? [];
    for (let index = items.length - 1; index >= 0; index -= 1) {
      const tool = items[index]!.tool;
      if (tool && (isWrapUp(tool) || execWrapUp(tool))) {
        const ask = wrapUpAsk(tool);
        if (ask) return ask;
      }
    }
  }
  return undefined;
}

/// The turn's rows without the wrap-up calls, which the card draws instead (and a script that did
/// nothing else): an activity row loses those items, and goes when they were all it held.
export function withoutWrapUp(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  // Only a call the card stands in for goes: a failed or unfinished one keeps its row.
  const drawn = (tool: Tool | undefined) =>
    (isWrapUp(tool) && tool.status === "completed" && wrapUpAsk(tool) !== undefined) ||
    (tool?.status === "completed" && execWrapUp(tool)?.only === true);
  const out: AcpmuxRow[] = [];
  for (const row of rows) {
    if (row.kind !== "activity" || !(row.items ?? []).some((item) => drawn(item.tool))) {
      out.push(row);
      continue;
    }
    const items = row.items!.filter((item) => !drawn(item.tool));
    if (items.length) out.push({ ...row, items });
  }
  return out;
}
