// l10n-allow-file: test fixtures, not shipped UI.
// The "New" line fades when the reader focuses the chat (Leo, 2026-11-21: "if i click into the app or
// click into you for the workspace like focus anything the composer just the window the pane it
// should fade away" / "*without dramatic layout shift ideally..."). Each surface reads the line:
// the app or window becoming key and the pane's web view taking the keyboard (the window's focus),
// the composer or any control in the chat taking focus (the host's focusContent lands there), and a
// click into the chat. The line fades in place: the same element stays mounted with its row (no
// `data-gone`, no collapse), the banner goes, and the mark stays read when the chat is drawn again.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import {
  bannerShown,
  markUnreadRead,
  noteUnreadMounted,
  readUnread,
  readUnreadOnFocus,
  resetUnreadForTest,
  unreadPending,
  unreadRead,
  unreadReadInPlace,
} from "../src/agent-session/acpmux/conversation/unreadState";
import { READER_FOCUS_SETTLE_MS, watchReaderFocus } from "../src/agent-session/acpmux/conversation/readerFocus";
import { teardownDom } from "./support/domTeardown";

beforeEach(() => resetUnreadForTest());

/// A window and a document the watcher listens on, with a clock the test moves.
function fakePage(visible = true) {
  const win = new EventTarget();
  const doc = Object.assign(new EventTarget(), { visibilityState: visible ? "visible" : "hidden" }) as EventTarget & {
    visibilityState: DocumentVisibilityState;
  };
  let clock = 0;
  const heard: string[] = [];
  const keyWatchers = new Set<() => void>();
  const stop = watchReaderFocus((source) => heard.push(source), {
    win: win as unknown as Window,
    doc: doc as unknown as Document,
    now: () => clock,
    watchKey: (run) => {
      keyWatchers.add(run);
      return () => void keyWatchers.delete(run);
    },
  });
  return {
    win,
    doc,
    heard,
    stop,
    advance: (ms: number) => void (clock += ms),
    show: (shown: boolean) => {
      doc.visibilityState = shown ? "visible" : "hidden";
      // pageKey.ts tells its watchers when the page stops or starts being the key one.
      for (const run of keyWatchers) run();
    },
  };
}

test("each focus surface counts once the page has been shown for the settle time", () => {
  const page = fakePage();
  // The activation that drew the line (its window focus, the composer's claim) does not read it.
  page.win.dispatchEvent(new Event("focus"));
  page.doc.dispatchEvent(new Event("focusin"));
  page.doc.dispatchEvent(new Event("pointerdown"));
  expect(page.heard).toEqual([]);
  page.advance(READER_FOCUS_SETTLE_MS);
  page.win.dispatchEvent(new Event("focus")); // the app, the window, the pane's web view
  page.doc.dispatchEvent(new Event("focusin")); // the composer, a control, the host's focusContent
  page.doc.dispatchEvent(new Event("pointerdown")); // a click into the chat
  expect(page.heard).toEqual(["window", "focus", "press"]);
  page.stop();
  page.win.dispatchEvent(new Event("focus"));
  expect(page.heard).toHaveLength(3);
});

test("showing the workspace starts the reader's look; the next focus after it reads the line", () => {
  const page = fakePage(false);
  page.advance(READER_FOCUS_SETTLE_MS * 5);
  // Hidden (a background workspace), nothing counts.
  page.win.dispatchEvent(new Event("focus"));
  expect(page.heard).toEqual([]);
  page.show(true);
  page.doc.dispatchEvent(new Event("focusin"));
  expect(page.heard).toEqual([]);
  page.advance(READER_FOCUS_SETTLE_MS);
  page.doc.dispatchEvent(new Event("focusin"));
  expect(page.heard).toEqual(["focus"]);
  // Hidden again and back: the settle time runs again.
  page.show(false);
  page.show(true);
  page.doc.dispatchEvent(new Event("pointerdown"));
  expect(page.heard).toEqual(["focus"]);
  page.stop();
});

test("a focus reads the mark in place: banner gone, Jump up done, and it stays read when drawn again", () => {
  noteUnreadMounted("s:41");
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(true);
  readUnreadOnFocus("s:41");
  expect(unreadRead("s:41", readUnread())).toBe(true);
  expect(unreadReadInPlace("s:41", readUnread())).toBe(true);
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
  expect(unreadPending("s:41", readUnread())).toBe(false);
  // Another chat's mark, then this chat again (acpmux keeps its `lastReturn`): still read, and it
  // takes no space now (not in place: it was never drawn this time).
  noteUnreadMounted("s:99");
  expect(unreadRead("s:99", readUnread())).toBe(false);
  noteUnreadMounted("s:41");
  expect(unreadRead("s:41", readUnread())).toBe(true);
  expect(unreadReadInPlace("s:41", readUnread())).toBe(false);
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
});

test("a line read another way keeps how it went; a focus after it changes nothing", () => {
  noteUnreadMounted("s:41");
  markUnreadRead("s:41");
  readUnreadOnFocus("s:41");
  expect(unreadReadInPlace("s:41", readUnread())).toBe(false);
});

// The drawn line in a DOM: the same element stays, with its row, and fades.
const dom = new JSDOM("<!doctype html><div id=root></div><textarea id=composer></textarea>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { SinceDivider } = await import("../src/agent-session/acpmux/conversation/SinceDivider");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(async () => {
  act(() => root.unmount());
  resetUnreadForTest();
  await teardownDom(saved, { window: dom.window, scope });
});

// The watcher reads the page's clock: the test moves it past the settle time, with no wait.
let clock = 0;
const realNow = performance.now.bind(performance);
performance.now = () => clock;
afterAll(() => void (performance.now = realNow));
const settle = () => void (clock += READER_FOCUS_SETTLE_MS);

async function drawLine(key: string) {
  await act(async () => root.render(<SinceDivider key={key} since={{ key, seq: 41, turns: 3 }} />));
  const line = host.querySelector<HTMLElement>(".cv-since")!;
  expect(line.hasAttribute("data-read")).toBe(false);
  return line;
}

/// The line read by focus: the same node, still holding its row, faded, nothing collapsing.
function expectFadedInPlace(before: HTMLElement) {
  const after = host.querySelector<HTMLElement>(".cv-since")!;
  expect(after).toBe(before);
  expect(after.getAttribute("data-read")).toBe("focus");
  expect(after.hasAttribute("data-gone")).toBe(false);
  expect(after.hasAttribute("data-row-collapsing")).toBe(false);
  expect(after.querySelector(".cv-since__menu .cv-since__line")).not.toBeNull();
}

const surfaces: [name: string, focus: () => void][] = [
  ["the app, window or pane (window focus)", () => void dom.window.dispatchEvent(new dom.window.FocusEvent("focus"))],
  ["the composer (focusin)", () => dom.window.document.getElementById("composer")!.focus()],
  [
    "a click into the chat (pointerdown)",
    () => void host.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true })),
  ],
];

for (const [name, focus] of surfaces)
  test(`${name} fades the drawn line in place`, async () => {
    dom.window.document.getElementById("composer")!.blur();
    await act(async () => resetUnreadForTest());
    const key = `chat:${name}`;
    const line = await drawLine(key);
    // Right after it is drawn, the activation that drew it does not take it away.
    await act(async () => focus());
    expect(line.hasAttribute("data-read")).toBe(false);
    dom.window.document.getElementById("composer")!.blur();
    settle();
    await act(async () => focus());
    expectFadedInPlace(line);
    expect(unreadReadInPlace(key, readUnread())).toBe(true);
    await act(async () => root.render(null));
  });
