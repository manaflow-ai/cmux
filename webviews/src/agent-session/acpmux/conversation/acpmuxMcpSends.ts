// The acpmux MCP `send` tool's batch, file and tag shapes (acpmux_mcp_send.rs, #28671), read as
// one sent-message row per recipient, the rows a shell `acpmux send` draws (acpmuxSends.ts,
// SentMessageLine.tsx). The tool's first shape, `{to, text}`, stays agentMessages.ts's card.
//
// Input: `{to|tag, text|file, steer?, class?, pr?, thread?, supersede?}`, or `messages: [ … ]` of
// those items, up to 32, each merged over the call's top-level fields (they are its defaults). A
// `file` stands in for the text, which the input does not hold: the row names the file. A `tag`
// stands in for `to` and reaches every live session carrying it.
// Result: the first shape `{deliveryId, target, status, delivery, …}`, or `{results: [{index, to,
// target, tag, ok, status, delivery, error?, …}], sent, failed}` with a row per recipient (a tag
// item one per session it reached, all with that item's index); `isError` only when nothing went.
// Harnesses mostly record the text instead (`content[0].text`): a line per row ("Sent to X: …",
// "On its way to X …", "Not sent to X: …"), then "N of M sent.". Both are read. Until the result
// comes, each item is one row: its `to`, or its tag.
import type { AcpmuxActivity } from "../model";
import type { AcpmuxSendCallPart } from "./acpmuxSends";
import { mcpCall, type McpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
type Item = { to?: string; tag?: string; text?: string; file?: string; steer?: boolean };
type Result = { index?: number; to?: string; target?: string; ok?: boolean; status?: string };

/// The send call as an MCP call: `acpmux_send` on the cmux server, `send` on acpmux's own, or the
/// tool's bare or dotted name (`acpmux_send`, `cmux.acpmux_send`), which names its server here.
export function acpmuxMcpSendCall(tool: Tool): McpCall | undefined {
  if (tool.command) return undefined;
  const call = mcpCall(tool);
  if (call)
    return (call.server === "cmux" && call.tool === "acpmux_send") || (call.server === "acpmux" && call.tool === "send")
      ? call
      : undefined;
  return /^(?:cmux\.)?acpmux_send$/.test(tool.title.trim())
    ? { server: "cmux", tool: "acpmux_send", args: parse(tool.inputSummary) }
    : undefined;
}

function sendArgs(tool: Tool): Record<string, unknown> | undefined {
  return record(acpmuxMcpSendCall(tool)?.args);
}

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" && value.trim() ? value : undefined);

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
    ...(body || file
      ? { ...(body && { text: body }), ...(file && { file }) }
      : { text: defaults.text, file: defaults.file }),
    steer: typeof value.steer === "boolean" ? value.steer : defaults.steer,
  };
}

/// One result row as the call reports it.
type Row = { target?: string; ok: boolean; delivery?: "queued" | "delivered"; index?: number };

/// How a row says the receiver took it: `delivery` (`next_step`, `queued`, `started`, `sending`).
function deliveryOf(row: { delivery?: unknown }): Row["delivery"] {
  // `delivery` says how the message landed (present only when it went); `status` is the outbox's
  // state, where `queued` means still in this daemon's outbox, not queued behind a turn.
  if (row.delivery === "queued") return "queued";
  if (row.delivery === "next_step") return "delivered";
  return undefined;
}

/// One line of the tool's text (acpmux_mcp_send.rs `sent_line`): "Sent to X: steered into its
/// running turn…", "Sent to X: queued behind…", "Sent to X: it started a turn…", "On its way to X
/// (delivery …)", "Not sent to X: why", "Not sent to X (delivery …): why", "Not sent
/// (messages[2]): why". The last line, "N of M sent.", is no row.
const LINE =
  /^(?:Sent to (.+?): (steered|queued|it started)|On its way to (.+?) \(delivery|Not sent to (.+?)(?: \(delivery [^)]*\))?: |Not sent \(messages\[(\d+)\]\): )/;

function textRows(text: string): Row[] {
  const rows: Row[] = [];
  for (const line of text.split("\n")) {
    const match = LINE.exec(line.trim());
    if (!match) continue;
    if (match[1])
      rows.push({
        target: match[1],
        ok: true,
        delivery: match[2] === "queued" ? "queued" : match[2] === "steered" ? "delivered" : undefined,
      });
    else if (match[3]) rows.push({ target: match[3], ok: true });
    else if (match[4]) rows.push({ target: match[4], ok: false });
    else rows.push({ ok: false, index: Number(match[5]) });
  }
  return rows;
}

/// The result's rows: from its JSON when the harness recorded it (the whole result, its
/// `structuredContent`, or that alone), else from its text lines, which is what most harnesses
/// keep (`content[0].text`). The first shape's JSON (`{target, status, …}`) is one row.
function results(output: string | undefined): Row[] | undefined {
  const trimmed = output?.trim();
  if (!trimmed) return undefined;
  const value = record(parse(trimmed));
  if (value) {
    const structured = record(value.structuredContent) ?? value;
    if (Array.isArray(structured.results))
      return structured.results.map((entry) => {
        const row = (record(entry) ?? {}) as Result & { delivery?: unknown };
        return {
          // `to` is the session as named (or as the tag listing named it); `target` is a routing key.
          target: text(row.to) ?? text(row.target),
          ok: row.ok !== false && row.status !== "failed" && row.status !== "held",
          delivery: deliveryOf(row),
          ...(typeof row.index === "number" && { index: row.index }),
        };
      });
    // The first shape names only the routing key (`target`): the row keeps the `to` asked for.
    if (text(structured.target)) {
      const row = structured as Result & { delivery?: unknown };
      return [{ ok: value.isError !== true, delivery: deliveryOf(row) }];
    }
    const content = Array.isArray(value.content) ? record(value.content[0]) : undefined;
    if (typeof content?.text === "string") return textRows(content.text);
  }
  return textRows(trimmed);
}

/// The tool takes at most 32 items (more and it sends nothing) and reaches at most 64 sessions.
const ITEM_CAP = 32;
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
  if (!items.length || items.length > ITEM_CAP) return undefined;
  const running = tool.status === "pending" || tool.status === "in_progress";
  const failed = tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0);
  const rows = running ? undefined : results(tool.output);
  const count = rows?.length || items.length;
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
  // Text rows carry no index: in order, they are the items' while each item reached one session.
  const ordered = rows.every((row) => row.index === undefined) && rows.length === items.length;
  for (const [at, row] of rows.slice(0, MESSAGE_CAP).entries()) {
    const item = row.index !== undefined && items[row.index] ? row.index : ordered ? at : undefined;
    const one = item !== undefined ? items[item]! : items.length === 1 ? items[0]! : {};
    parts.push({
      ...base(one, at),
      // `index` is the row's place, unique per recipient (a tag item's sessions share its item).
      target: row.target ?? one.to ?? (one.tag ? `tag:${one.tag}` : "?"),
      state: row.ok ? "sent" : "failed",
      ...(row.ok && row.delivery && { delivery: row.delivery }),
    });
  }
  return parts;
}
