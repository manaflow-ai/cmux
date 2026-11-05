// l10n-allow-file: test fixture text, not shipped UI.
// The live line of a turn the agent started on its own (a background task's notice, a message
// that woke it) times that turn, never the prompt's turn that ended hours of such turns ago (Leo,
// 2026-10-29: "why the fuck are you still depicted as thinking for 11 hours?").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

const HOUR = 3_600_000;
const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const call = (id: string, at: number, status: string) =>
  row(id, "activity", at, {
    items: [{ kind: "tool", text: `Ran ${id}`, tool: { id, title: id, kind: "execute", status } }],
  });
const liveLine = (rows: AcpmuxRow[], now: number) =>
  turnView(rows, new Set(), { now, working: true }).find((entry) => entry.below);

test("a turn the agent started on its own after others it ended is timed from its own start", () => {
  const rows = [
    row("prompt", "user", 0, { text: "Watch the fleet" }),
    row("reply", "assistant", 1_000, { text: "Watching." }),
    row("summary", "turnSummary", 2_000, { status: "completed", durationMs: 2_000 }),
    call("first-check", 1 * HOUR, "completed"),
    row("first-end", "turnSummary", 1 * HOUR + 60_000, { status: "completed", durationMs: 60_000 }),
    call("second-check", 6 * HOUR, "completed"),
    row("second-end", "turnSummary", 6 * HOUR + 60_000, { status: "completed", durationMs: 60_000 }),
    call("now-check", 11 * HOUR, "in_progress"),
  ];
  expect(liveLine(rows, 11 * HOUR + 10_000)?.at).toBe(11 * HOUR);
});

test("the first turn the agent starts on its own is timed from its first row, not the prompt's end", () => {
  const rows = [
    row("prompt", "user", 0, { text: "Run the suite in the background" }),
    row("reply", "assistant", 1_000, { text: "Started it." }),
    row("summary", "turnSummary", 2_000, { status: "completed", durationMs: 2_000 }),
    call("check", 5 * HOUR, "in_progress"),
  ];
  expect(liveLine(rows, 5 * HOUR + 10_000)?.at).toBe(5 * HOUR);
});
