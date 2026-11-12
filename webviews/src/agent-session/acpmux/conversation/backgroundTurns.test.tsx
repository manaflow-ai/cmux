// l10n-allow-file: test fixture replies, not shipped UI.
// The line of a turn the agent ran on its own (backgroundTurns.ts, BackgroundTurnLine.tsx): quiet,
// it is one closed line the reader can open; running, the same line with the working spinner and its words shimmering; one
// with something to say draws no line. direct.ts tags the rows (test/agent-pane-background-turns.test.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { BACKGROUND_TURN, backgroundTurnRowId, foldBackgroundTurns } from "./backgroundTurns";
import { turnView, WORKED } from "./turns";

// These pin the line look (backgroundTurnLook.experiment.ts `line`): the default draws a background
// turn's calls inline, with no line (backgroundTurnInline.test.ts).
const experiments = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "background-turn-look": "line" };
});
afterAll(() => {
  globalThis.cmuxExperiments = experiments;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const line = (id: string, background: Partial<NonNullable<AcpmuxRow["background"]>>) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "task_notification", running: false, hasRows: true, ...background },
  });

const transcript = (background: Partial<NonNullable<AcpmuxRow["background"]>>) => {
  at = 0;
  return [
    row("prompt", "user", { text: "Run the suite in the background" }),
    row("reply", "assistant", { text: "Started it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
    line("bg", background),
    row("check", "activity", {
      inBackground: "bg",
      items: [
        {
          kind: "tool",
          text: "Ran check",
          tool: { id: "check", title: "check", kind: "execute", status: "completed" },
        },
      ],
    }),
    row("note", "assistant", { text: "Nothing new for you yet.", inBackground: "bg" }),
  ];
};
const ids = (rows: AcpmuxRow[]) => rows.filter((entry) => entry.kind !== "date").map((entry) => entry.id);

// Once its turn ended, a background turn is the agent's work after that turn: it folds in place under
// the tail's own "Worked for" (turns.ts `foldTail`; Leo, 2026-11-11: "Do those not count as the works
// for?"). Opened, that fold draws the line as before.
const TAIL = (first: string) => `${WORKED}-prompt~tail-${first}`;

test("a quiet background turn is one closed line that opens to its rows", () => {
  const rows = transcript({ quiet: true });
  const fold = TAIL(backgroundTurnRowId("bg"));
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", "reply", "summary", fold]);
  // The tail's fold opened: the line, closed, in its place.
  expect(ids(turnView(rows, new Set([fold])))).toEqual(["prompt", "reply", "summary", fold, backgroundTurnRowId("bg")]);
  // The line opened too: its rows follow it, in order.
  expect(ids(turnView(rows, new Set([fold, backgroundTurnRowId("bg")])))).toEqual([
    "prompt",
    "reply",
    "summary",
    fold,
    backgroundTurnRowId("bg"),
    "check",
    "note",
  ]);
  const html = renderToStaticMarkup(<BackgroundTurnLine row={rows[3]!} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("Background task finished");
  expect(html).toContain('aria-expanded="false"');
  expect(html).not.toContain("cv-spinner");
});

test("a background turn that is not quiet draws its rows as they came, with no line", () => {
  const rows = transcript({ quiet: false });
  // Its call folds in place; its reply stays in sight and ends on its own footer
  // (backgroundTurnFooter.test.ts).
  const fold = TAIL("check");
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", "reply", "summary", fold, "note", "backgroundEnd-bg"]);
  const open = turnView(rows, new Set([fold]));
  expect(ids(open)).toEqual(["prompt", "reply", "summary", fold, "check", "note", "backgroundEnd-bg"]);
  expect(open.some((entry) => entry.kind === BACKGROUND_TURN)).toBe(false);
});

test("a running background turn is the compact line with the working spinner", () => {
  const rows = transcript({ running: true });
  // While it runs the chat works, and the tail draws as it comes: the line in sight, the last row.
  const view = turnView(rows, new Set(), { working: true });
  expect(ids(view).at(-1)).toBe(backgroundTurnRowId("bg"));
  expect(view.some((entry) => entry.id === "note")).toBe(false);
  const running = line("bg", { running: true, trigger: "scheduled" });
  const html = renderToStaticMarkup(<BackgroundTurnLine row={running} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("cv-spinner");
  expect(html).toContain("Scheduled check");
  // Its words shimmer as a running tool row's do (Leo, 2026-11-09: "isn't highlighted all the way
  // through like other tool calls are"): the lit copy of the whole label, on a live line.
  expect(html).toContain("is-live");
  expect(html).toMatch(/class="cv-row-shimmer"[^>]*>.*Scheduled check/);
  const ended = line("bg", { running: false, quiet: true, trigger: "scheduled" });
  expect(renderToStaticMarkup(<BackgroundTurnLine row={ended} expanded={false} onToggle={() => {}} />)).not.toContain(
    "cv-row-shimmer",
  );
});

test("rows with no background turn come back as they were", () => {
  at = 0;
  const rows = [row("prompt", "user", { text: "hi" }), row("reply", "assistant", { text: "hello" })];
  expect(foldBackgroundTurns(rows, new Set())).toBe(rows);
});
