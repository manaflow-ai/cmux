// l10n-allow-file: test fixture replies, not shipped UI.
// A run of background-task lines the reader opened stays open when its rows regroup: a reply between
// two runs that turns out to draw nothing joins them into one, and the run keeps the reader's open
// whichever member's key it was opened under, as a message run does (Leo, 2026-11-08: "if i have a
// tool call expanded, the auto folding situation shouldn't collapse it when a new tool call comes in
// and the folds reformat").
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { backgroundRunRowId, foldBackgroundRuns } from "./backgroundRuns";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

// These pin the line look (backgroundTurnLook.experiment.ts `line`): the default draws no run line
// (backgroundTurnInline.test.ts).
beforeAll(() => {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "background-turn-look": "line" };
});
afterAll(() => {
  delete globalThis.cmuxExperiments;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const line = (id: string) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "task_notification", running: false, quiet: true, hasRows: true },
  });

test("a background run the reader opened stays open when a reply that draws nothing joins it to the run before", () => {
  at = 0;
  const before = [line("a"), line("b"), row("reply", "assistant", { text: "Still going." }), line("c"), line("d")];
  const runs = foldBackgroundRuns(before, new Set()).filter((entry) => entry.backgroundRun);
  expect(runs).toHaveLength(2);
  const opened = new Set([runs[1]!.id]);
  expect(opened.has(backgroundRunRowId(backgroundTurnRowId("c")))).toBe(true);
  // The reply comes back as a lone period, which draws nothing: the two runs are one now.
  const after = before.map((entry) => (entry.id === "reply" ? { ...entry, text: ".", version: 2 } : entry));
  const joined = foldBackgroundRuns(after, opened).filter((entry) => entry.backgroundRun);
  expect(joined).toHaveLength(1);
  expect(joined[0]!.foldOpen).toBe(true);
  // Its id is the key it was opened under, so a click closes it by that same key.
  expect(joined[0]!.id).toBe(runs[1]!.id);
});

test("two background runs the reader opened, joined into one, close with one click", async () => {
  // turns.ts `foldCovers` and `toggleTurnFold` with it, as the transcript's click passes them.
  const { foldCovers, toggleTurnFold } = await import("./turns");
  at = 0;
  const before = [line("a"), line("b"), row("reply", "assistant", { text: "Still going." }), line("c"), line("d")];
  const runs = foldBackgroundRuns(before, new Set()).filter((entry) => entry.backgroundRun);
  // The reader opened both runs.
  const opened = new Set(runs.map((entry) => entry.id));
  const after = before.map((entry) => (entry.id === "reply" ? { ...entry, text: ".", version: 2 } : entry));
  const joined = foldBackgroundRuns(after, opened).find((entry) => entry.backgroundRun)!;
  expect(joined.foldOpen).toBe(true);
  // One click on the joined line closes it: no member's key holds it open.
  const closed = toggleTurnFold(after, opened, joined.id, foldCovers(joined));
  expect(foldBackgroundRuns(after, closed).find((entry) => entry.backgroundRun)!.foldOpen).toBe(false);
  // And the next click opens it again.
  const reopened = toggleTurnFold(after, closed, joined.id, foldCovers(joined));
  expect(foldBackgroundRuns(after, reopened).find((entry) => entry.backgroundRun)!.foldOpen).toBe(true);
});

test("a message run's line covers every member's key, so a joined run closes with one click", async () => {
  const { foldCovers, toggleTurnFold } = await import("./turns");
  const { messageRunRowId } = await import("./messageRuns");
  const lineRow: AcpmuxRow = {
    id: messageRunRowId("m1"),
    kind: "messageRun",
    version: 1,
    at: 1,
    foldOpen: true,
    messageRun: { sent: 2, received: 0, work: [], failed: 0, running: false, rows: ["m1", "m2", "m3"] },
  };
  const opened = new Set([messageRunRowId("m1"), messageRunRowId("m3")]);
  expect(foldCovers(lineRow)).toEqual(["m1", "m2", "m3"].map(messageRunRowId));
  expect([...toggleTurnFold([], opened, lineRow.id, foldCovers(lineRow))]).toEqual([]);
});
