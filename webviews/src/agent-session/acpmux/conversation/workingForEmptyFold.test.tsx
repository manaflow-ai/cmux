// l10n-allow-file: test fixtures.
// The running turn's "Working for" shows its chevron only once its fold holds work to open. Before
// the first step, or while the only step is the call in flight (the live line names it), the
// chevron's slot stays unseen and the label opens nothing, so the first finished call moves nothing.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { WORKED, turnView } from "./turns";
import { WorkingFor } from "./WorkingFor";

const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "Fix it" };
const call = (id: string, status: "completed" | "in_progress") => ({
  kind: "tool",
  text: "Run",
  tool: { id, title: "Run", kind: "execute", status },
});
const work = (id: string, at: number, ...items: ReturnType<typeof call>[]) =>
  ({ id, version: 1, at, kind: "activity", items }) as AcpmuxRow;

const header = (rows: AcpmuxRow[]) =>
  turnView([prompt, ...rows], new Set(), { now: 20_000, agentFamily: "codex", working: true }).find(
    (row) => row.kind === WORKED && row.turnPhase === "running",
  )!;

test("no step yet: the header's fold is empty", () => {
  expect(header([]).foldEmpty).toBe(true);
});

test("the only step is the call in flight: the header's fold is empty", () => {
  expect(header([work("w1", 1_000, call("c1", "in_progress"))]).foldEmpty).toBe(true);
});

test("a finished call: the header's fold has work to open", () => {
  const row = header([work("w1", 1_000, call("c1", "completed"), call("c2", "in_progress"))]);
  expect(row.foldOpen).toBe(false);
  expect(row.foldEmpty).toBeUndefined();
});

const draw = (row: AcpmuxRow) =>
  new JSDOM(`<main>${renderToStaticMarkup(<WorkingFor row={row} now={() => 5_000} onToggle={() => {}} />)}</main>`)
    .window.document;
const running: AcpmuxRow = { id: "worked-p", kind: "worked", version: 1, at: 0, turnPhase: "running" };

test("an empty fold keeps the chevron's slot unseen and the label inert", () => {
  const doc = draw({ ...running, foldEmpty: true });
  const toggle = doc.querySelector<HTMLButtonElement>(".cv-worked__toggle")!;
  expect(toggle.disabled).toBe(true);
  expect(toggle.hasAttribute("aria-expanded")).toBe(false);
  const chevron = doc.querySelector(".cv-worked__hug")!.lastElementChild!;
  expect(chevron.getAttribute("class")).toContain("cv-worked__chevron");
  expect(chevron.getAttribute("class")).toContain("is-reserved");
});

test("a fold with work shows the chevron and toggles", () => {
  const doc = draw(running);
  const toggle = doc.querySelector<HTMLButtonElement>(".cv-worked__toggle")!;
  expect(toggle.disabled).toBe(false);
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  expect(doc.querySelector(".cv-worked__hug")!.lastElementChild!.getAttribute("class")).not.toContain("is-reserved");
});
