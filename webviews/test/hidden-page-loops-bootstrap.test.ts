// HIDDEN-PAGE LOOPS (p03-rendering-120) in the WebTheme bootstrap, without a browser: the page
// changes nothing until the host first calls `cmuxTheme.visibility` (feature `hiddenPageLoops` off
// means it never does); from then on the host's word and `visibilitychange` set `data-cmux-hidden`,
// fire `cmux-visibility` once per change, and hold animation-frame callbacks until the show.
// hidden-page-no-frames.test.ts counts frames and animations over a second in Chromium.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";

const bootstrap = readWebThemeBootstrap();

type ThemeWindow = { cmuxTheme: { visibility(shown: boolean): void; framesAllowed(): boolean } };

function page() {
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const engineFrame = dom.window.requestAnimationFrame;
  dom.window.eval(bootstrap);
  const doc = dom.window.document;
  const theme = (dom.window as unknown as ThemeWindow).cmuxTheme;
  let events = 0;
  doc.addEventListener("cmux-visibility", () => events++);
  const setVisibilityState = (state: "hidden" | "visible") => {
    Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => state });
    doc.dispatchEvent(new dom.window.Event("visibilitychange"));
  };
  const hidden = () => doc.documentElement.hasAttribute("data-cmux-hidden");
  const frame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
  return { dom, engineFrame, theme, events: () => events, setVisibilityState, hidden, frame };
}

test("before the host's first call the page is as it was: the engine's frames, no mark", () => {
  const p = page();
  expect(p.dom.window.requestAnimationFrame).toBe(p.engineFrame);
  p.setVisibilityState("hidden");
  expect(p.hidden()).toBe(false);
  expect(p.events()).toBe(0);
  p.dom.window.close();
});

test("the host's word marks the page once per change and frames wait for the show", async () => {
  const p = page();
  p.theme.visibility(true);
  expect(p.hidden()).toBe(false);
  expect(p.events()).toBe(0);
  p.theme.visibility(false);
  p.theme.visibility(false);
  expect(p.hidden()).toBe(true);
  expect(p.events()).toBe(1);
  expect(p.theme.framesAllowed()).toBe(false);
  const ran: string[] = [];
  p.dom.window.requestAnimationFrame(() => ran.push("held"));
  expect(ran).toEqual([]);
  p.theme.visibility(true);
  expect(p.events()).toBe(2);
  await p.frame();
  expect(ran).toEqual(["held"]);
  p.dom.window.close();
});

test("once the host spoke, visibilitychange marks the page too; the host's hidden wins over a visible document", () => {
  const p = page();
  p.theme.visibility(true);
  p.setVisibilityState("hidden");
  expect(p.hidden()).toBe(true);
  p.setVisibilityState("visible");
  expect(p.hidden()).toBe(false);
  p.theme.visibility(false);
  p.setVisibilityState("visible");
  expect(p.hidden()).toBe(true);
  p.dom.window.close();
});

test("the stylesheet pauses every animation under the mark", () => {
  const p = page();
  const sheet = p.dom.window.document.getElementById("cmux-theme")?.textContent ?? "";
  expect(sheet).toContain("html[data-cmux-hidden] *,html[data-cmux-hidden] *::before,html[data-cmux-hidden] *::after");
  expect(sheet).toContain("{animation-play-state:paused !important}");
  p.dom.window.close();
});
