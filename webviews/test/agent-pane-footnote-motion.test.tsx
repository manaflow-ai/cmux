// A reply's footnote reference (conversation/Markdown.tsx) scrolls to its note. It glides only while
// motion is on: with the system's Reduce Motion or cmux's animations off (`data-agent-motion="off"`)
// it lands in one frame, as Jump to latest does (App.tsx `jumpToLatest`). hq#3581: the click
// passed `behavior: "smooth"` whatever the reader had asked for.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Markdown } from "../src/agent-session/acpmux/conversation/Markdown";

const reply = "The cap is WebKit's.[^1]\n\n[^1]: PreferPageRenderingUpdatesNear60FPSEnabled.";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(reduce: boolean): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const window = dom.window;
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    matchMedia: (query: string) => ({
      matches: reduce && query === "(prefers-reduced-motion: reduce)",
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
    }),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  window.matchMedia = replacements.matchMedia as typeof window.matchMedia;
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

/// Clicks the reply's footnote reference and returns the options its note was scrolled with.
async function followNote(options: { reduce?: boolean; motionOff?: boolean } = {}) {
  const container = installDom(options.reduce ?? false);
  if (options.motionOff) document.documentElement.dataset.agentMotion = "off";
  await act(async () => {
    root = createRoot(container);
    root.render(<Markdown>{reply}</Markdown>);
  });
  const note = container.querySelector<HTMLElement>(".cv-footnote");
  const ref = container.querySelector<HTMLButtonElement>(".cv-fnref button");
  expect(note).not.toBeNull();
  expect(ref?.getAttribute("aria-describedby")).toBe(note!.id);
  const calls: (ScrollIntoViewOptions | boolean | undefined)[] = [];
  note!.scrollIntoView = (arg?: ScrollIntoViewOptions | boolean) => void calls.push(arg);
  await act(async () => ref!.click());
  return calls;
}

test("with motion on, a footnote reference glides to its note", async () => {
  expect(await followNote()).toEqual([{ block: "nearest", behavior: "smooth" }]);
});

test("with the system's Reduce Motion, a footnote reference lands on its note in one frame", async () => {
  expect(await followNote({ reduce: true })).toEqual([{ block: "nearest", behavior: "auto" }]);
});

test("with cmux's animations off, a footnote reference lands on its note in one frame", async () => {
  expect(await followNote({ motionOff: true })).toEqual([{ block: "nearest", behavior: "auto" }]);
});
