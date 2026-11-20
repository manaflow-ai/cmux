// l10n-allow-file: test fixture text, not shipped UI.
// A turn Claude Code ran on its own (a background task's notification woke it) ends with acpmux's
// `background_turn` ended record, never a `turn_result` (hub/background_turn.rs), so it had no
// summary to carry a footer: the chat's last reply drew no Copy, Fork, Read aloud or time row under
// it (Leo, 2026-11-04: "also i want to be able to copy/voice/fork/whatever at the very bottom... it
// feels like idk sometimes we're not counting your turns and enabling stuff"). Once it ends, its
// reply ends on a footer as a prompt's does; while it runs, or when it folds quiet, it draws none.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const tool = (id: string, extra: Partial<AcpmuxRow> = {}) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: "Ran tests", tool: { id, title: "bun test", kind: "execute", status: "completed" } }],
    ...extra,
  });

const transcript = (background: Partial<NonNullable<AcpmuxRow["background"]>>) => {
  at = 0;
  return [
    row("prompt", "user", { text: "Run the suite in the background and tell me when it is done" }),
    row("note", "assistant", { text: "Starting the suite." }),
    tool("start"),
    row("started", "assistant", { text: "The suite runs in the background; I'll report when it ends." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 4_000, seq: 40 }),
    row("task", "backgroundTask", {
      backgroundTask: { toolCallId: "start", command: "bun test", state: "completed" },
    }),
    row(backgroundTurnRowId("bg"), BACKGROUND_TURN, {
      seq: 41,
      background: {
        id: "bg",
        trigger: "task_notification",
        running: false,
        quiet: false,
        hasRows: true,
        ...background,
      },
    }),
    tool("read", { inBackground: "bg" }),
    row("woken", "assistant", { text: "The suite finished: 412 passed, 0 failed.", inBackground: "bg" }),
  ];
};

for (const agentFamily of ["claude", undefined])
  test(`${agentFamily ?? "default"}: the last reply of a turn the agent ran on its own ends on its footer`, () => {
    const view = turnView(transcript({}), new Set(), { now: 60_000, agentFamily });
    const footer = view.at(-1)!;
    expect(footer).toMatchObject({
      kind: "turnSummary",
      text: "The suite finished: 412 passed, 0 failed.",
      answerId: "woken",
    });
    // Its Copy copies that turn's own rows, and its Fork goes through the last turn acpmux ended.
    expect(footer.turnCopy?.length).toBeGreaterThan(0);
    expect(footer.seq).toBe(40);
    // The prompt's own footer stays where it was.
    expect(view.filter((entry) => entry.kind === "turnSummary").map((entry) => entry.text)).toEqual([
      "The suite runs in the background; I'll report when it ends.",
      "The suite finished: 412 passed, 0 failed.",
    ]);
  });

test("a background turn still running draws no footer yet", () => {
  const view = turnView(transcript({ running: true }), new Set(), { now: 60_000, agentFamily: "claude" });
  expect(view.filter((entry) => entry.kind === "turnSummary")).toHaveLength(1);
});

test("a quiet background turn folds to its line, with no footer", () => {
  const view = turnView(transcript({ quiet: true }), new Set(), { now: 60_000, agentFamily: "claude" });
  expect(view.filter((entry) => entry.kind === "turnSummary")).toHaveLength(1);
  expect(view.some((entry) => entry.id.startsWith("backgroundEnd"))).toBe(false);
});

test("a background turn a summary already ends gets no second footer", () => {
  const rows = [...transcript({}), row("woken-end", "turnSummary", { status: "completed", durationMs: 2_000 })];
  const view = turnView(rows, new Set(), { now: 60_000, agentFamily: "claude" });
  expect(view.filter((entry) => entry.kind === "turnSummary")).toHaveLength(2);
  expect(view.at(-1)).toMatchObject({ id: "woken-end", text: "The suite finished: 412 passed, 0 failed." });
});
