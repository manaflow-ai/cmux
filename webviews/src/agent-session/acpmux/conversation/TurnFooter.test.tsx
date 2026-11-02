// l10n-allow-file: test fixture replies, not shipped UI.
// A turn's footer under its answer (TurnRows.tsx TurnFooter). Leo, 2026-10-21, on a footer reading
// "Worked for 0s · pin · now" that took a full line: "IF WE 0 SECONDS THEN IT DOESNT NEED TO TAKE
// UP SPACE". A turn under a second says no "Worked for", and a footer left with only its hover
// controls (Pin, Fork, its age) takes no line: the row is its turn gap alone.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { layoutConversation } from "../model";
import { translate, type Translate } from "../i18n";
import { gridLength, TRANSCRIPT_BLOCK_GAP, TRANSCRIPT_TURN_GAP } from "../transcriptGrid";
import { footerLabel, isEmptyFooter } from "./turns";
import { TurnFooter } from "./TurnRows";

const t: Translate = (key, values) => translate(key, values, "en");

const footer = (fields: Partial<AcpmuxRow>): AcpmuxRow => ({
  id: "summary",
  version: 1,
  at: 1_000,
  kind: "turnSummary",
  status: "completed",
  ...fields,
});

test("a turn under a second says no Worked for", () => {
  for (const durationMs of [0, 1, 999]) {
    const row = footer({ durationMs });
    expect(footerLabel(t, row)).toBeUndefined();
    expect(renderToStaticMarkup(<TurnFooter row={row} />)).not.toContain("Worked for");
  }
});

test("a 5 s turn still says Worked for 5s", () => {
  const row = footer({ durationMs: 5_000 });
  expect(footerLabel(t, row)).toBe("Worked for 5s");
  expect(renderToStaticMarkup(<TurnFooter row={row} />)).toContain("Worked for 5s");
});

// Leo, 2026-11-02, on "Worked for" drawn in front of Copy: "this should not be placed in front of
// the copy/whatever buttons. those buttons should always just be there left aligned".
test("the buttons lead the footer row; Worked for comes after them", () => {
  const markup = renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 5_000, text: "Done." })} />);
  const group = markup.indexOf("cv-turn-action-group");
  expect(group).toBeGreaterThan(-1);
  expect(markup.indexOf("Copy")).toBeGreaterThan(group);
  expect(markup.indexOf("cv-turn-summary")).toBeGreaterThan(markup.indexOf("Copy"));
});

test("a turn stopped within a second still says it stopped", () => {
  expect(footerLabel(t, footer({ durationMs: 400, status: "cancelled" }))).toBe("You stopped after 0s");
});

test("a turn whose work folds under Worked for says nothing in its footer", () => {
  expect(footerLabel(t, footer({ durationMs: 5_000, folded: true }))).toBeUndefined();
});

test("a footer with only hover controls is empty; one with an answer, a label or a failure is not", () => {
  expect(isEmptyFooter(footer({ durationMs: 0 }))).toBe(true);
  expect(isEmptyFooter(footer({ durationMs: 5_000, folded: true }))).toBe(true);
  expect(isEmptyFooter(footer({ durationMs: 0, text: "Done." }))).toBe(false);
  expect(isEmptyFooter(footer({ durationMs: 5_000 }))).toBe(false);
  expect(isEmptyFooter(footer({ durationMs: 0, status: "failed", error: "boom" }))).toBe(false);
  expect(renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 0 })} />)).toContain("cv-turn-actions--empty");
  expect(renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 0, text: "Done." })} />)).not.toContain(
    "cv-turn-actions--empty",
  );
});

const prompt = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "user", text: "Next" });

test("an empty footer adds no line and still fits its hover controls", () => {
  // On the grid (#27580) a settled footer has no height of its own: design/grid.md 5.5, a message's
  // "hover action row ... takes no layout height: it is laid in the gap under its message", and the gap
  // is the stack's (transcriptGrid.ts). "Every gap that can follow a message is at least 24", so its
  // 16px glyphs keep 4px above and at least 4px below.
  const fits = (gap: number) => expect(gap).toBeGreaterThanOrEqual(gridLength("transcript-icon-box") + 8);
  // Between two prompts: no line, and the turn gap between them holds the hover controls.
  const between = layoutConversation([prompt("p"), footer({ durationMs: 0 }), prompt("q")], 720);
  expect(between.heights[1]).toBe(0);
  expect(between.gaps?.[2]).toBe(TRANSCRIPT_TURN_GAP);
  fits(between.gaps?.[2] ?? 0);
  // The chat's last one: no line, and the tail gap before the composer is the block gap.
  const last = layoutConversation([prompt("p"), footer({ durationMs: 0 })], 720);
  expect(last.heights[1]).toBe(0);
  expect(last.tailGap).toBe(TRANSCRIPT_BLOCK_GAP);
  fits(last.tailGap ?? 0);
  // A footer with an answer to copy is laid in the gap the same way: it moves nothing either.
  const answered = layoutConversation([prompt("p"), footer({ durationMs: 0, text: "Done." }), prompt("q")], 720);
  expect(answered.heights[1]).toBe(0);
  expect(answered.gaps?.[2]).toBe(TRANSCRIPT_TURN_GAP);
});
