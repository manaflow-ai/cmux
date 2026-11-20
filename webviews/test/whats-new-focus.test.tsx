// Leo 2026-11-08, on the sidebar Updated card's list: "if someone clicks it... maybe just bring
// them to the section in what's new aka bringing that tab up". The host opens the page on
// `#/?…&area=<a>&entry=<title>&n=<nonce>`; the sheet scrolls to that change (unfolding its area),
// else to the area's section, and marks it for a moment.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
const scrolled: { text: string | null; block?: string; behavior?: string }[] = [];

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.changelog/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  dom.window.HTMLElement.prototype.scrollIntoView = function (this: HTMLElement, options?: ScrollIntoViewOptions) {
    scrolled.push({
      text: this.querySelector(".cls-row-title, .cls-area-name")?.textContent ?? null,
      block: options?.block,
      behavior: options?.behavior,
    });
  } as never;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const entry = (id: string, title: string) => ({
  id,
  category: "improved" as const,
  title: { en: title },
  summary: { en: "" },
});

// Nine sidebar changes: the area shows six, then "Show more".
const sidebar = Array.from({ length: 9 }, (_, i) => entry(`s${i}`, `Sidebar rows change number ${i + 1}`));
const notes: ReleaseNotes[] = [
  {
    build: "4124615690001",
    shortVersion: "1.0.0-nightly.4124615690001",
    date: "2026-10-31",
    highlights: [],
    changes: [],
    whatsNew: {
      version: "1.0.0-nightly.4124615690001",
      channel: "nightly",
      date: "2026-10-31",
      headline: { en: "" },
      entries: [...sidebar, entry("links", "Links reuse the browser pane beside your chat")],
    },
  },
];

test("the route's focus is the change a click asked for", async () => {
  const { parseFocus } = await import("../src/pages/changelog/store");
  expect(parseFocus("")).toBeUndefined();
  expect(parseFocus("#/?from=1&to=2")).toBeUndefined();
  expect(parseFocus("#/?from=1&to=2&area=agentChat&entry=Faster%20chat%20a%2Bb&n=k1")).toEqual({
    area: "agentChat",
    entry: "Faster chat a+b",
    n: "k1",
  });
  expect(parseFocus("#/?area=sidebar")).toEqual({ area: "sidebar" });
});

async function mount(hash: string) {
  dom.window.location.hash = hash;
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => void mountChangelogPage(root, new MockChangelogProvider(notes) as never));
  for (let tries = 0; tries < 200 && root.querySelectorAll(".cls-row").length < 2; tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  return root;
}

async function navigate(hash: string) {
  await act(async () => {
    dom.window.location.hash = hash;
    dom.window.dispatchEvent(new dom.window.HashChangeEvent("hashchange"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("a focused change folded behind Show more unfolds, scrolls into view and is marked", async () => {
  scrolled.length = 0;
  const root = await mount("#/?area=sidebar&entry=Sidebar%20rows%20change%20number%208&n=a");
  const row = [...root.querySelectorAll<HTMLElement>(".cls-row")].find(
    (el) => el.dataset.entry === "sidebar rows change number 8",
  );
  expect(row).toBeDefined();
  expect(root.querySelectorAll(".cls-area[data-area=sidebar] .cls-row").length).toBe(9);
  expect(root.querySelector(".cls-area[data-area=sidebar] .cls-more")).toBeNull();
  expect(row!.hasAttribute("data-focus")).toBe(true);
  expect(scrolled).toEqual([{ text: "Sidebar rows change number 8", block: "center", behavior: "smooth" }]);

  // An unrelated render scrolls nothing.
  await navigate("#/?area=sidebar&entry=Sidebar%20rows%20change%20number%208&n=a");
  expect(scrolled.length).toBe(1);

  // The same change clicked again (a new nonce) scrolls again; less motion jumps.
  dom.window.document.documentElement.dataset.cmuxMotion = "reduced";
  await navigate("#/?area=sidebar&entry=Sidebar%20rows%20change%20number%208&n=b");
  expect(scrolled.at(-1)).toEqual({ text: "Sidebar rows change number 8", block: "center", behavior: "auto" });
  delete dom.window.document.documentElement.dataset.cmuxMotion;

  // A title the page does not list falls back to its area's section.
  await navigate("#/?area=agentChat&entry=Something%20else&n=c");
  expect(scrolled.at(-1)).toEqual({ text: "Agent Chat", block: "start", behavior: "smooth" });
  expect(root.querySelector(".cls-area[data-area=agentChat]")!.hasAttribute("data-focus")).toBe(true);
  expect(row!.hasAttribute("data-focus")).toBe(false);
  root.remove();
});

test("with no focus the area stays folded and nothing scrolls", async () => {
  scrolled.length = 0;
  const root = await mount("#/");
  expect(root.querySelectorAll(".cls-area[data-area=sidebar] .cls-row").length).toBe(6);
  expect(root.querySelector(".cls-area[data-area=sidebar] .cls-more")).not.toBeNull();
  expect(scrolled).toEqual([]);
  root.remove();
});
