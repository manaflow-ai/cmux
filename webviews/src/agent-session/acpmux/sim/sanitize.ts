// l10n-allow-file: the chat simulator's sanitizer, not shipped UI.
// The chat simulator's sanitizer (sim/README.md "Replaying a real chat"): turns a real session's
// records (~/.acpmux/sessions/<id>/events/*.ndjson) into a fixture that is safe to commit. It keeps
// the chat's shape (which records, in what order, how far apart, how long each text is, where its
// lines and Markdown marks fall) and drops everything it said: every word and number becomes a
// stand-in of the same length, picked by a hash, so an id that recurs (a toolCallId, a promptId)
// maps to the same stand-in everywhere and the reducer still pairs a call with its result.
//
// Kept verbatim: only short enum-like values under the keys the reducer branches on (`kind`,
// `status`, `sessionUpdate`, `state`, ...). Dropped: the agent's own stdin (`out` records) and the
// harness's per-token noise, which the pane never reads.
import type { EventRecord } from "../direct";
import { SIM_SESSION, SIM_START } from "./script";

/** Keys whose short, enum-like string values stay as they are: the reducer branches on them. */
const KEEP_KEYS = new Set([
  "kind",
  "dir",
  "sessionUpdate",
  "status",
  "state",
  "type",
  "method",
  "jsonrpc",
  "stopReason",
  "actor",
  "display",
  "severity",
  "mode",
  "role",
  "tool",
  "origin",
  "trigger",
  "control",
  "priority",
  "level",
  "reason",
  "weight",
  "fromRole",
  "transport",
]);
const ENUM = /^[A-Za-z0-9][A-Za-z0-9_.\-/]{0,39}$/;

/** Record kinds the pane never reads: the harness's token stream and control chatter. */
const DROP_KINDS = new Set([
  "claude.system.thinking_tokens",
  "claude.stream_event",
  "claude.control_request",
  "claude.control_response",
  "claude.stdin",
  "claude.tool_progress",
  "claude.command_lifecycle",
  "claude.system.hook_started",
  "claude.system.hook_response",
  "claude.assistant",
  "claude.user",
  "claude.system.status",
  "claude.result.success",
  "_acpmux/claude/tool_gate",
  "usage_update",
  "config_option_update",
  // The session's own labels and settings: names and hosts, no chat.
  "tags",
  "config",
  "created",
]);

const WORDS =
  "the a and to of in it is for on that this with as at by from run test file fix read check build line call step part note".split(
    " ",
  );

