// A snapshot that only names another live record's kind in `connection` draws nothing new
// (drawsNothingNew.ts); a link state, a changed row or any other field still draws. On the recorded
// lane session most such snapshots are task notes, process updates and progress records.
// Leo (rulebook): "Root-fix anything slow, stalling, uncached, growing ... Before/after, one harness".
import { expect, test } from "bun:test";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { drawsNothingNew } from "./drawsNothingNew";

const rows: AcpmuxRow[] = [{ id: "a", kind: "assistant", version: 1, at: 1, text: "hi" }];
const base = { connection: "agent_thought_chunk", rows, summary: { sessionId: "s" } } as unknown as AcpmuxSnapshot;
const with_ = (patch: Record<string, unknown>) => ({ ...base, ...patch }) as unknown as AcpmuxSnapshot;

test("another record kind with the same rows and fields draws nothing new", () => {
  for (const kind of ["claude.system.task_progress", "process_update", "subagent_progress", "status", "plan"])
    expect(drawsNothingNew(base, with_({ connection: kind }))).toBe(true);
  expect(drawsNothingNew(base, with_({}))).toBe(true);
});

test("a link state, a row or any other field draws", () => {
  for (const reason of [
    "connected",
    "attached",
    "failed",
    "disconnected",
    "session changed",
    "debug",
    "connecting: daemon",
    "error",
  ])
    expect(drawsNothingNew(base, with_({ connection: reason }))).toBe(false);
  expect(drawsNothingNew(with_({ connection: "failed" }), base)).toBe(false);
  expect(drawsNothingNew(base, with_({ rows: [...rows] }))).toBe(false);
  expect(drawsNothingNew(base, with_({ summary: { sessionId: "s" } }))).toBe(false);
  expect(drawsNothingNew(base, with_({ isWorking: true }))).toBe(false);
  const { summary: _, ...less } = base as unknown as Record<string, unknown>;
  expect(drawsNothingNew(base, { ...less, isWorking: true } as unknown as AcpmuxSnapshot)).toBe(false);
});
