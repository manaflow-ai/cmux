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
  // Between two prompts: the 16px turn gap has a 24px floor for the existing hover controls.
  expect(layoutConversation([prompt("p"), footer({ durationMs: 0 }), prompt("q")], 720).heights[1]).toBe(24);
  // The chat's last one keeps that same turn gap before the composer.
  expect(layoutConversation([prompt("p"), footer({ durationMs: 0 })], 720).heights[1]).toBe(24);
  // A footer with an answer to copy keeps its line.
  expect(layoutConversation([prompt("p"), footer({ durationMs: 0, text: "Done." }), prompt("q")], 720).heights[1]).toBe(
    40,
  );
});
