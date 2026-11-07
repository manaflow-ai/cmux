// l10n-allow-file: test fixture replies, not shipped UI.
// A run of background-task notifications folds into one line (backgroundRuns.ts), and a reply of
// only punctuation draws no row (visibleMessage.ts). Leo, 2026-11-02, on a column of "Background
// task finished" rows with a lone "·" reply under each: "why do you still do these".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { backgroundRunRowId, foldBackgroundRuns } from "./backgroundRuns";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { messageRunRowId } from "./messageRuns";
import { hiddenRowFolds, messageRevealTarget, turnView } from "./turns";
import { isBareAgentText, isVisiblyEmptyMessage } from "./visibleMessage";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const line = (id: string, background: Partial<NonNullable<AcpmuxRow["background"]>> = {}) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "task_notification", running: false, quiet: true, hasRows: true, ...background },
  });
const note = (id: string, state: "completed" | "failed" | "stopped") =>
  row(id, "backgroundTask", { backgroundTask: { toolCallId: id, command: "cargo test", state } });
const dot = (id: string, extra: Partial<AcpmuxRow> = {}) => row(id, "assistant", { text: ".", ...extra });
const ids = (rows: AcpmuxRow[]) => rows.filter((entry) => entry.kind !== "date").map((entry) => entry.id);
const prompt = () => {
  at = 0;
  return [
    row("prompt", "user", { text: "Run the suites in the background" }),
    row("reply", "assistant", { text: "Started them." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
  ];
};

// Only a lone period: other punctuation is rare and may mean something (Leo, 2026-11-03: "well
// there are cases (rare) that you would want to see it"). Background turns that say nothing worth
// a row are weighed by acpmux instead (backgroundTurns.ts).
test("a lone period reply draws no row; a person's does", () => {
  for (const text of [".", " . ", ""]) expect(isBareAgentText(text)).toBe(true);
  for (const text of ["·", "…", "...", "ok", "1", ". done", "👍"]) expect(isBareAgentText(text)).toBe(false);
  expect(isVisiblyEmptyMessage(dot("a"))).toBe(true);
  expect(isVisiblyEmptyMessage(row("q", "user", { text: "?" }))).toBe(false);
  expect(isVisiblyEmptyMessage(row("r", "assistant", { text: "Done." }))).toBe(false);
});

test("four quiet background task lines with lone replies fold into one closed line", () => {
  const rows = [
    ...prompt(),
    line("a"),
    dot("a-dot"),
    line("b"),
    dot("b-dot"),
    line("c"),
    dot("c-dot"),
    line("d"),
    dot("d-dot"),
  ];
  const view = turnView(rows, new Set());
  const run = backgroundRunRowId(backgroundTurnRowId("a"));
  expect(ids(view)).toEqual(["prompt", "reply", "summary", run]);
  const drawnRun = view.at(-1)!;
  expect(drawnRun.kind).toBe(BACKGROUND_TURN);
  expect(drawnRun.backgroundRun).toMatchObject({ finished: 4, stopped: 0 });
  const html = renderToStaticMarkup(<BackgroundTurnLine row={drawnRun} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("4 background tasks finished");
  expect(html).toContain('aria-expanded="false"');
  // Opened: each line again, in order; the lone replies still draw nothing.
  const open = turnView(rows, new Set([run]));
  expect(ids(open).slice(3)).toEqual([
    run,
    backgroundTurnRowId("a"),
    backgroundTurnRowId("b"),
    backgroundTurnRowId("c"),
    backgroundTurnRowId("d"),
  ]);
});

test("a finished and a stopped shell fold with the lines, as background updates", () => {
  const rows = [...prompt(), line("a"), note("stop", "stopped"), line("b")];
  const view = turnView(rows, new Set());
  const run = view.at(-1)!;
  expect(run.backgroundRun).toMatchObject({ finished: 2, stopped: 1 });
  const html = renderToStaticMarkup(<BackgroundTurnLine row={run} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("3 background updates");
});

test("a notification followed by a real reply keeps that reply in sight", () => {
  const rows = [
    ...prompt(),
    line("a"),
    line("loud", { quiet: false }),
    row("said", "assistant", { text: "The suite failed: 2 tests.", inBackground: "loud" }),
    line("b"),
  ];
  const view = turnView(rows, new Set());
  expect(ids(view).slice(3)).toEqual([
    backgroundTurnRowId("a"),
    "said",
    "backgroundEnd-loud",
    backgroundTurnRowId("b"),
  ]);
});

test("a failed shell and a running line end a run; one line alone stays as it was", () => {
  const rows = [...prompt(), line("a"), note("fail", "failed"), line("b"), line("live", { running: true })];
  const view = turnView(rows, new Set());
  expect(view.some((entry) => entry.backgroundRun)).toBe(false);
  expect(ids(view).slice(3)).toEqual([
    backgroundTurnRowId("a"),
    "fail",
    backgroundTurnRowId("b"),
    backgroundTurnRowId("live"),
  ]);
});

test("a member line opened on its own keeps its rows inside the run", () => {
  const rows = [
    ...prompt(),
    line("a"),
    row("a-work", "activity", { inBackground: "a", items: [] }),
    dot("a-dot", { inBackground: "a" }),
    line("b"),
  ];
  const run = backgroundRunRowId(backgroundTurnRowId("a"));
  // The member opened while its run is closed: still one line.
  expect(ids(turnView(rows, new Set([backgroundTurnRowId("a")]))).slice(3)).toEqual([run]);
  // Both open: the member's rows under it, then the next member.
  expect(ids(turnView(rows, new Set([run, backgroundTurnRowId("a")]))).slice(3)).toEqual([
    run,
    backgroundTurnRowId("a"),
    "a-work",
    backgroundTurnRowId("b"),
  ]);
});

test("Find opens the run, then the member line, for a row behind both", () => {
  const rows = [...prompt(), line("a"), row("a-work", "activity", { inBackground: "a", items: [] }), line("b")];
  const drawn = turnView(rows, new Set());
  const run = backgroundRunRowId(backgroundTurnRowId("a"));
  // Then a message run that may fold the row inside the member's rows (messageRuns.ts).
  expect(hiddenRowFolds(rows, drawn, 4)).toEqual([run, backgroundTurnRowId("a"), messageRunRowId("a-work")]);
  expect(messageRevealTarget(rows, drawn, ["a-work"])).toEqual({
    rowId: "a-work",
    fold: run,
    run: backgroundTurnRowId("a"),
    also: [messageRunRowId("a-work")],
  });
  expect(hiddenRowFolds(rows, drawn, 5)).toEqual([run]);
});

test("rows without a run come back as they were, and the run line keeps its object", () => {
  const plain = [...prompt(), line("a")];
  expect(foldBackgroundRuns(plain, new Set())).toBe(plain);
  const rows = [...prompt(), line("a"), line("b")];
  const first = foldBackgroundRuns(rows, new Set()).at(-1)!;
  const again = foldBackgroundRuns(rows, new Set()).at(-1)!;
  expect(again.version).toBe(first.version);
  expect(foldBackgroundRuns(rows, new Set([first.id])).find((entry) => entry.id === first.id)!.version).not.toBe(
    first.version,
  );
});

test("closing a run hides its last member's opened rows with it", () => {
  const rows = [...prompt(), line("a"), line("b"), row("b-work", "activity", { inBackground: "b", items: [] })];
  const run = backgroundRunRowId(backgroundTurnRowId("a"));
  expect(ids(turnView(rows, new Set([backgroundTurnRowId("b")]))).slice(3)).toEqual([run]);
  expect(ids(turnView(rows, new Set([run, backgroundTurnRowId("b")]))).slice(3)).toEqual([
    run,
    backgroundTurnRowId("a"),
    backgroundTurnRowId("b"),
    "b-work",
  ]);
});
