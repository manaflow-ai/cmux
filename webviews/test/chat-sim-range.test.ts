import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readRecords, readReplayRange } from "../src/agent-session/acpmux/sim/records";

let session: string;
let events: string;
beforeEach(() => {
  session = mkdtempSync(join(tmpdir(), "chat-sim-range-"));
  events = join(session, "events");
  mkdirSync(events);
});
afterEach(() => rmSync(session, { recursive: true }));

const record = (seq: number) => JSON.stringify({ seq, at: seq, dir: "mux", kind: "turn_started", msg: {} });
function segment(name: string, seqs: number[], prefix = "") {
  const path = join(events, name + ".ndjson");
  writeFileSync(path, prefix + seqs.map(record).join("\n"));
  return path;
}

test("inclusive and tail ranges parse only the selected numbered segments", async () => {
  segment("000001", [1, 2, 3]);
  segment("000002", [4, 5, 6]);
  segment("000003", [7, 8, 9]);

  for (const [range, expected, parsed] of [
    [{ from: 7 }, [7, 8, 9], 1],
    [{ to: 3 }, [1, 2, 3], 1],
    [{ from: 5, to: 7 }, [5, 6, 7], 2],
    [{ last: 4 }, [6, 7, 8, 9], 2],
    [{ last: 2 }, [8, 9], 1],
    [{ last: 2, from: 9, to: 9 }, [9], 1],
  ] as const) {
    const result = await readReplayRange(session, range);
    expect(result.records.map((r) => r.seq)).toEqual([...expected]);
    expect(result.parsed).toBe(parsed);
  }
});

test("empty segments, partial lines and sequence gaps match filtering a full replay", async () => {
  segment("000001", []);
  segment("000002", [3, 5], "incomplete\n\n");
  segment("000003", []);
  segment("000004", [9, 13], record(8).replace('"msg":{}', '"msg":{"text":"' + "x".repeat(140_000) + '"}') + "\n");
  segment("000005", [], '{"seq":');
  const all = readRecords(events);
  for (const range of [
    { from: 1, to: 2 },
    { from: 4, to: 5 },
    { from: 6, to: 8 },
    { from: 8, to: 8 },
    { from: 14 },
    { last: 6 },
    { last: 0 },
    { last: 5, to: 8 },
  ]) {
    const from = Math.max(range.from ?? 0, range.last === undefined ? 0 : 14 - range.last);
    expect((await readReplayRange(events, range)).records).toEqual(
      all.filter((record) => record.seq >= from && record.seq <= (range.to ?? Infinity)),
    );
  }
});

test("standalone files and named fixture directories preserve input order", async () => {
  const path = segment("first", [15, 4, 8]);
  segment("second", [16, 3]);
  expect((await readReplayRange(path, { last: 9 })).records.map((r) => r.seq)).toEqual([15, 8]);
  expect((await readReplayRange(session, { from: 3, to: 8 })).records.map((r) => r.seq)).toEqual([4, 8, 3]);
});
