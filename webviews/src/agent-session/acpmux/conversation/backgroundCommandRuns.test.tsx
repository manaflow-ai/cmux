// l10n-allow-file: test fixture commands, not shipped UI.
// A run of background shells' ends folds into one line in the default look, where a background
// turn's calls draw inline (backgroundRuns.ts, backgroundTurnLook.experiment.ts). Leo, 2026-11-12,
// on a coordinator chat with about 40 subagents that drew dozens of "Background command completed"
// rows in a row: "Holy crap, there are way too many [waits] here... this looks like a degenerate
// [state], bro."
import { afterAll, beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { backgroundRunFoldFor, backgroundRunRowId, foldBackgroundRuns } from "./backgroundRuns";
import { BACKGROUND_TURN } from "./backgroundTurns";
import { turnView } from "./turns";

// The default look: background turns draw inline, with no line of their own.
beforeAll(() => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
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
const end = (id: string, state: "completed" | "failed" | "stopped" = "completed", owner = "helper") =>
  row(id, "backgroundTask", {
    backgroundTask: { toolCallId: id, command: `glaeda-gh wait file /tmp/${id}.out`, state, ownerTitle: owner },
  });
const ends = (n: number, prefix = "bg") => Array.from({ length: n }, (_, i) => end(`${prefix}-${i}`));
const ids = (rows: AcpmuxRow[]) => rows.filter((entry) => entry.kind !== "date").map((entry) => entry.id);
const label = (drawn: AcpmuxRow) =>
  renderToStaticMarkup(<BackgroundTurnLine row={drawn} expanded={false} onToggle={() => {}} />);
const prompt = () => {
  at = 0;
  return [
    row("prompt", "user", { text: "Land the four PRs" }),
    row("reply", "assistant", { text: "Started the helpers." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
  ];
};
const asView = (rows: AcpmuxRow[], expanded: Set<string>) => turnView(rows, expanded, { agentFamily: "claude" });

test("23 background command ends from many subagents fold into one closed line", () => {
  const owned = ends(23).map((entry, i) => ({
    ...entry,
    backgroundTask: { ...entry.backgroundTask!, ownerTitle: `helper ${i % 7}` },
  }));
  const rows = [...prompt(), ...owned];
  const view = asView(rows, new Set());
  const run = backgroundRunRowId("bg-0");
  expect(ids(view)).toEqual(["prompt", "reply", "summary", run]);
  const drawn = view.at(-1)!;
  expect(drawn.kind).toBe(BACKGROUND_TURN);
  expect(drawn.backgroundRun).toMatchObject({ finished: 23, failed: 0, commands: 23 });
  expect(drawn.backgroundRun!.rows).toHaveLength(23);
  const html = label(drawn);
  expect(html).toContain("23 background commands completed");
  expect(html).toContain('aria-expanded="false"');
  // Opened: the line, then every end in order.
  const open = asView(rows, new Set([run]));
  expect(ids(open).slice(3)).toEqual([run, ...Array.from({ length: 23 }, (_, i) => `bg-${i}`)]);
  // Find or a link to one end opens the line.
  expect(backgroundRunFoldFor(view, "bg-11")).toBe(run);
});

test("a stopped end counts as ended; failed ends are counted on the line", () => {
  const rows = [...prompt(), end("a"), end("b", "stopped"), end("c", "failed"), end("d"), end("e", "failed")];
  const drawn = asView(rows, new Set()).at(-1)!;
  expect(drawn.backgroundRun).toMatchObject({ finished: 2, stopped: 1, failed: 2, commands: 5 });
  const html = label(drawn);
  expect(html).toContain("3 background commands finished, 2 failed");
  expect(html).toContain("cv-background-turn--failed");
});

test("completed commands keep the completed summary when another command fails", () => {
  const drawn = asView([...prompt(), end("a"), end("b"), end("c", "failed")], new Set()).at(-1)!;
  expect(label(drawn)).toContain("2 background commands completed, 1 failed");
});

test("a run of failed ends only says they failed", () => {
  const drawn = asView([...prompt(), end("a", "failed"), end("b", "failed")], new Set()).at(-1)!;
  expect(label(drawn)).toContain("2 background commands failed");
});

test("one end alone stays its own row, and a row the person needs splits the run", () => {
  expect(ids(asView([...prompt(), end("solo")], new Set())).slice(3)).toEqual(["solo"]);
  const rows = [...ends(3, "x"), row("said", "assistant", { text: "PR 41443 is green." }), ...ends(2, "y")];
  const folded = foldBackgroundRuns(rows, new Set());
  expect(folded.map((entry) => entry.id)).toEqual([backgroundRunRowId("x-0"), "said", backgroundRunRowId("y-0")]);
  expect(folded[0]!.backgroundRun).toMatchObject({ finished: 3, commands: 3 });
  expect(folded[2]!.backgroundRun).toMatchObject({ finished: 2, commands: 2 });
});

test("bare replies between ends go with the run; rows with nothing to fold come back as they were", () => {
  const rows = [end("a"), row("dot", "assistant", { text: "." }), end("b")];
  expect(foldBackgroundRuns(rows, new Set()).map((entry) => entry.id)).toEqual([backgroundRunRowId("a")]);
  const plain = [row("p", "user", { text: "hi" }), end("only")];
  expect(foldBackgroundRuns(plain, new Set())).toBe(plain);
});

test("the default look still folds no background turn lines, only shell ends", () => {
  const line = (id: string) =>
    row(`bgturn-${id}`, BACKGROUND_TURN, {
      background: { id, trigger: "task_notification", running: false, quiet: true, hasRows: true },
    });
  const rows = [line("a"), line("b")];
  expect(foldBackgroundRuns(rows, new Set())).toBe(rows);
});
