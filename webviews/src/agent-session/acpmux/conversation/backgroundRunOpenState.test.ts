// l10n-allow-file: test fixture replies, not shipped UI.
// A run of background-task lines the reader opened stays open when its rows regroup: a reply between
// two runs that turns out to draw nothing joins them into one, and the run keeps the reader's open
// whichever member's key it was opened under, as a message run does (Leo, 2026-11-08: "if i have a
// tool call expanded, the auto folding situation shouldn't collapse it when a new tool call comes in
// and the folds reformat").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { backgroundRunRowId, foldBackgroundRuns } from "./backgroundRuns";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

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
