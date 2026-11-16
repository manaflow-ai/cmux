/**
 * The chat's ingest queue (cmuxterm-hq docs/design/chat-instant-under-load.md, "Ingest is a queue, not a
 * task"). A host push used to be parsed and reduced in the task that delivered it, up to 512 frames at
 * once; now `receive` stores the stream frames and returns, and the frame lane drains them in slices.
 *
 * This file holds the pure parts: which frames are stream frames (read from the frame's head without
 * parsing it), and how consecutive stream records coalesce before the reducer sees them. The client
 * (direct.ts) holds the queue and the drain.
 */

import type { EventRecord } from "./direct";

/** How far into a frame `isStreamFrame` reads before it gives up and lets the frame be parsed now. */
const SNIFF_LIMIT = 160;

/**
 * Whether `raw` is a JSON-RPC notification whose top-level method is a chat stream record
 * (`_acpmux/event` or `session/update`): those wait in the queue. Reads only the head of the frame,
 * tracking depth so a method named inside params (a reply's page of records) never counts. Anything
 * it cannot tell is not a stream frame: the client parses it at once, and a stream record found that
 * way still joins the queue behind the ones waiting, so order holds either way.
 */
export function isStreamFrame(raw: string): boolean {
  const end = Math.min(raw.length, SNIFF_LIMIT);
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = 0; index < end; index += 1) {
    const char = raw.charCodeAt(index);
    if (inString) {
      if (escaped) escaped = false;
      else if (char === 0x5c /* \ */) escaped = true;
      else if (char === 0x22 /* " */) inString = false;
      continue;
    }
    if (char === 0x22) {
      if (depth === 1 && raw.startsWith('"method":', index)) {
        let at = index + 9;
        while (at < raw.length && (raw.charCodeAt(at) === 0x20 || raw.charCodeAt(at) === 0x09)) at += 1;
        return raw.startsWith('"_acpmux/event"', at) || raw.startsWith('"session/update"', at);
      }
      inString = true;
    } else if (char === 0x7b /* { */ || char === 0x5b /* [ */) {
      depth += 1;
      if (depth > 1) return false;
    } else if (char === 0x7d /* } */ || char === 0x5d /* ] */) depth -= 1;
  }
  return false;
}

/**
 * One fold: the page holds `hold` (its held window and its seqs, every record, as before), then the
 * reducer folds `reduce`. For a record alone `hold` is `[reduce]`; for a coalesced run `reduce` stands
 * for its `hold` records folded one by one, and carries the last one's seq.
 */
export interface IngestStep {
  hold: EventRecord[];
  reduce: EventRecord;
}

function updateOf(event: EventRecord): any {
  return event.dir === "in" && event.msg?.method === "session/update" ? event.msg.params?.update : undefined;
}

/** The text of a content that is one text block (`{type:"text",text}`, or an array of one). */
function plainText(content: unknown): string | undefined {
  const block = Array.isArray(content) ? (content.length === 1 ? content[0] : undefined) : content;
  if (!block || typeof block !== "object") return undefined;
  const { type, text } = block as { type?: unknown; text?: unknown };
  return type === "text" && typeof text === "string" && Object.keys(block).length === 2 ? text : undefined;
}

/** A `_meta` without the stamps every record carries its own of (`acpmux.seq`, `acpmux.at`). */
function metaKey(meta: unknown): unknown {
  if (!meta || typeof meta !== "object") return meta;
  const acpmux = (meta as { acpmux?: unknown }).acpmux;
  if (!acpmux || typeof acpmux !== "object") return meta;
  const { seq: _seq, at: _at, ...rest } = acpmux as Record<string, unknown>;
  return { ...(meta as object), acpmux: rest };
}

/** Everything about a record but its seq, time and text: two records with the same key fold alike. */
function textRunKey(event: EventRecord): string | undefined {
  if (event.kind !== "agent_message_chunk" && event.kind !== "agent_thought_chunk") return undefined;
  const update = updateOf(event);
  if (!update || update.sessionUpdate !== event.kind) return undefined;
  const text = plainText(update.content);
  if (!text) return undefined;
  for (const key of Object.keys(update))
    if (key !== "sessionUpdate" && key !== "content" && key !== "messageId" && key !== "_meta") return undefined;
  const params = event.msg.params ?? {};
  for (const key of Object.keys(params))
    if (key !== "sessionId" && key !== "update" && key !== "_meta") return undefined;
  for (const key of Object.keys(event.msg))
    if (key !== "method" && key !== "params" && key !== "jsonrpc") return undefined;
  return JSON.stringify([
    event.kind,
    event.sessionId,
    params.sessionId,
    update.messageId,
    metaKey(update._meta),
    metaKey(params._meta),
  ]);
}

