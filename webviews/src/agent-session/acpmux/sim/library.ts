// The chat simulator's library of reported chats and its freshness check (sim/README.md "Reported
// chats" and "Keep it current").
//
// - `readSessionRecords` reads a recorded session's records for a range, opening only the event files
//   the range touches (a long chat is hundreds of 8 MB files; a reported moment is usually its tail).
// - A reported chat is a sanitized fixture in test/fixtures/chat-sim/ with a sidecar NAME.json: what
//   it reproduces, where it came from, and the violations it drew when recorded. `--reported` replays
//   them all and says, per chat, which rules now break more or less often than that.
// - `freshness` compares the record kinds recent real chats write with the kinds the simulator plays
//   (its scenarios and every fixture). A kind real chats write that no scenario or fixture plays is a
//   part of the pane the simulator cannot see.
import { closeSync, existsSync, openSync, readdirSync, readFileSync, readSync, statSync } from "node:fs";
import { join } from "node:path";
import type { EventRecord } from "../direct";
import type { SimResult } from "./run";
import { paneReads, parseRecords } from "./sanitize";
import type { SimScenario } from "./script";

export type RecordRange = {
  from?: number;
  to?: number;
  /** The last N seqs of the chat (applied before `from`/`to`). */
  last?: number;
};

/** The first line of a file, read in chunks (a record line can be hundreds of KB). */
function firstLine(path: string): string {
  const fd = openSync(path, "r");
  try {
    const chunk = Buffer.alloc(64 * 1024);
    const parts: Buffer[] = [];
    for (let at = 0; ;) {
      const read = readSync(fd, chunk, 0, chunk.length, at);
      if (read <= 0) break;
      const newline = chunk.subarray(0, read).indexOf(10);
      if (newline >= 0) {
        parts.push(Buffer.from(chunk.subarray(0, newline)));
        break;
      }
      parts.push(Buffer.from(chunk.subarray(0, read)));
      at += read;
    }
    return Buffer.concat(parts).toString("utf8");
  } finally {
    closeSync(fd);
  }
}

/** A file's first seq; undefined when its first line is not a record (the file is then always read). */
function firstSeq(path: string): number | undefined {
  try {
    const seq = JSON.parse(firstLine(path)).seq;
    return typeof seq === "number" ? seq : undefined;
  } catch {
    return undefined;
  }
}

/** The events directory of a session directory (or the directory itself), its files in order. */
export function eventFiles(path: string): string[] {
  const dir = existsSync(join(path, "events")) ? join(path, "events") : path;
  return readdirSync(dir)
    .filter((name) => name.endsWith(".ndjson"))
    .sort()
    .map((name) => join(dir, name));
}

const inRange = (record: EventRecord, from: number, to: number) => record.seq >= from && record.seq <= to;

/// A session directory's records (events/*.ndjson) or one NDJSON file's, within `range`. For a
/// directory it reads each file's first line, then parses only the files whose seqs can fall in the
/// range. Returns the records and how many files it parsed (of how many).
export function readSessionRecords(
  path: string,
  range: RecordRange = {},
): { records: EventRecord[]; filesRead: number; files: number } {
  let from = range.from ?? 0;
  let to = range.to ?? Number.POSITIVE_INFINITY;
  if (!statSync(path).isDirectory()) {
    let records = parseRecords(readFileSync(path, "utf8"));
    if (range.last !== undefined) {
      const lastSeq = records.reduce((max, record) => Math.max(max, record.seq), 0);
      from = Math.max(from, lastSeq - range.last + 1);
    }
    records = records.filter((record) => inRange(record, from, to));
    return { records, filesRead: 1, files: 1 };
  }
  const files = eventFiles(path);
  if (!files.length) return { records: [], filesRead: 0, files: 0 };
  const starts = files.map(firstSeq);
  const parsed = new Map<number, EventRecord[]>();
  const parse = (index: number) => {
    let records = parsed.get(index);
    if (!records) parsed.set(index, (records = parseRecords(readFileSync(files[index]!, "utf8"))));
    return records;
  };
  if (range.last !== undefined) {
    const lastSeq = parse(files.length - 1).reduce((max, record) => Math.max(max, record.seq), 0);
    from = Math.max(from, lastSeq - range.last + 1);
  }
  const records: EventRecord[] = [];
  for (let index = 0; index < files.length; index += 1) {
    const end = starts[index + 1] ?? Number.POSITIVE_INFINITY;
    const start = starts[index] ?? Number.NEGATIVE_INFINITY;
    if (end <= from || start > to) continue;
    for (const record of parse(index)) if (inRange(record, from, to)) records.push(record);
  }
  return { records, filesRead: parsed.size, files: files.length };
}

