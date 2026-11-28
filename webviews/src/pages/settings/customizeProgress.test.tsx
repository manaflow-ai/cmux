// Settings > General > Customize cmux: the checklist Rust answers (`cmux --json customize checklist`)
// draws as General's first card, on for everyone; it shows n of m from the answer, Open goes where a
// step is done, a check writes `customize.checklist.done`, and Dismiss writes
// `customize.checklist.enabled` false and puts the card away.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockOptions } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, ops } = await import("./testing");
const { checklistFacts, toggledDone } = await import("./customizeProgress");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="customizeProgress"]');
const count = () => card()!.querySelector<HTMLElement>("[data-progress]")!.textContent;

// The mock signs in its model connections (mockModels.ts); with Models unread, "agents" counts only
// when a test says so, whichever read lands first.
async function open(mock?: MockOptions) {
  const failing = { "cmux.settings.models.state": "unavailable", ...mock?.failing };
  page = await renderPage({ path: "/settings/general", mock: { ...mock, failing } });
  await settle();
  return page;
}

test("General opens on the checklist, on by default, at 0 of 15 on a fresh install", async () => {
  await open();
  expect(card()).not.toBeNull();
  expect(count()).toBe("0 of 15 done");
  // On General after its own rows, not first (Leo 2026-11-27: "why do we have so many up top?").
  const section = page!.container.querySelector<HTMLElement>(".section[data-section='general']")!;
  const cards = [...section.querySelectorAll<HTMLElement>("[data-card]")].map((el) => el.dataset.card);
  expect(cards[0]).toBe("textSize");
  expect(cards.at(-1)).toBe("customizeProgress");
  // The next five steps left, the rest behind Show All.
  expect(card()!.querySelectorAll("[data-step]").length).toBe(5);
});

test("it draws n of m from the answer: changed settings and hand checks count", async () => {
  await open({
    values: { "appearance.theme": "Nightfall", "terminal.fontSize": 14, "customize.checklist.done": ["look"] },
  });
  expect(count()).toBe("3 of 15 done");
  // Done steps leave the short list; the next one left leads it.
  expect(card()!.querySelector<HTMLElement>("[data-step]")!.dataset.step).toBe("background");
});

test("a step's Open goes to where it is done", async () => {
  await open();
  await click(card()!.querySelector('[data-step-open="theme"]')!);
  expect(page!.history.location.pathname).toBe("/settings/appearance");
  expect(page!.history.location.search).toContain("focus=card.themeStudio");
});

test("checking a step off writes it to customize.checklist.done and counts it", async () => {
  await open();
  await click(card()!.querySelector('[data-step="theme"] input[type="checkbox"]')!);
  await settle();
  const writes = ops(page!.provider, "cmux.settings.set").map((params) => params as { key?: string; value?: unknown });
  expect(writes.some((write) => write.key === "customize.checklist.done")).toBe(true);
  expect(count()).toBe("1 of 15 done");
});

test("Dismiss writes customize.checklist.enabled false and hides the card", async () => {
  await open();
  await click(card()!.querySelector('[aria-label="Dismiss"]')!);
  await settle();
  expect(card()).toBeNull();
  expect(ops(page!.provider, "cmux.settings.set")).toContainEqual(
    expect.objectContaining({ key: "customize.checklist.enabled", value: false }),
  );
});

test("a dismissed checklist draws nothing", async () => {
  await open({ values: { "customize.checklist.enabled": false } });
  expect(card()).toBeNull();
});

test("the page reports only the connections it holds", () => {
  expect(checklistFacts({ accounts: null, models: null })).toEqual([]);
  expect(
    checklistFacts({
      accounts: { github: { connections: [{ id: "1" }] } } as never,
      models: { personal: { connections: [{ signedIn: true }] } } as never,
    }),
  ).toEqual(["models", "github"]);
  expect(toggledDone(["a", 3, "b"], "a", false)).toEqual(["b"]);
  expect(toggledDone(undefined, "a", true)).toEqual(["a"]);
});
