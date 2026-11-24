import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { countChanges, replayReported, ruleCounts } from "../src/agent-session/acpmux/sim/reported";

test("counts rows once per rule and reports increases and decreases independently", () => {
  const now = ruleCounts([
    { rule: "a-head-gap", rowId: "r1" },
    { rule: "a-head-gap", rowId: "r1" },
    { rule: "a-head-gap", rowId: "r2" },
    { rule: "c-rerender", rowId: "r1" },
  ]);
  expect(now).toEqual({ "a-head-gap": 2, "c-rerender": 1 });
  expect(countChanges({ "a-head-gap": 9 }, now)).toEqual([
    { rule: "a-head-gap", before: 9, after: 2 },
    { rule: "c-rerender", before: 0, after: 1 },
  ]);
});

test("replays legacy fixtures with and without a sidecar; updating keeps capture metadata", () => {
  const dir = mkdtempSync(join(tmpdir(), "chat-sim-reported-"));
  try {
    for (const name of ["capture", "legacy", "standalone"])
      writeFileSync(join(dir, name + ".ndjson"), '{"seq":1,"dir":"mux","kind":"turn_started","at":100,"msg":{}}\n');
    const capture = join(dir, "capture.json");
    const legacy = join(dir, "legacy.json");
    writeFileSync(capture, JSON.stringify({ capturedAt: "2026-11-23", expect: { "c-rerender": 1 } }));
    writeFileSync(legacy, JSON.stringify({ records: 1 }));

    const lines: string[] = [];
    const log = (line: string) => lines.push(line);
    expect(replayReported(dir, false, log)).toBe(false);
    expect(lines.map((line) => line.split(" (")[0])).toEqual([
      "capture: c-rerender 1 -> 0",
      "legacy: no baseline",
      "standalone: no baseline",
    ]);
    expect(JSON.parse(readFileSync(capture, "utf8")).expect).toEqual({ "c-rerender": 1 });
    expect(existsSync(join(dir, "standalone.json"))).toBe(false);
    expect(replayReported(dir, true, log)).toBe(false);
    expect(JSON.parse(readFileSync(capture, "utf8"))).toEqual({ capturedAt: "2026-11-23", expect: {} });
    expect(JSON.parse(readFileSync(legacy, "utf8"))).toEqual({ records: 1, expect: {} });
    expect(JSON.parse(readFileSync(join(dir, "standalone.json"), "utf8"))).toEqual({ expect: {} });
  } finally {
    rmSync(dir, { recursive: true });
  }
});
