#!/usr/bin/env bun
// Turns a real acpmux session recording into a gallery fixture with none of its words (Leo,
// 2026-11-01: "how about like the apparatuses for improving ui verification? let's examine what we
// can do better for our workflows"). Synthetic fixtures miss what real chats look like: long tool
// runs, steers, agent inbox messages, outputs of every length. This keeps a recording's shape and
// drops its content:
//
//   - only the events the pane draws a transcript from (user messages, turns, tool calls and their
//     updates, message chunks);
//   - every word becomes a fixed neutral word of the same length and every digit a digit picked by
//     hash, so a line, a path, a command and a reply keep their length and their line breaks;
//   - ids become stable fake ones, times start at a fixed epoch, and names are dropped;
//   - a text past `MAX_TEXT` characters (a long tool output) keeps its first lines up to that, so a
//     fixture stays small; the pane folds or clips such an output long before.
// Protocol words (event kinds, update kinds, statuses, tool kinds, provenance kinds) stay as they
// are; nothing else does. Review the output before committing it all the same.
//
//   bun scripts/gallery/anonymize-recording.ts --in events.ndjson --out src/gallery/fixtures/recordings/NAME.ndjson \
//     [--from-seq N] [--to-seq M] [--max-chunks K]
import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";

const KEEP_KINDS = new Set([
  "created",
  "user_message",
  "turn_started",
  "status",
  "tool_call",
  "tool_call_update",
  "agent_message_chunk",
  "agent_thought_chunk",
  "turn_end",
  "turn_result",
]);

/** Keys whose string values are protocol words the pane switches on: kept verbatim. */
const PROTOCOL_KEYS = new Set([
  "kind",
  "sessionUpdate",
  "status",
  "type",
  "method",
  "jsonrpc",
  "dir",
  "itemType",
  "stopReason",
  "from",
  "harness",
  "family",
  "control",
  "model",
]);
/** Keys whose values are ids: mapped to stable fake ones. */
const ID_KEYS = /(^|_)(id|Id|ID)$|Id$|^to$|^client$|^terminal_id$/;
/** Keys that only name the sender or host: dropped to a neutral name. */
const NAME_KEYS = new Set(["fromName", "title", "displayName", "name", "host", "cwd"]);

const WORDS: Record<number, string[]> = {};
for (const word of (
  "a an as at be by do go if in is it me my no of on or so to up we " +
  "add all and any are bar can end fix for get has its log new not now one out run see set the top use " +
  "also area base call case code data done edit file fold from full give head item just keep kind last " +
  "line list made make mark more move name next note only open page part pass path read rest rows same " +
  "shape sheet short sound state steps still table tests their there these thing those three timer " +
  "update values change checks column double folder number output passes record should simple string " +
  "branches checked default history replace request summary between changed comment contents " +
  "described examples handling measured received recorded required rendered settings"
).split(" "))
  (WORDS[word.length] ??= []).push(word);

function hash(text: string): number {
  let value = 2166136261;
  for (let index = 0; index < text.length; index++) value = Math.imul(value ^ text.charCodeAt(index), 16777619);
  return value >>> 0;
}

/** A neutral word of `word`'s length (a long word: neutral words joined to its length). */
function neutralWord(word: string): string {
  const pick = (length: number, seed: number) => {
    const list = WORDS[length];
    return list ? list[seed % list.length]! : "x".repeat(length);
  };
  let out = "";
  let seed = hash(word);
  while (out.length < word.length) {
    const left = word.length - out.length;
    const take = left <= 9 ? left : Math.min(8, left - 2);
    out += (out ? "-" : "") + pick(out ? take - 1 : take, seed);
    seed = Math.imul(seed, 31) >>> 0;
  }
  out = out.slice(0, word.length);
  return word[0] === word[0]!.toUpperCase() && word[0] !== word[0]!.toLowerCase()
    ? out[0]!.toUpperCase() + out.slice(1)
    : out;
}

/** Same length, same line breaks, same punctuation; no word or number of the original. */
export const MAX_TEXT = 3000;

export function neutralText(text: string): string {
  const kept = text.length > MAX_TEXT ? text.slice(0, text.lastIndexOf("\n", MAX_TEXT) + 1 || MAX_TEXT) : text;
  return kept
    .replace(/[A-Za-zÀ-￿]+/g, (word) => neutralWord(word))
    .replace(/[0-9]+/g, (digits) => String(hash(digits)).padStart(digits.length, "7").slice(0, digits.length));
}

const ids = new Map<string, string>();
function fakeId(value: string): string {
  let id = ids.get(value);
  if (!id) ids.set(value, (id = `0190a000-0000-7000-8000-${String(ids.size + 1).padStart(12, "0")}`));
  return id;
}

function scrub(value: unknown, key = ""): unknown {
  if (typeof value === "string") {
    if (PROTOCOL_KEYS.has(key)) return value;
    if (ID_KEYS.test(key)) return fakeId(value);
    if (NAME_KEYS.has(key)) return key === "cwd" ? "/home/dev/project" : neutralText(value);
    return neutralText(value);
  }
  if (Array.isArray(value)) return value.map((item) => scrub(item, key));
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        // The terminal's own copy of an output the update's content already holds.
        .filter(([name]) => name !== "terminal_output_delta")
        .map(([name, item]) => [name, scrub(item, name)]),
    );
  return value;
}

export type Recorded = { seq: number; at: number; kind: string; sessionId?: string; [key: string]: unknown };

/** The fixture events of a recording: kept kinds only, scrubbed, renumbered from seq 1 and time 0. */
export function anonymize(events: Recorded[], options: { sessionId: string; maxChunks?: number }): Recorded[] {
  const kept = events.filter((event) => KEEP_KINDS.has(event.kind));
  const start = kept[0]?.at ?? 0;
  let chunks = 0;
  const out: Recorded[] = [];
  for (const event of kept) {
    if (event.kind === "agent_message_chunk" && options.maxChunks !== undefined && ++chunks > options.maxChunks)
      continue;
    const { seq: _seq, at, sessionId: _session, hostSeq: _hostSeq, ...rest } = event;
    out.push({
      sessionId: options.sessionId,
      seq: out.length + 1,
      at: 1_793_500_000_000 + (at - start),
      ...(scrub(rest) as Omit<Recorded, "seq" | "at">),
      kind: event.kind,
    });
  }
  return out;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      in: { type: "string" },
      out: { type: "string" },
      "from-seq": { type: "string" },
      "to-seq": { type: "string" },
      "max-chunks": { type: "string" },
      session: { type: "string", default: "0190a000-0000-7000-8000-0000000000d1" },
    },
  });
  if (!values.in || !values.out) throw new Error("--in and --out are required");
  const from = Number(values["from-seq"] ?? -Infinity);
  const to = Number(values["to-seq"] ?? Infinity);
  const events = readFileSync(values.in, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Recorded)
    .filter((event) => event.seq >= from && event.seq <= to);
  const fixture = anonymize(events, {
    sessionId: values.session!,
    maxChunks: values["max-chunks"] ? Number(values["max-chunks"]) : undefined,
  });
  writeFileSync(values.out, `${fixture.map((event) => JSON.stringify(event)).join("\n")}\n`);
  console.log(`${fixture.length} events -> ${values.out}`);
}
