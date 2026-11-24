// Settings search keeps every category and a collapsing slot per row mounted (SearchResults,
// GroupList), editors only for rows that matched. The schema bounds it (each slot is one setting),
// so it is not windowed; but a keystroke draws again only the slots whose match changed and the
// matching rows (their highlight follows the query), and a change elsewhere in the page's state (the
// host's lists, a write to a row that is not shown) does not run the filter or draw a slot again
// (visible-only rules 2 and 3).
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const field = () => page!.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
/** Every row's slot in the results, matched or not. */
const slots = () => page!.container.querySelectorAll<HTMLElement>("[data-search-results] .rows > .collapse");
const open = (slot: Element) => slot.hasAttribute("data-open");
const keyOf = (slot: Element) => slot.querySelector("[data-row-key]")?.getAttribute("data-row-key") ?? null;

// The slot's own element: React's committed props object, as rowPropsRenders reads it.
const propsOf = (element: Element) =>
  (element as unknown as Record<string, unknown>)[
    Object.keys(element).find((name) => name.startsWith("__reactProps$"))!
  ];
let marked = new Map<Element, unknown>();
const mark = () => {
  marked = new Map([...slots()].map((slot) => [slot, propsOf(slot)]));
  return new Map([...slots()].map((slot) => [slot, open(slot)]));
};
const drewAgain = (slot: Element) => marked.has(slot) && marked.get(slot) !== propsOf(slot);

test("a keystroke draws no slot whose row stayed out of the results", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(field(), "fon");
  // Every row of every category has a slot: the schema's size, not the person's data.
  expect(slots().length).toBeGreaterThan(300);
  const before = mark();
  await changeValue(field(), "font");
  const shown = [...slots()].filter(open).length;
  expect(shown).toBeGreaterThan(0);
  const stayedOut = [...slots()].filter((slot) => !before.get(slot) && !open(slot));
  expect(stayedOut.length).toBeGreaterThan(300);
  expect(stayedOut.filter(drewAgain).length).toBe(0);
  // Only the matching rows (their highlight follows the query) and those whose match changed draw again.
  const changed = [...slots()].filter((slot) => before.get(slot) !== open(slot)).length;
  expect([...slots()].filter(drewAgain).length).toBeLessThanOrEqual(shown + changed);
});

test("a change to the host's lists neither filters again nor draws a slot", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(field(), "font");
  const results = () => page!.container.querySelector("[data-search-results]")!;
  const resultsProps = propsOf(results());
  mark();
  await act(async () => page!.provider.setHost({ ...page!.provider.host, machines: [] }));
  await settle();
  // The results did not draw again (the filter runs in their render), and no slot did.
  expect(propsOf(results())).toBe(resultsProps);
  expect([...slots()].filter(drewAgain).length).toBe(0);
  expect([...slots()].filter(open).map(keyOf)).toContain("terminal.fontFamily");
});
