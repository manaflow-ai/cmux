// l10n-allow-file: the header copy is read from the pane's string table.
// The running turn's "Working for 5s ›" keeps its chevron right after its words (#55615,
// https://github.com/manaflow-ai/cmux/issues/55615): the ticking time held an unseen "00m 00s" box
// from its first second, so the chevron sat a few digits' width past "5s", wider at a larger text
// size. The words and chevron now hug, and the widest time's room sits after the chevron in an
// unseen copy, so the toggle's width still holds while the seconds tick. Real layout:
// test/turn-header-steady-browser.test.ts.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { WorkingFor } from "./WorkingFor";

const header: AcpmuxRow = {
  id: "worked-u",
  kind: "worked",
  version: 1,
  at: 0,
  turnPhase: "running",
};

function draw(elapsed: number, onToggle?: () => void) {
  const html = renderToStaticMarkup(<WorkingFor row={header} now={() => elapsed} onToggle={onToggle} />);
  return new JSDOM(`<main>${html}</main>`).window.document;
}

for (const [elapsed, shown, widest] of [
  [5_000, "5s", "00m 00s"],
  [59_000, "59s", "00m 00s"],
  [76_000, "1m 16s", "00m 00s"],
  [3_725_000, "1h 2m 5s", "00h 00m 00s"],
] as const)
  test(`the toggle at ${shown}: its chevron follows the words, the widest time's room after it`, () => {
    const doc = draw(elapsed, () => {});
    const hug = doc.querySelector(".cv-worked__toggle > .cv-worked__hug")!;
    expect(hug.textContent).toBe(translate("turn.working", { time: shown }));
    // Nothing between the words and the chevron holds room: no clock box in the visible label.
    expect(hug.querySelector("[data-clock-size]")).toBeNull();
    const chevron = hug.lastElementChild!;
    expect(chevron.getAttribute("class")).toContain("cv-worked__chevron");
    expect(chevron.getAttribute("class")).not.toContain("is-reserved");
    expect(chevron.previousElementSibling?.classList.contains("cv-worked__label")).toBe(true);
    // The unseen copy at the widest time shares the toggle, its chevron the held slot.
    const sizer = doc.querySelector(".cv-worked__toggle > .cv-worked__toggle-sizer")!;
    expect(sizer.getAttribute("aria-hidden")).toBe("true");
    expect(sizer.textContent).toBe(translate("turn.working", { time: widest }));
    expect(doc.querySelectorAll(".cv-worked__chevron.is-reserved")).toHaveLength(1);
    expect(sizer.querySelector(".cv-worked__chevron.is-reserved")).not.toBeNull();
  });

test("a header that does not toggle keeps its time box and its chevron's slot unseen at the end", () => {
  const doc = draw(5_000);
  expect(doc.querySelector(".cv-worked__toggle")).toBeNull();
  expect(doc.querySelector(".cv-worked__label-time")?.getAttribute("data-clock-size")).toBe("00m 00s");
  expect(doc.querySelectorAll(".cv-worked__chevron")).toHaveLength(1);
  expect(doc.querySelector(".cv-worked")!.lastElementChild!.getAttribute("class")).toContain("is-reserved");
});
