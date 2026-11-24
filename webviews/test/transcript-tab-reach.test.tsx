// l10n-allow-file: test fixtures, not shipped UI.
// Tab never walks onto a transcript row the virtual list rendered past the viewport's edge (#38090).
// The list mounts rows a little above and below what is in view, and each row's controls (Copy, Read
// aloud, More) are tab stops. The browser's next stop from the composer (Shift-Tab) or from a
// control above the transcript (Tab) was such a row, and focusing it scrolled the reader away from
// where they were reading. Tab now hands off to the nearest stop on screen in that direction, the
// way it leaves the toast deck and Jump to latest (ui/tabReach.ts).
//
// The test document has no layout and no sequential focus navigation, so `press` plays the
// browser's part: it sends the key to the focused element and, unless the page took it, moves focus
// to the previous or next tabbable element in tree order. Boxes and hit testing are stubbed: a row's
// controls sit at the row's place.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const win = dom.window;
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: win,
  document: win.document,
  navigator: win.navigator,
  HTMLElement: win.HTMLElement,
  Element: win.Element,
  customElements: win.customElements,
  Node: win.Node,
  MutationObserver: win.MutationObserver,
  KeyboardEvent: win.KeyboardEvent,
  getComputedStyle: win.getComputedStyle.bind(win),
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: win.requestAnimationFrame.bind(win),
  cancelAnimationFrame: win.cancelAnimationFrame.bind(win),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(win))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (win as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEW = { width: 760, height: 700 };
Object.defineProperty(win, "innerWidth", { value: VIEW.width, configurable: true });
Object.defineProperty(win, "innerHeight", { value: VIEW.height, configurable: true });
// A tall list viewport mounts every row of these small conversations, as overscan mounts rows past
// the real viewport's edges.
Object.defineProperty(win.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(win.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

/// Where each turn's rows are drawn, top in viewport px (set per test).
let turnTop: Record<string, number> = {};
const BOXES: Record<string, { top: number; height: number }> = {
  header: { top: 10, height: 24 },
  composer: { top: 640, height: 40 },
  // A plain scroller, for the region test below.
  region: { top: 40, height: 600 },
  // A control inside text collapsed to no height (a sent message's preview before it opens), in view.
  collapsed: { top: 300, height: 0 },
  // A frame in view and a control scrolled out of view below it, for the frame test below.
  frame: { top: 200, height: 100 },
  "out-of-view": { top: 1_400, height: 24 },
};
win.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const own = BOXES[this.id];
  if (own) return new win.DOMRect(40, own.top, 200, own.height);
  // The transcript's scroller: the view between the header and the composer.
  if (this.classList.contains("acpmux-scroll")) return new win.DOMRect(0, 40, 760, 600);
  // The thread minimap's ticks stand on its rail at the pane's edge, always in view.
  if (this.classList.contains("acpmux-minimap__tick")) {
    const ticks = [...win.document.querySelectorAll(".acpmux-minimap__tick")];
    return new win.DOMRect(4, 300 + ticks.indexOf(this) * 12, 8, 8);
  }
  const row = this.closest<HTMLElement>("[data-row-id]");
  const id = row?.dataset.rowId ?? "";
  const turn = id.match(/\d+$/)?.[0];
  if (turn === undefined || turnTop[turn] === undefined) return new win.DOMRect(0, 0, 0, 0);
  const index = "uaf".indexOf(id[0] ?? "");
  return new win.DOMRect(40, turnTop[turn]! + Math.max(0, index) * 60, 120, 28);
};
win.document.elementFromPoint = (x: number, y: number) => {
  if (x < 0 || y < 0 || x >= VIEW.width || y >= VIEW.height) return null;
  for (const element of win.document.querySelectorAll<HTMLElement>("button, textarea")) {
    const rect = element.getBoundingClientRect();
    if (rect.width > 0 && x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom) return element;
  }
  return win.document.body;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { keepTabOnScreen, tabStops } = await import("../src/ui/tabReach");

afterEach(() => {
  win.document.getElementById("root")!.replaceChildren();
});
afterAll(async () => {
  await teardownDom(saved, { window: win, scope });
});

function turn(n: number, at: number) {
  return [
    { id: `u${n}`, version: 1, at, kind: "user", text: `Question ${n}.` },
    { id: `a${n}`, version: 1, at: at + 1_000, kind: "assistant", text: `Answer ${n}.` },
    {
      id: `f${n}`,
      version: 1,
      at: at + 2_000,
      kind: "turnSummary",
      durationMs: 2_000,
      toolCount: 0,
      status: "completed",
    },
  ];
}

async function renderPane() {
  const expanded = new Set<string>();
  const rows = turnView([...turn(1, 0), ...turn(2, 10_000), ...turn(3, 20_000)], expanded, { now: 60_000 });
  const root = createRoot(win.document.getElementById("root")!);
  await act(async () =>
    root.render(
      <>
        <button id="header" type="button">
          Header
        </button>
        <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={expanded} />
        <textarea id="composer" aria-label="Message" />
      </>,
    ),
  );
  return root;
}

const TABBABLE = "button:not(:disabled), textarea:not(:disabled), input:not(:disabled), a[href], [tabindex]";

/// Tab or Shift-Tab as the browser does it: the page may take the key; otherwise focus moves to the
/// next tabbable element in tree order.
function press(shift: boolean): void {
  const doc = win.document;
  const active = doc.activeElement as HTMLElement | null;
  if (!active) throw new Error("nothing focused");
  act(() => {
    const event = new win.KeyboardEvent("keydown", { key: "Tab", shiftKey: shift, bubbles: true, cancelable: true });
    if (!active.dispatchEvent(event)) return;
    const order = [...doc.querySelectorAll<HTMLElement>(TABBABLE)].filter(
      (element) => element.tabIndex >= 0 && !element.closest("[inert]"),
    );
    order[order.indexOf(active) + (shift ? -1 : 1)]?.focus();
  });
}

/// Where focus is: an element's id, or a transcript control's turn and whether its centre is in view.
function focused(): string {
  const active = win.document.activeElement as HTMLElement | null;
  if (!active) return "none";
  if (active.id in BOXES) return active.id;
  const id = active.closest<HTMLElement>("[data-row-id]")?.dataset.rowId ?? "?";
  const rect = active.getBoundingClientRect();
  const centre = rect.top + rect.height / 2;
  return `turn ${id.match(/\d+$/)?.[0]} ${rect.height > 0 && centre >= 0 && centre < VIEW.height ? "in view" : "off screen"}`;
}

test("Shift-Tab from the composer lands on a transcript control in view, never one below the viewport", async () => {
  // Scrolled to the top: turn 1 in view, turns 2 and 3 mounted below the viewport's edge.
  turnTop = { "1": 100, "2": 1_400, "3": 1_700 };
  const root = await renderPane();
  try {
    act(() => win.document.getElementById("composer")!.focus());
    press(true);
    expect(focused()).toBe("turn 1 in view");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Tab from above the transcript lands on a control in view, never one above the viewport", async () => {
  // Scrolled down: turn 1 mounted above the viewport's edge, turn 2 in view, turn 3 below. The
  // control just before the rows is the thread minimap's last tick.
  turnTop = { "1": -900, "2": 200, "3": 1_500 };
  const root = await renderPane();
  try {
    const ticks = win.document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick");
    expect(ticks.length).toBeGreaterThan(0);
    act(() => ticks[ticks.length - 1]!.focus());
    press(false);
    expect(focused()).toBe("turn 2 in view");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Tab past the last control in view leaves the transcript instead of scrolling to the next row", async () => {
  turnTop = { "1": 100, "2": 1_400, "3": 1_700 };
  const root = await renderPane();
  try {
    act(() => win.document.getElementById("composer")!.focus());
    press(true);
    expect(focused()).toBe("turn 1 in view");
    for (let step = 0; step < 6 && focused() !== "composer"; step += 1) {
      press(false);
      expect(focused()).not.toContain("off screen");
    }
    expect(focused()).toBe("composer");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Tab still reaches a control in view inside text that opens on focus", () => {
  // A sent message's preview is collapsed to no height until focus enters it; its code controls
  // have no box yet, but they are in view, and the browser's Tab into them opens the text
  // (message-preview-browser.test.ts). Only a stop scrolled out of the view is passed over.
  const doc = win.document;
  const host = doc.getElementById("root")!;
  host.innerHTML =
    '<button id="header" type="button">Header</button>' +
    '<div id="region"><div style="max-height:0;overflow:hidden"><button id="collapsed" type="button">Copy</button></div></div>' +
    '<textarea id="composer" aria-label="Message"></textarea>';
  const stop = keepTabOnScreen(doc.getElementById("region")!);
  try {
    act(() => doc.getElementById("header")!.focus());
    press(false);
    expect(focused()).toBe("collapsed");
  } finally {
    stop();
  }
});

test("the stops are every control the browser tabs to, and only those", () => {
  // Players with controls (a reply's audio or video, ReplyMedia.tsx), a details' own summary, a
  // frame, an editable box and anything with a tabindex of 0 or more are stops; a player without
  // controls, a second summary, a box marked not editable, a negative tabindex and a disabled,
  // inert or hidden control are not (#38230 review F1).
  const host = win.document.getElementById("root")!;
  host.innerHTML = [
    '<audio id="audio" controls></audio>',
    '<audio id="audio-bare"></audio>',
    '<video id="video" controls></video>',
    '<video id="video-bare"></video>',
    '<details><summary id="summary">More</summary><summary id="summary-second">Not this</summary>x</details>',
    '<summary id="summary-loose">Loose</summary>',
    '<iframe id="frame" title="Frame"></iframe>',
    '<div id="editable" contenteditable="true"></div>',
    '<div id="plain-editable" contenteditable></div>',
    '<div id="not-editable" contenteditable="false"></div>',
    '<div id="tabbable" tabindex="0"></div>',
    '<div id="later" tabindex="2"></div>',
    '<div id="skipped" tabindex="-1"></div>',
    '<button id="button-skipped" tabindex="-1">x</button>',
    '<button id="disabled" disabled>x</button>',
    '<div inert><button id="inert">x</button></div>',
    '<input id="hidden-input" type="hidden" />',
    '<a id="link" href="#x">x</a>',
    '<a id="anchor">x</a>',
  ].join("");
  expect(tabStops(host).map((stop) => stop.id)).toEqual([
    "audio",
    "video",
    "summary",
    "frame",
    "editable",
    "plain-editable",
    "tabbable",
    "later",
    "link",
  ]);
});

test("Tab from inside a frame or player is left to the browser", () => {
  // The document's focus stays on a frame or a player while Tab moves through what is inside it, so
  // the guard cannot tell its last control from its first: it leaves those presses alone, even with
  // the next listed stop out of view (#38230 review F1, second round).
  const doc = win.document;
  const host = doc.getElementById("root")!;
  host.innerHTML =
    '<div id="region"><iframe id="frame" title="Frame"></iframe><button id="out-of-view" type="button">Below</button></div>' +
    '<textarea id="composer" aria-label="Message"></textarea>';
  const stop = keepTabOnScreen(doc.getElementById("region")!);
  try {
    act(() => doc.getElementById("frame")!.focus());
    expect(win.document.activeElement?.id).toBe("frame");
    const event = new win.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
    act(() => {
      doc.getElementById("frame")!.dispatchEvent(event);
    });
    expect(event.defaultPrevented).toBe(false);
  } finally {
    stop();
  }
});
