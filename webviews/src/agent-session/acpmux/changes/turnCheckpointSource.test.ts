import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { readTurnCheckpoint } from "./turnCheckpoint";
import { readSummaryCheckpoint, readTurnFromRows } from "./turnCheckpointSource";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}) =>
  ({ id, version: 1, at: 1, kind, ...extra }) as AcpmuxRow;
const turn = (summary?: Partial<AcpmuxRow>) => [
  row("u1", "user", { text: "go" }),
  row("a1", "activity"),
  ...(summary ? [row("s1", "turnSummary", summary)] : []),
];

test("a turn_result's checkpoints read as acpmux recorded them", () => {
  expect(readSummaryCheckpoint({ status: "completed" })).toBeUndefined();
  expect(readSummaryCheckpoint({ checkpointId: "a", endCheckpointId: "b" })).toEqual({ from: "a", to: "b" });
  expect(readSummaryCheckpoint({ checkpointId: "a" })).toEqual({ from: "a" });
  expect(readSummaryCheckpoint({ checkpointId: null, checkpointError: "timed_out" })).toEqual({
    from: null,
    reason: "timed_out",
  });
});

test("a turn that has not ended is refused, so it is asked again later", async () => {
  await expect(readTurnFromRows(turn(), "u1", () => Promise.resolve({}))).rejects.toThrow();
});

test("an agent that records no checkpoints leaves the tool-call view with no note", async () => {
  const wire = await readTurnFromRows(turn({}), "u1", () => Promise.reject(new Error("not asked")));
  expect(wire).toEqual({ unsupported: true });
  expect(readTurnCheckpoint(wire).state).toBe("unsupported");
});

test("an ended turn without both checkpoints has no pair, and the host is not asked", async () => {
  const asked: string[] = [];
  const diff = (from: string) => (asked.push(from), Promise.resolve({}));
  expect(await readTurnFromRows(turn({ checkpoint: { from: null, reason: "timed_out" } }), "u1", diff)).toBeNull();
  expect(await readTurnFromRows(turn({ checkpoint: { from: "a" } }), "u1", diff)).toBeNull();
  expect(asked).toEqual([]);
});

test("an ended turn's pair is diffed on the host and loads as the turn's checkpoint", async () => {
  const asked: [string, string][] = [];
  const diff = {
    root: "/repo",
    files: [{ path: "a.ts", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n a\n+b\n" }],
    total_files: 1,
    files_omitted: 0,
    complete: true,
  };
  const wire = await readTurnFromRows(turn({ checkpoint: { from: "a", to: "b" } }), "a1", (from, to) => {
    asked.push([from, to]);
    return Promise.resolve(diff);
  });
  expect(asked).toEqual([["a", "b"]]);
  expect(wire).toEqual({ checkpoint_id: "a..b", complete: true, diff });
  const load = readTurnCheckpoint(wire);
  expect(load.state).toBe("loaded");
});

test("files a checkpoint or the read left out leave the pair incomplete", async () => {
  const read = async (extra: object) => {
    const wire = await readTurnFromRows(turn({ checkpoint: { from: "a", to: "b" } }), "u1", () =>
      Promise.resolve({ root: "/repo", files: [], ...extra }),
    );
    return readTurnCheckpoint(wire).state;
  };
  expect(await read({ complete: true, files_omitted: 0 })).toBe("loaded");
  // A checkpoint skipped an oversized file the agent may have edited.
  expect(await read({ complete: false, files_omitted: 0 })).toBe("incomplete");
  expect(await read({ complete: true, files_omitted: 2 })).toBe("incomplete");
  // A host that does not say is not trusted to be complete.
  expect(await read({ files_omitted: 0 })).toBe("incomplete");
});
