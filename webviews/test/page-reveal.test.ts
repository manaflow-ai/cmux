// shared/pageReveal.ts: the one owner of "may an entrance run now" for a page that is switched
// away from and back to (shared-projections.md). Hidden: no. Shown again: not until its first frame
// back has passed. Every finite animation finishes when the page hides and when it shows, so an
// entrance started while hidden never plays on return; spinners keep spinning.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { entranceAllowed, finishPageAnimations, installRevealSettle } from "../src/agent-session/shared/pageReveal";

type Fake = { playState: AnimationPlayState; finished: number; effect: { getComputedTiming(): { endTime: number } } };

function page() {
  const { window } = new JSDOM("<!doctype html>", { pretendToBeVisual: true });
  let visibility: DocumentVisibilityState = "visible";
  Object.defineProperty(window.document, "visibilityState", { configurable: true, get: () => visibility });
  const animations: Fake[] = [];
  const add = (endTime: number) => {
    const fake = {
      playState: "running" as AnimationPlayState,
      finished: 0,
      effect: { getComputedTiming: () => ({ endTime }) },
      finish() {
        fake.finished += 1;
        fake.playState = "finished";
      },
    };
    animations.push(fake);
    return fake;
  };
  (window.document as unknown as { getAnimations: () => unknown[] }).getAnimations = () => animations;
  const frames: (() => void)[] = [];
  window.requestAnimationFrame = (run: FrameRequestCallback) => frames.push(() => run(0));
  const set = (next: DocumentVisibilityState) => {
    visibility = next;
    window.document.dispatchEvent(new window.Event("visibilitychange"));
  };
  const frame = () => frames.splice(0).forEach((run) => run());
  return { doc: window.document, add, set, frame };
}

test("an entrance waits while hidden and until the first frame back has passed", () => {
  const { doc, set, frame } = page();
  installRevealSettle(doc);
  expect(entranceAllowed(doc)).toBe(true);
  set("hidden");
  expect(entranceAllowed(doc)).toBe(false);
  set("visible");
  expect(entranceAllowed(doc)).toBe(false);
  frame();
  expect(entranceAllowed(doc)).toBe(false);
  frame();
  expect(entranceAllowed(doc)).toBe(true);
});

test("a reveal superseded by another hide and show settles on the newer one's frames", () => {
  const { doc, set, frame } = page();
  installRevealSettle(doc);
  set("hidden");
  set("visible");
  frame();
  set("hidden");
  set("visible");
  frame(); // The first reveal's second frame and the second reveal's first.
  expect(entranceAllowed(doc)).toBe(false);
  frame();
  expect(entranceAllowed(doc)).toBe(true);
});

test("hiding and showing finish finite animations and leave infinite ones running", () => {
  const { doc, add, set } = page();
  installRevealSettle(doc);
  const entrance = add(180);
  const spinner = add(Number.POSITIVE_INFINITY);
  set("hidden");
  expect(entrance.finished).toBe(1);
  expect(spinner.finished).toBe(0);
  // Started while hidden (a row that streamed in): finished as the page shows, before it plays.
  const late = add(180);
  set("visible");
  expect(late.finished).toBe(1);
  expect(spinner.playState).toBe("running");
});

test("motion turned off by the host allows no entrance", () => {
  const { doc } = page();
  doc.documentElement.dataset.agentMotion = "off";
  expect(entranceAllowed(doc)).toBe(false);
});

test("a document without getAnimations finishes nothing", () => {
  const { window } = new JSDOM("<!doctype html>");
  expect(finishPageAnimations(window.document)).toBe(0);
});

test("motion off is not away: a paced view keeps its pace and catches up only on return", async () => {
  const { pageAway } = await import("../src/agent-session/shared/pageReveal");
  const { doc, set, frame } = page();
  installRevealSettle(doc);
  doc.documentElement.dataset.agentMotion = "off";
  expect(pageAway(doc)).toBe(false);
  set("hidden");
  expect(pageAway(doc)).toBe(true);
  set("visible");
  expect(pageAway(doc)).toBe(true);
  frame();
  frame();
  expect(pageAway(doc)).toBe(false);
  expect(entranceAllowed(doc)).toBe(false);
});