/** A tool call's output update and nothing else (no status, title or other field): the newest one says it all. */
function outputRunKey(event: EventRecord): string | undefined {
  if (event.kind !== "tool_call_update") return undefined;
  const update = updateOf(event);
  if (!update || update.sessionUpdate !== "tool_call_update" || typeof update.toolCallId !== "string") return undefined;
  const content = update.content;
  if (
    !Array.isArray(content) ||
    content.length === 0 ||
    !content.every(
      (block: any) => block?.type === "text" || (block?.type === "content" && block.content?.type === "text"),
    )
  )
    return undefined;
  for (const key of Object.keys(update))
    if (key !== "sessionUpdate" && key !== "content" && key !== "toolCallId" && key !== "_meta") return undefined;
  const params = event.msg.params ?? {};
  for (const key of Object.keys(params))
    if (key !== "sessionId" && key !== "update" && key !== "_meta") return undefined;
  for (const key of Object.keys(event.msg))
    if (key !== "method" && key !== "params" && key !== "jsonrpc") return undefined;
  return JSON.stringify([
    event.sessionId,
    params.sessionId,
    update.toolCallId,
    metaKey(update._meta),
    metaKey(params._meta),
  ]);
}

/** The run's text in one record: the last record's seq and time, every record's text in order. */
function joinedText(run: EventRecord[]): EventRecord {
  const last = run[run.length - 1]!;
  const update = updateOf(last);
  const text = run.map((event) => plainText(updateOf(event).content)).join("");
  return {
    ...last,
    msg: {
      ...last.msg,
      params: { ...last.msg.params, update: { ...update, content: { type: "text", text } } },
    },
  };
}

/**
 * Coalesces consecutive stream records before they are reduced. Never across kinds or calls, never
 * reordered, and every record still held (its seq kept):
 * - a run of text chunks of one reply or thought (same message, segment and meta): the first is folded
 *   alone (it may start the row), the rest as one chunk with their text joined;
 * - a run of output-only updates of one tool call: the first and the newest are folded, since a call's
 *   content replaces the one before (`mergeToolItem`); the ones between say nothing the newest does not.
 */
export function coalesceStream(records: readonly EventRecord[]): IngestStep[] {
  const steps: IngestStep[] = [];
  let index = 0;
  while (index < records.length) {
    const first = records[index]!;
    const textKey = textRunKey(first);
    const outputKey = textKey === undefined ? outputRunKey(first) : undefined;
    const key = textKey ?? outputKey;
    let end = index + 1;
    if (key !== undefined) {
      const keyOf = textKey !== undefined ? textRunKey : outputRunKey;
      while (end < records.length && keyOf(records[end]!) === key) end += 1;
    }
    // The run's first record folds alone (it may open the row, under its own seq); the rest fold as one.
    steps.push({ hold: [first], reduce: first });
    if (end - index === 2) steps.push({ hold: [records[index + 1]!], reduce: records[index + 1]! });
    else if (end - index > 2) {
      const rest = records.slice(index + 1, end);
      steps.push({ hold: rest, reduce: textKey !== undefined ? joinedText(rest) : rest[rest.length - 1]! });
    }
    index = end;
  }
  return steps;
}

/**
 * Whether `raw` is a reply to a request: a top-level `"id"` and no top-level `"method"` (acpmux writes keys
 * sorted, so an error reply starts `{"error":`). Read from the frame's top level only, to its end or its
 * `"method"`; a frame it cannot read is not a reply (`receive` then folds the queue before it, which is
 * always safe).
 */
export function isReplyFrame(raw: string): boolean {
  let depth = 0;
  let inString = false;
  let escaped = false;
  let id = false;
  for (let index = 0; index < raw.length; index += 1) {
    const char = raw.charCodeAt(index);
    if (inString) {
      if (escaped) escaped = false;
      else if (char === 0x5c) escaped = true;
      else if (char === 0x22) inString = false;
      continue;
    }
    if (char === 0x22) {
      if (depth === 1) {
        if (raw.startsWith('"method"', index)) return false;
        if (raw.startsWith('"id"', index)) id = true;
      }
      inString = true;
    } else if (char === 0x7b || char === 0x5b) depth += 1;
    else if (char === 0x7d || char === 0x5d) depth -= 1;
  }
  return id;
}
