// Read a session directory, its events/ directory, or a standalone NDJSON replay.
import { createReadStream, existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";
import type { EventRecord } from "../direct";
import { parseRecords } from "./sanitize";

function eventFiles(path: string): string[] {
  if (!statSync(path).isDirectory()) return [path];
  const dir = existsSync(join(path, "events")) ? join(path, "events") : path;
  return readdirSync(dir)
    .filter((name) => name.endsWith(".ndjson"))
    .sort()
    .map((name) => join(dir, name));
}

const readFile = (path: string) => parseRecords(readFileSync(path, "utf8"));

export function readRecords(path: string): EventRecord[] {
  return eventFiles(path).flatMap(readFile);
}

async function firstSeq(path: string): Promise<number | undefined> {
  const input = createReadStream(path, { encoding: "utf8" });
  try {
    for await (const line of createInterface({ input, crlfDelay: Infinity })) {
      const record = parseRecords(line)[0];
      if (record) return record.seq;
    }
  } finally {
    input.destroy();
  }
}

/** Numbered acpmux segments have increasing, non-overlapping seqs. Probe their first records to
 * locate the range without parsing earlier segments. With empty segments, use the next nonempty
 * segment's first seq as their boundary. */
async function upperBound(files: string[], target: number, starts: Map<number, number | undefined>): Promise<number> {
  let lo = 0;
  let hi = files.length;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    let next = mid;
    while (next < hi) {
      if (!starts.has(next)) starts.set(next, await firstSeq(files[next]!));
      if (starts.get(next) !== undefined) break;
      next++;
    }
    if (next < hi && starts.get(next)! <= target) lo = next + 1;
    else hi = mid;
  }
  return lo;
}

type Range = { from?: number; to?: number; last?: number };

export async function readReplayRange(path: string, range: Range) {
  const files = eventFiles(path);
  let from = range.from ?? 0;
  const to = range.to ?? Infinity;
  const inRange = (record: EventRecord) => record.seq >= from && record.seq <= to;
  const count = files.length;
  // Single files and arbitrary fixture directories can contain records in any order.
  const firstName = basename(files[0] ?? "");
  if (
    count < 2 ||
    files.some((file) => {
      const name = basename(file);
      return name.length !== firstName.length || !/^\d+\.ndjson$/.test(name);
    })
  ) {
    const all = files.flatMap(readFile);
    if (range.last !== undefined) {
      const end = all.reduce((max, record) => Math.max(max, record.seq), 0);
      from = Math.max(from, end - range.last + 1);
    }
    return { records: all.filter(inRange), parsed: count, count };
  }

  let parsed = 0;
  let tail: EventRecord[] | undefined;
  if (range.last !== undefined) {
    // A just-rotated live segment can still be empty or have only a partial line.
    while (files.length) {
      tail = readFile(files[files.length - 1]!);
      parsed++;
      if (tail.length) break;
      files.pop();
    }
    const end = tail?.at(-1)?.seq ?? 0;
    from = Math.max(from, end - range.last + 1);
  }

  const starts = new Map<number, number | undefined>();
  if (tail?.length) starts.set(files.length - 1, tail[0]!.seq);
  const records: EventRecord[] = [];
  if (from <= to) {
    let begin = 0;
    if (tail?.length && from >= tail[0]!.seq) begin = files.length - 1;
    else if (range.from !== undefined || range.last !== undefined)
      begin = Math.max(0, (await upperBound(files, from, starts)) - 1);
    const end = range.to === undefined ? files.length : await upperBound(files, to, starts);
    for (let index = begin; index < end; index++) {
      const cached = index === files.length - 1 ? tail : undefined;
      const chunk = cached ?? readFile(files[index]!);
      if (!cached) parsed++;
      for (const record of chunk) if (inRange(record)) records.push(record);
    }
  }
  return { records, parsed, count };
}
