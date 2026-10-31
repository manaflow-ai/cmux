// The acpmux MCP `send` tool's batch, file and tag shapes (acpmux_mcp_send.rs, #28671), read as
// one sent-message row per recipient, the rows a shell `acpmux send` draws (acpmuxSends.ts,
// SentMessageLine.tsx). The tool's first shape, `{to, text}`, stays agentMessages.ts's card.
//
// Input: `{to|tag, text|file, steer?, class?, pr?, thread?, supersede?}`, or `messages: [ … ]` of
// those items, up to 32, each merged over the call's top-level fields (they are its defaults). A
// `file` stands in for the text, which the input does not hold: the row names the file. A `tag`
// stands in for `to` and reaches every live session carrying it.
// Result: one shape `{target, status, …}`, or `{results: [{index, to, target, tag, ok, status,
// error?, …}], sent, failed}` with a row per recipient (a tag item one per session it reached, all
// with that item's index). Until the result comes, each item is one row: its `to`, or its tag.
import type { AcpmuxActivity } from "../model";
import type { AcpmuxSendCallPart } from "./acpmuxSends";
import { mcpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
type Item = { to?: string; tag?: string; text?: string; file?: string; steer?: boolean };
type Result = {
  index?: number;
  to?: string;
  target?: string;
  tag?: string;
  ok?: boolean;
  status?: string;
  error?: string;
};

/// The tool calls this file reads: `acpmux_send` on the cmux server, `send` on acpmux's own.
function sendArgs(tool: Tool): Record<string, unknown> | undefined {
  if (tool.command) return undefined;
  const call = mcpCall(tool);
  const named = call
    ? (call.server === "cmux" && call.tool === "acpmux_send") || (call.server === "acpmux" && call.tool === "send")
    : /^(?:cmux\.)?acpmux_send$/.test(tool.title.trim());
  if (!named) return undefined;
  const args = call ? call.args : parse(tool.inputSummary);
  return record(args);
}

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value : undefined;

function parse(summary: string | undefined): unknown {
  if (!summary?.trimStart().startsWith("{")) return undefined;
  try {
    return JSON.parse(summary);
  } catch {
    return undefined;
  }
}

function item(value: Record<string, unknown>, defaults: Item): Item {
  const to = text(value.to);
  const tag = text(value.tag);
  const body = text(value.text);
  const file = text(value.file);
  return {
    // An item's own recipient replaces the default one, whichever form either takes.
    ...(to || tag ? { ...(to && { to }), ...(tag && { tag }) } : { to: defaults.to, tag: defaults.tag }),
    ...(body || file ? { ...(body && { text: body }), ...(file && { file }) } : { text: defaults.text, file: defaults.file }),
    steer: typeof value.steer === "boolean" ? value.steer : defaults.steer,
  };
}

/// The result rows, from the call's output: the JSON the tool returns (or its `structuredContent`).
function results(output: string | undefined): Result[] | undefined {
  const value = record(parse(output?.trim()));
  const rows = value?.results ?? record(value?.structuredContent)?.results;
  return Array.isArray(rows) ? rows.map((row) => record(row) ?? {}) : undefined;
}

const MESSAGE_CAP = 64;

/// The messages an acpmux MCP send call with `messages`, `file` or `tag` makes, one per recipient
/// with its state; nil for any other call, and for the first shape (`{to, text}`), which
/// agentMessages.ts draws.
export function acpmuxMcpSends(tool: Tool): AcpmuxSendCallPart[] | undefined {
  const args = sendArgs(tool);
  if (!args) return undefined;
  const list = Array.isArray(args.messages) ? args.messages : undefined;
  if (!list && !text(args.file) && !text(args.tag)) return undefined;
  const defaults = item(args, {});
  const items = list ? list.map((entry) => item(record(entry) ?? {}, defaults)) : [defaults];
  if (!items.length || items.length > MESSAGE_CAP) return undefined;
  const running = tool.status === "pending" || tool.status === "in_progress";
  const failed = tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0);
  const rows = running ? undefined : results(tool.output);
  const count = items.length;
  const base = (one: Item, index: number) => ({
    ...(one.text && { text: one.text }),
    ...(!one.text && one.file && { file: one.file }),
    noWait: true,
    index,
    count,
  });
  if (!rows?.length)
    return items.map((one, index): AcpmuxSendCallPart => ({
      ...base(one, index),
      target: one.to ?? (one.tag ? `tag:${one.tag}` : "?"),
      // Without per-recipient rows, the call's own status is every message's. A call that failed
      // sent nothing (`isError` is set only when nothing went).
      state: running ? "sending" : failed ? "failed" : "sent",
    }));
  const parts: AcpmuxSendCallPart[] = [];
  for (const row of rows.slice(0, MESSAGE_CAP)) {
    const index = typeof row.index === "number" && items[row.index] ? row.index : parts.length;
    const one = items[index] ?? {};
    const status = row.status;
    const bad = row.ok === false || status === "failed";
    const held = status === "held";
    parts.push({
      ...base(one, index),
      target: text(row.target) ?? text(row.to) ?? one.to ?? (one.tag ? `tag:${one.tag}` : "?"),
      state: bad ? "failed" : held ? "ended" : "sent",
      ...(status === "queued" && { delivery: "queued" as const }),
      ...(status === "delivered" && { delivery: "delivered" as const }),
    });
  }
  return parts;
}
