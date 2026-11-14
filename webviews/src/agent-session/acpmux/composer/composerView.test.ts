import { expect, test } from "bun:test";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { queuePauseReason } from "../queuePause";
import { composerRows, composerView, sameComposerView } from "./composerView";

const row = (id: string, kind: AcpmuxRow["kind"], extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind, ...extra }) as AcpmuxRow;

const start = row("start", "sessionStart");
const prompt = row("p1", "user", { text: "fix the build" });
const reply = row("a1", "assistant", { text: "on it" });
const tool = row("t1", "tool");
const failed = row("s1", "turnSummary", { status: "failed", error: "rate limited" } as Partial<AcpmuxRow>);
const queued = row("q1", "user", { text: "next", queued: {} } as Partial<AcpmuxRow>);

test("the composer's rows keep what it reads: prompts, queued, failed turns, the first and the first started", () => {
  const rows = [start, prompt, reply, tool, failed, queued];
  const kept = composerRows(rows);
  expect(kept.map((r) => r.id)).toEqual(["start", "p1", "s1", "q1"]);
  // What the composer asks of its rows reads the same from either.
  expect(kept.length === 0).toBe(rows.length === 0);
  expect(kept.some((r) => r.kind !== "sessionStart")).toBe(rows.some((r) => r.kind !== "sessionStart"));
  expect(queuePauseReason(kept)).toBe(queuePauseReason(rows));
  expect(kept.some((r) => r.queued !== undefined)).toBe(true);
  // A chat whose only rows are past its start keeps its first, so it reads as started.
  expect(composerRows([reply, tool]).map((r) => r.id)).toEqual(["a1"]);
  expect(composerRows([])).toEqual([]);
});

const snapshot = (rows: AcpmuxRow[], connection = "connected", commands = [{ name: "plan" }]): AcpmuxSnapshot =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    rows,
    connection,
    commands,
    queue: [],
    sessions: [],
  }) as unknown as AcpmuxSnapshot;

test("a tool call's snapshot is the same composer view; a new prompt is not", () => {
  const commands = [{ name: "plan" }];
  const before = composerView(snapshot([start, prompt, reply], "agent_message_chunk", commands));
  // A tool call: a new row, a new rows array, a new commands array with the same commands, and the
  // event's kind as the connection.
  const tool = composerView(snapshot([start, prompt, reply, row("t2", "tool")], "tool_call", [...commands]));
  expect(sameComposerView(before, tool)).toBe(true);
  const next = composerView(snapshot([start, prompt, reply, row("p2", "user", { text: "and test" })]));
  expect(sameComposerView(before, next)).toBe(false);
  // A lost link is still told apart.
  expect(sameComposerView(before, composerView(snapshot([start, prompt, reply], "disconnected", commands)))).toBe(
    false,
  );
});