/** A reported chat's sidecar (test/fixtures/chat-sim/NAME.json). */
export type ReportedChat = {
  /** What it reproduces, in the words of whoever reported it when there are any. */
  about: string;
  /** Where the records came from: the session (its id only) and the range. */
  source: {
    session: string;
    from?: number;
    to?: number;
    last?: number;
    records: number;
  };
  recordedAt: string;
  /** Rows breaking each rule when it was recorded (or last `--reported --update`). */
  expect: Record<string, number>;
};

/** Rows breaking each rule (a row breaking one rule at many steps counts once). */
export function ruleCounts(result: Pick<SimResult, "violations">): Record<string, number> {
  const rows = new Map<string, Set<string>>();
  for (const violation of result.violations) {
    const set = rows.get(violation.rule) ?? new Set();
    set.add(violation.rowId);
    rows.set(violation.rule, set);
  }
  return Object.fromEntries([...rows].sort(([a], [b]) => a.localeCompare(b)).map(([rule, set]) => [rule, set.size]));
}

/** How `now` differs from `expect`, per rule: "a-head-gap 9 -> 0". Empty when the same. */
export function countChanges(expect: Record<string, number>, now: Record<string, number>) {
  const rules = [...new Set([...Object.keys(expect), ...Object.keys(now)])].sort();
  return rules
    .map((rule) => ({ rule, before: expect[rule] ?? 0, after: now[rule] ?? 0 }))
    .filter((change) => change.before !== change.after);
}

/** Every fixture in `dir` (NAME.ndjson) with its sidecar when it has one. */
export function fixtures(dir: string): { name: string; path: string; sidecar?: ReportedChat }[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".ndjson"))
    .sort()
    .map((file) => {
      const name = file.replace(/\.ndjson$/, "");
      const sidecarPath = join(dir, `${name}.json`);
      return {
        name,
        path: join(dir, file),
        sidecar: existsSync(sidecarPath) ? (JSON.parse(readFileSync(sidecarPath, "utf8")) as ReportedChat) : undefined,
      };
    });
}

/** A record's kind as the freshness check counts it: its direction and kind ("in tool_call"). */
export const kindKey = (record: Pick<EventRecord, "dir" | "kind">) => `${record.dir} ${record.kind}`;

/** The record kinds the simulator plays: every scenario's and every fixture's. */
export function playedKinds(scenarios: readonly SimScenario[], fixtureDir: string): Set<string> {
  const kinds = new Set<string>();
  for (const scenario of scenarios) for (const event of scenario.events) kinds.add(kindKey(event));
  for (const fixture of fixtures(fixtureDir))
    for (const record of parseRecords(readFileSync(fixture.path, "utf8"))) kinds.add(kindKey(record));
  return kinds;
}

export type SeenKind = { records: number; chats: Set<string>; example: string };

/// The record kinds the newest `sessions` chats in `root` wrote that the pane reads, from each chat's
/// newest events file (the kinds a chat writes now, at a bounded cost per chat).
export function seenKinds(root: string, sessions: number): { kinds: Map<string, SeenKind>; chats: number } {
  const chats = readdirSync(root)
    .map((name) => join(root, name))
    .filter((dir) => existsSync(join(dir, "events")))
    .map((dir) => ({ dir, mtime: statSync(join(dir, "events")).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, sessions);
  const kinds = new Map<string, SeenKind>();
  for (const { dir } of chats) {
    const files = eventFiles(dir);
    const newest = files.at(-1);
    if (!newest) continue;
    const chat = dir.split("/").at(-1)!;
    for (const record of parseRecords(readFileSync(newest, "utf8"))) {
      if (!paneReads(record)) continue;
      const key = kindKey(record);
      const entry = kinds.get(key) ?? {
        records: 0,
        chats: new Set(),
        example: `${chat} seq ${record.seq}`,
      };
      entry.records += 1;
      entry.chats.add(chat);
      kinds.set(key, entry);
    }
  }
  return { kinds, chats: chats.length };
}

/// What recent real chats write that the simulator never plays (`missing`, most chats first), and
/// what it plays that none of them wrote (`unseen`: kinds gone from real chats, or just rare).
export function freshness(played: Set<string>, seen: Map<string, SeenKind>) {
  const missing = [...seen]
    .filter(([key]) => !played.has(key))
    .sort((a, b) => b[1].chats.size - a[1].chats.size || b[1].records - a[1].records);
  const unseen = [...played].filter((key) => !seen.has(key)).sort();
  return { missing, unseen };
}
