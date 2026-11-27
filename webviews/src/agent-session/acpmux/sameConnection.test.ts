import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { sameConnection } from "./model";
import { sameButRows } from "./liveToolOutput";

test("two events' names draw the same connection", () => {
  expect(sameConnection("tool_call", "claude.system.task_progress")).toBe(true);
  expect(sameConnection("response", "response")).toBe(true);
});

test("a change of link or a failure is never the same connection", () => {
  for (const changed of [
    "disconnected",
    "connecting",
    "connecting: retry 2",
    "failed",
    "failed: boom",
    "error: x",
    "fork failed",
    "debug",
  ])
    expect(sameConnection("tool_call", changed)).toBe(false);
  expect(sameConnection("failed: a", "failed: b")).toBe(false);
});

test("a snapshot that only names another event is the same but its rows", () => {
  const rows: AcpmuxSnapshot["rows"] = [];
  const drawn = { rows, connection: "tool_call", isWorking: true } as unknown as AcpmuxSnapshot;
  expect(sameButRows(drawn, { ...drawn, connection: "plan" })).toBe(true);
  expect(sameButRows(drawn, { ...drawn, connection: "disconnected" })).toBe(false);
  expect(sameButRows(drawn, { ...drawn, connection: "plan", isWorking: false })).toBe(false);
});
