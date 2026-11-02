// l10n-allow-file: test fixture replies, not shipped UI.
// The line of a turn the agent ran on its own (backgroundTurns.ts, BackgroundTurnLine.tsx): quiet,
// it is one closed line the reader can open; running, the same line with the working spinner; one
// with something to say draws no line. direct.ts tags the rows (test/agent-pane-background-turns.test.ts).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { BACKGROUND_TURN, backgroundTurnRowId, foldBackgroundTurns } from "./backgroundTurns";
import { turnView } from "./turns";

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
    background: { id, trigger: "task_notification", running: false, ...background },
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

test("a quiet background turn is one closed line that opens to its rows", () => {
  const rows = transcript({ quiet: true });
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", "reply", "summary", backgroundTurnRowId("bg")]);
  expect(ids(turnView(rows, new Set([backgroundTurnRowId("bg")])))).toEqual([
    "prompt",
    "reply",
    "summary",
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
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", "reply", "summary", "check", "note"]);
});

test("a running background turn is the compact line with the working spinner", () => {
  const rows = transcript({ running: true });
  const view = turnView(rows, new Set());
  expect(ids(view).at(-1)).toBe(backgroundTurnRowId("bg"));
  expect(view.some((entry) => entry.id === "note")).toBe(false);
  const running = line("bg", { running: true, trigger: "scheduled" });
  const html = renderToStaticMarkup(<BackgroundTurnLine row={running} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("cv-spinner");
  expect(html).toContain("Scheduled check");
});

test("rows with no background turn come back as they were", () => {
  at = 0;
  const rows = [row("prompt", "user", { text: "hi" }), row("reply", "assistant", { text: "hello" })];
  expect(foldBackgroundTurns(rows, new Set())).toBe(rows);
});
