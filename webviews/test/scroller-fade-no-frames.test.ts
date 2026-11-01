// A field unmounting in a view with no animation frames (a JSDOM page made without
// pretendToBeVisual, as many New Tab tests make one) threw from the scroller fade's stop:
// `view.cancelAnimationFrame is not a function` (scrollers.ts followShownScrollerFade). A view
// that cannot draw frames runs no fade, and stopping it is a no-op.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { followShownScrollerFade } from "../src/scrollers";

test("the scroller fade stops cleanly in a view with no animation frames", () => {
  const dom = new JSDOM("<!doctype html><div></div>");
  const element = dom.window.document.querySelector("div") as unknown as HTMLElement;
  const stop = followShownScrollerFade(element);
  expect(() => stop()).not.toThrow();
  dom.window.close();
});