function hash(value: string): number {
  let h = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    h ^= value.charCodeAt(index);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

/** A stand-in for one word or number: same length, same kind of characters, picked by its hash. */
function standIn(token: string): string {
  const h = hash(token);
  if (/^\d+$/.test(token)) {
    let out = "";
    for (let index = 0; index < token.length; index += 1) out += String((h >>> (index % 28)) % 10);
    return out;
  }
  let out = "";
  let pick = h;
  while (out.length < token.length) {
    out += WORDS[pick % WORDS.length];
    pick = Math.imul(pick ^ out.length, 0x01000193) >>> 0;
  }
  out = out.slice(0, token.length);
  return /^[A-Z]/.test(token) ? out[0]!.toUpperCase() + out.slice(1) : out;
}

/** Markup the pane reads in a prompt's text to tell what it is (conversation/incomingMessage.ts: another
 *  agent's message, a task notification, a reminder, an inbox notice) and a client's kind
 *  (`acpmux-cli#`): kept as they are, so a scrubbed incoming message is still drawn as one. */
const STRUCTURE = new RegExp(
  [
    String.raw`<\/?[a-z][\w-]*(?=[\s/>]|&gt;)`, // a tag's name (not an email: <name@host>) (<task-notification>, </system-reminder>)
    String.raw`(?<=<[\w-]+[^>]*\s)[\w-]+(?==)`, // an attribute's name
    String.raw`\[(?:cmux agent message|agent message|inbox|from|notice from)\b`,
    String.raw`\b(?:of|from|From|New messages from other agents|Another Claude session|A peer session|sent a message|while you were working|Request interrupted|Subagent hand-back|cmux agent message)\b`,
    String.raw`^acpmux(?:-cli|-peer|-outbox)?#?`,
    String.raw`^acp:`,
    String.raw`^(?:pane|acpmux|cli|mobile|cloud)$`,
  ].join("|"),
  "g",
);

/** Every run of letters or digits replaced; spaces, line breaks, punctuation (Markdown) and the markup the
 *  pane parses kept. */
export function scrubText(value: string): string {
  let out = "";
  let at = 0;
  for (const match of value.matchAll(STRUCTURE)) {
    if (match[0].length === 0) continue;
    out += value.slice(at, match.index).replace(/[\p{L}\p{N}_]+/gu, (token) => standIn(token)) + match[0];
    at = match.index! + match[0].length;
  }
  return out + value.slice(at).replace(/[\p{L}\p{N}_]+/gu, (token) => standIn(token));
}

/** Strings longer than this keep their first part only (a tool's output: the pane draws its first lines). */
const MAX_TEXT = 1_200;

function scrub(value: unknown, key: string | undefined): unknown {
  if (typeof value === "string") {
    if (key && KEEP_KEYS.has(key) && ENUM.test(value)) return value;
    // Who sent an incoming message, as the pane reads it (incomingMessage.ts): a named agent, or a
    // session by id after `acp:`.
    if (key === "from" && value === "fromAgent") return value;
    // An id's word parts are its kind (`bg-done-`, `call-`, `toolu_`): only the parts with a digit (the
    // unique part) are replaced.
    if (key === "sessionId") return SIM_SESSION;
    if (key && /id$/i.test(key) && value.length <= 120)
      return value.replace(/[\p{L}\p{N}]+/gu, (token) => (/\d/.test(token) ? standIn(token) : token));
    return scrubText(value.length > MAX_TEXT && key !== "text" ? value.slice(0, MAX_TEXT) : value);
  }
  if (Array.isArray(value)) return value.map((item) => scrub(item, key));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    // A call titled by its tool's name (`mcp__acpmux__wrap_up` before its input streams) keeps the
    // title: the name is the harness's, kept under `_meta.claude.tool` already, and the pane reads a
    // wrap-up's card from it (conversation/wrapUp.ts `isWrapUp`).
    const tool = (value as { _meta?: { claude?: { tool?: unknown } } })._meta?.claude?.tool;
    for (const [name, item] of Object.entries(value)) {
      if (name === "title" && typeof tool === "string" && item === tool && ENUM.test(tool)) {
        out[name] = item;
        continue;
      }
      const safeName = /^[A-Za-z_$][A-Za-z0-9_$]{0,40}$/.test(name) ? name : scrubText(name);
      out[safeName] = scrub(item, name);
    }
    return out;
  }
  return value;
}

export type SanitizeOptions = {
  /** Keep only records with seq in [from, to]. */
  from?: number;
  to?: number;
  /** Keep at most this many records (after the range). */
  limit?: number;
};

/// A real session's records, made safe to commit: see the file header.
export function sanitizeRecords(records: readonly EventRecord[], options: SanitizeOptions = {}): EventRecord[] {
  const kept = [...records]
    .filter((record) => record.dir !== "out" && !DROP_KINDS.has(record.kind))
    .filter((record) => record.seq >= (options.from ?? 0) && record.seq <= (options.to ?? Number.POSITIVE_INFINITY))
    .sort((a, b) => a.seq - b.seq)
    .slice(0, options.limit ?? Number.POSITIVE_INFINITY);
  const first = kept[0]?.at ?? 0;
  return kept.map((record, index) => ({
    sessionId: SIM_SESSION,
    seq: index + 1,
    at: SIM_START + (record.at - first),
    dir: record.dir,
    kind: record.kind,
    msg: scrub(record.msg, undefined) as Record<string, any>,
  }));
}

/// Reads NDJSON records (one per line; blank and broken lines skipped).
export function parseRecords(text: string): EventRecord[] {
  const out: EventRecord[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line) as EventRecord;
      if (typeof record.seq === "number" && typeof record.kind === "string") out.push(record);
    } catch {
      // A torn last line of a live chunk: skip it.
    }
  }
  return out;
}
