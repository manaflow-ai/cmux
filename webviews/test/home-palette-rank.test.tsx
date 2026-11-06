// The Channels Cmd-K palette ranks through the page client (`cmux.home.paletteRank`, the daemon's
// palette.rank): it shows the rows in order before the first answer, keeps the last answer on screen
// until the next one arrives, and drops an answer for an older query.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import table from "../src/pages/home-channels/generated/strings.json";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const { Palette } = await import("../src/pages/home-channels/Palette");
const { clipUtf8, fixtureRank } = await import("../src/pages/home-channels/paletteRank");
const { MockHomeProvider } = await import("../src/pages/home-channels/mockProvider");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { createStrings } = await import("../src/pages/shared/i18n");
const strings = createStrings(table, ["en"]);
type Request = import("../src/pages/home-channels/paletteRank").PaletteRankRequest;
type Reply = import("../src/pages/home-channels/paletteRank").PaletteRankReply;

const items = ["general", "Release train", "random"].map((title, index) => ({
  id: `c${index}`,
  group: "conversations" as const,
  title,
  run() {},
}));

/** A rank function whose answers the test releases one by one, in any order. */
function heldRanker() {
  const asked: Array<{ request: Request; answer(reply: Reply): void }> = [];
  const rank = (request: Request) => new Promise<Reply>((resolve) => asked.push({ request, answer: resolve }));
  return { asked, rank };
}

function shown(): string[] {
  return [...host.ownerDocument.querySelectorAll("[role='option'] .lg-palette-title")].map(
    (node) => node.textContent ?? "",
  );
}

async function type(value: string) {
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, value);
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

/** The reply that ranks the rows at `indexes` in that order. */
const reply = (...indexes: number[]): Reply => ({
  sections: [{ sectionIndex: 0, rows: indexes.map((index) => ({ index, score: 1, highlights: [] })) }],
});

test("the palette keeps the last answer until the next and drops an older query's", async () => {
  const ranker = heldRanker();
  root = createRoot(host);
  await act(async () => root!.render(createElement(Palette, { items, rank: ranker.rank, strings, onClose() {} })));
  // Before any answer: the rows in their order, never an empty list.
  expect(shown()).toEqual(["general", "Release train", "random"]);
  expect(ranker.asked.map((ask) => ask.request.query)).toEqual([""]);
  expect(ranker.asked[0]!.request.keepsSectionOrder).toBe(true);

  await type("r");
  await type("re");
  expect(ranker.asked.map((ask) => ask.request.query)).toEqual(["", "r", "re"]);
  // Nothing answered yet: the first frame's rows stay.
  expect(shown()).toEqual(["general", "Release train", "random"]);

  // The newest query answers first, then the older one: the older answer is dropped.
  await act(async () => ranker.asked[2]!.answer(reply(1)));
  expect(shown()).toEqual(["Release train"]);
  await act(async () => ranker.asked[1]!.answer(reply(2, 1)));
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  expect(shown()).toEqual(["Release train"]);

  // A new query keeps the shown answer until its own arrives.
  await type("rel");
  expect(shown()).toEqual(["Release train"]);
  await act(async () => ranker.asked[3]!.answer(reply()));
  expect(shown()).toEqual([]);
});

test("a failed rank falls back to the substring filter, not to no rows", async () => {
  root = createRoot(host);
  await act(async () =>
    root!.render(
      createElement(Palette, {
        items,
        rank: () => Promise.reject(new Error("daemon went away")),
        strings,
        onClose() {},
      }),
    ),
  );
  await type("RAN");
  expect(shown()).toEqual(["random"]);
});

test("the fixture ranker keeps the rows in order, filtered by a case-insensitive substring", async () => {
  const entries = [
    { title: "general", sectionIndex: 0 },
    { title: "Fix it", keywords: ["Release"], sectionIndex: 1 },
    { title: "Release train", sectionIndex: 0 },
  ];
  expect(fixtureRank({ entries, query: "" }).sections.map((section) => section.rows.map((row) => row.index))).toEqual([
    [0, 2],
    [1],
  ]);
  expect(fixtureRank({ entries, query: "release" }).sections).toEqual([
    { sectionIndex: 0, rows: [{ index: 2, score: 0, highlights: [] }] },
    { sectionIndex: 1, rows: [{ index: 1, score: 0, highlights: [] }] },
  ]);
  // The mock provider (gallery and dev loop) answers the op with it.
  const mocked = await new MockHomeProvider().call<Reply>(HomeOps.paletteRank, { entries, query: "TRAIN" });
  expect(mocked).toEqual({
    sections: [{ sectionIndex: 0, rows: [{ index: 2, score: 0, highlights: [] }] }],
  });
});

test("a row that changes while an answer is on its way runs its current action", async () => {
  const ranker = heldRanker();
  const ran: string[] = [];
  const rows = (label: string) => items.map((item) => ({ ...item, run: () => void ran.push(`${label}:${item.id}`) }));
  root = createRoot(host);
  const render = (list: ReturnType<typeof rows>) =>
    act(async () => root!.render(createElement(Palette, { items: list, rank: ranker.rank, strings, onClose() {} })));
  await render(rows("old"));
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  // The rows change (one leaves) before their new answer arrives.
  await render(rows("new").filter((item) => item.id !== "c2"));
  expect(shown()).toEqual(["general", "Release train"]);
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(ran).toEqual(["new:c0"]);
});

test("the request is clipped to the daemon's byte caps on a character boundary", () => {
  expect(clipUtf8("short", 512)).toBe("short");
  const long = "é".repeat(300); // 600 bytes
  expect(new TextEncoder().encode(clipUtf8(long, 512)).length).toBe(512);
  expect(clipUtf8("a😀", 4)).toBe("a");
});
