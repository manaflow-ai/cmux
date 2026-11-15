// l10n-allow-file: test fixture markup, not shipped UI.
// A wide table's thin sideways thumb fades in as the table scrolls and fades out after, instead of
// showing and hiding in one frame (user 2026-11-08: "this table thing needs better animation on
// appear/disappear"). WebKit restyles a scrollbar's parts only when its element's style is
// resolved again, never on a CSS transition's steps, so the ink steps once a frame from script
// (scrollers.ts followShownScrollerFade), as the transcript's own thumb does. Before, a table's
// thumb went from none to full the frame it started scrolling, and back the frame it stopped.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { watchSideways } from "../src/agent-session/acpmux/conversation/sideways";
import { SCROLLER_FADE_ATTRIBUTE, SCROLLING_ATTRIBUTE, SIDEWAYS_SCROLLER_ATTRIBUTE } from "../src/scrollers";

/** The thumb's ink in percent of its full color, stepped inline while it fades. */
const SIDEWAYS_INK_PROPERTY = "--cmux-sideways-ink";

let window: JSDOM["window"];
let stop: () => void = () => {};

beforeEach(() => {
  ({ window } = new JSDOM(
    '<!doctype html><html style="--cmux-scroller-fade-in: 20s; --cmux-scroller-fade-out: 20s"><body></body></html>',
    { url: "http://localhost/", pretendToBeVisual: true },
  ));
});
afterEach(() => {
  stop();
  window.close();
});

/** A table box 300 wide holding 900 of table, with the page's scrollbar fade on or off. */
function table(fade: boolean) {
  const root = window.document.documentElement;
  root.toggleAttribute(SCROLLER_FADE_ATTRIBUTE, fade);
  const box = window.document.createElement("div");
  box.className = "cv-table-wrap";
  box.setAttribute(SIDEWAYS_SCROLLER_ATTRIBUTE, "");
  window.document.body.append(box);
  Object.defineProperties(box, {
    clientWidth: { get: () => 300 },
    scrollWidth: { get: () => 900 },
  });
  stop = watchSideways(box);
  return box;
}

const ink = (box: HTMLElement) => box.style.getPropertyValue(SIDEWAYS_INK_PROPERTY);
const frames = (count: number) =>
  new Promise<void>((done) => {
    const step = (left: number) => (left <= 0 ? done() : window.requestAnimationFrame(() => step(left - 1)));
    step(count);
  });

test("a table's sideways thumb fades in while it scrolls and fades out after, never in one frame", async () => {
  const box = table(true);
  // Fades 20 s long, so a loaded machine's slow frames still land mid-fade.
  box.setAttribute(SCROLLING_ATTRIBUTE, "");
  await frames(3);
  const rising = parseFloat(ink(box));
  expect(rising).toBeGreaterThan(0);
  expect(rising).toBeLessThan(100);
  // It stops scrolling mid-fade: the thumb fades back out from where it is, never jumping.
  box.removeAttribute(SCROLLING_ATTRIBUTE);
  await frames(3);
  const falling = parseFloat(ink(box));
  expect(falling).toBeGreaterThan(0);
  expect(falling).toBeLessThanOrEqual(rising + 0.01);
});

test("without the page's scrollbar fade the thumb stays drawn and nothing steps", async () => {
  const box = table(false);
  box.setAttribute(SCROLLING_ATTRIBUTE, "");
  await frames(3);
  expect(ink(box)).toBe("");
});
