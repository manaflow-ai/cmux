// The browser's element picker (design mode, Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/
// Resources/BrowserDesignModeRuntime.js), run on a real DOM. David Beyer, 2026-11-20: "I like the way
// Codex does it ... if I wanna do a lot of them, this would be visually messy". A click opens a small
// comment bubble under the element with no buttons; Return adds the pick with its comment and a
// numbered pin, Escape drops it, and only added picks reach the chat. Picking several in a row never
// asks for anything else.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";

const RUNTIME = join(
  import.meta.dir,
  "../../Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/Resources/BrowserDesignModeRuntime.js",
);

type Selection = { selector: string; comment?: string; number?: number; tag_name?: string };
type Snapshot = { selections: Selection[] };
type Api = {
  enable(): Snapshot;
  snapshot(): Snapshot;
  draft(text: string): Snapshot;
  commit(): Snapshot;
  removeSelection(selector: string): Snapshot;
  restoreThread(selector: string, comment: string, value: { state: string; reply?: string } | null): boolean;
};

let dom: JSDOM;
let api: Api;
let posted: Array<{ type: string; snapshot?: Snapshot }>;
let roots: ShadowRoot[];
let under: Element | null;

beforeEach(() => {
  dom = new JSDOM(
    `<!doctype html><body><h1 id="title">Example Domain</h1><p class="lede">Some words</p><a href="#more">More</a></body>`,
    { runScripts: "outside-only", pretendToBeVisual: true },
  );
  // The jsdom window as the runtime sees it: the DOM, WebKit's message handler, and its own API.
  const window = dom.window as unknown as {
    eval(source: string): unknown;
    webkit: unknown;
    __cmuxDesignMode: Api;
    Element: typeof Element;
    document: Document;
  };
  posted = [];
  roots = [];
  under = null;
  window.webkit = { messageHandlers: { cmuxDesignMode: { postMessage: (message: never) => posted.push(message) } } };
  // The runtime's root is closed; the test opens it to reach the bubble the way a person's pointer does.
  const attach = window.Element.prototype.attachShadow;
  window.Element.prototype.attachShadow = function (init: ShadowRootInit) {
    const root = attach.call(this, { ...init, mode: "open" });
    roots.push(root);
    return root;
  };
  window.document.elementFromPoint = () => under;
  window.eval(readFileSync(RUNTIME, "utf8"));
  api = window.__cmuxDesignMode;
  api.enable();
});

afterEach(() => dom.window.close());

const doc = () => dom.window.document;
const root = () => roots[0]!;
const field = () => root().querySelector("textarea") as HTMLTextAreaElement;
const bubble = () => field().closest("[data-cmux-bubble]") as HTMLElement;
const bubbleOpen = () => bubble().hasAttribute("data-open");
const pins = () =>
  Array.from(root().querySelectorAll("[data-cmux-pin]"))
    .filter((pin) => (pin as HTMLElement).style.display !== "none")
    .map((pin) => pin.textContent);
const added = () => api.snapshot().selections.map((selection) => [selection.number, selection.comment]);

function click(selector: string) {
  under = doc().querySelector(selector);
  const init = { bubbles: true, button: 0, clientX: 20, clientY: 20 };
  doc().dispatchEvent(new dom.window.MouseEvent("pointerdown", init));
  doc().dispatchEvent(new dom.window.MouseEvent("pointerup", init));
}

function type(text: string) {
  field().value = text;
  field().dispatchEvent(new dom.window.Event("input", { bubbles: true, composed: true }));
}

function key(name: string, extra: KeyboardEventInit = {}) {
  const event = new dom.window.KeyboardEvent("keydown", {
    key: name,
    bubbles: true,
    composed: true,
    cancelable: true,
    ...extra,
  });
  field().dispatchEvent(event);
  return event;
}

test("a click opens the comment bubble under the element, focused, with no buttons; the chat gets nothing yet", () => {
  click("h1");
  expect(bubbleOpen()).toBe(true);
  expect(root().activeElement).toBe(field());
  expect(bubble().querySelectorAll("button")).toHaveLength(0);
  expect(api.snapshot().selections).toEqual([]);
  // The pick's pin already shows the number it will take.
  expect(pins()).toEqual(["1"]);
});

test("Return adds the pick with its comment and number; the chat gets one snapshot with it", () => {
  click("h1");
  type("Make this larger");
  const event = key("Enter");
  expect(event.defaultPrevented).toBe(true);
  expect(bubbleOpen()).toBe(false);
  expect(added()).toEqual([[1, "Make this larger"]]);
  const last = posted.filter((message) => message.type === "snapshot").at(-1);
  expect(last?.snapshot?.selections.map((selection) => selection.comment)).toEqual(["Make this larger"]);
  expect(pins()).toEqual(["1"]);
});

test("several picks in a row: each gets the next number, and none asks for anything else", () => {
  click("h1");
  type("Bigger");
  key("Enter");
  click("p");
  type("Darker text");
  key("Enter");
  click("a");
  type("Make it a button");
  key("Enter");
  expect(added()).toEqual([
    [1, "Bigger"],
    [2, "Darker text"],
    [3, "Make it a button"],
  ]);
  expect(pins()).toEqual(["1", "2", "3"]);
});

test("Shift-Return is a new line, and a composing key never adds", () => {
  click("h1");
  type("Line one");
  expect(key("Enter", { shiftKey: true }).defaultPrevented).toBe(false);
  key("Enter", { isComposing: true });
  expect(bubbleOpen()).toBe(true);
  expect(added()).toEqual([]);
});

test("Escape drops a new pick; clicking away drops an empty one and keeps a typed one", () => {
  click("h1");
  type("Never mind");
  key("Escape");
  expect(bubbleOpen()).toBe(false);
  expect(added()).toEqual([]);
  expect(pins()).toEqual([]);
  click("p");
  click("a");
  expect(added()).toEqual([]);
  type("Typed, then clicked away");
  click("h1");
  expect(added()).toEqual([[1, "Typed, then clicked away"]]);
  expect(bubbleOpen()).toBe(true);
});

test("Return on an empty comment adds the pick without one", () => {
  click("p");
  key("Enter");
  expect(added()).toEqual([[1, ""]]);
});

test("clicking a pick again edits its comment; emptying it and pressing Delete removes it and renumbers", () => {
  click("h1");
  type("First");
  key("Enter");
  click("p");
  type("Second");
  key("Enter");
  click("h1");
  expect(bubbleOpen()).toBe(true);
  expect(field().value).toBe("First");
  type("First, edited");
  key("Enter");
  expect(added()).toEqual([
    [1, "First, edited"],
    [2, "Second"],
  ]);
  click("h1");
  type("");
  key("Backspace");
  expect(added()).toEqual([[1, "Second"]]);
  expect(pins()).toEqual(["1"]);
});

test("keys typed in the bubble never reach the page", () => {
  let seen = 0;
  doc().body.addEventListener("keydown", () => (seen += 1));
  doc().addEventListener("keydown", () => (seen += 1));
  click("h1");
  key("a");
  key("Enter");
  expect(seen).toBe(0);
});

test("Escape with no bubble open asks to leave design mode and keeps the picks", () => {
  click("h1");
  type("Keep me");
  key("Enter");
  doc().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  expect(posted.some((message) => message.type === "exit_requested")).toBe(true);
  expect(added()).toEqual([[1, "Keep me"]]);
});

test("the chat taking a pick out removes its pin and renumbers the rest", () => {
  click("h1");
  type("One");
  key("Enter");
  click("p");
  type("Two");
  key("Enter");
  const [first] = api.snapshot().selections;
  api.removeSelection(first!.selector);
  expect(added()).toEqual([[1, "Two"]]);
  expect(pins()).toEqual(["1"]);
});

test("automation fills and adds the open bubble through the same path", () => {
  click("a");
  api.draft("From the tour");
  api.commit();
  expect(added()).toEqual([[1, "From the tour"]]);
});

// A kept comment thread comes back on its element when design mode turns on again (the browser
// selector anchor, cmuxterm-hq goals/all-surface-comments-round-trip.md): an added pick with its
// comment and pin, its thread card showing the agent's reply, and the chat's tracker hears it.
test("a kept thread is put back on its element by selector, with its comment, pin and reply", () => {
  click("p");
  type("Tighten this");
  key("Enter");
  const [picked] = api.snapshot().selections;
  api.removeSelection(picked!.selector);
  expect(added()).toEqual([]);
  posted.length = 0;
  expect(api.restoreThread(picked!.selector, "Tighten this", { state: "answered", reply: "Done in 3f2c" })).toBe(true);
  expect(added()).toEqual([[1, "Tighten this"]]);
  expect(pins()).toEqual(["1"]);
  expect(
    posted
      .filter((message) => message.type === "snapshot")
      .at(-1)
      ?.snapshot?.selections.map((s) => s.selector),
  ).toEqual([picked!.selector]);
  const card = root().querySelector("[data-cmux-thread]") as HTMLElement;
  expect(card.getAttribute("data-state")).toBe("answered");
  expect(card.textContent).toContain("Done in 3f2c");
  // Restoring it again changes nothing: still one pick.
  expect(api.restoreThread(picked!.selector, "Tighten this", { state: "answered", reply: "Done in 3f2c" })).toBe(true);
  expect(added()).toEqual([[1, "Tighten this"]]);
});

test("a kept thread whose element is gone is not put back", () => {
  expect(api.restoreThread("#no-such-element", "Gone", { state: "sent" })).toBe(false);
  expect(api.restoreThread("::not a selector", "Bad", { state: "sent" })).toBe(false);
  expect(added()).toEqual([]);
});
