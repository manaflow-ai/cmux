// Two-finger Back / Forward's page glue (swipeNavigation/install.ts): a carousel that takes
// horizontal wheels for itself keeps swipes off, even when its handler also stops the event.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { watchPreventedWheels } from "../src/swipeNavigation/install";

const dom = new JSDOM("<!doctype html><body><div id=c></div><p id=p></p></body>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const view = dom.window as unknown as Window & typeof globalThis;
const doc = view.document;
afterAll(() => dom.window.close());

const wheel = (deltaX: number, deltaY = 0) =>
  new dom.window.WheelEvent("wheel", { deltaX, deltaY, bubbles: true, cancelable: true });
const tick = () => new Promise((resolve) => view.setTimeout(resolve, 0));

test("a horizontal wheel the page prevents and stops still counts", async () => {
  const carousel = doc.getElementById("c")!;
  carousel.addEventListener("wheel", (event) => {
    event.preventDefault();
    event.stopPropagation();
  });
  const seen: number[] = [];
  watchPreventedWheels(view, (at) => seen.push(at));
  carousel.dispatchEvent(wheel(12));
  await tick();
  expect(seen.length).toBe(1);
});

test("a vertical wheel or one nobody prevented does not count", async () => {
  const seen: number[] = [];
  watchPreventedWheels(view, (at) => seen.push(at));
  doc.getElementById("p")!.dispatchEvent(wheel(12));
  doc.getElementById("c")!.dispatchEvent(wheel(1, 20));
  await tick();
  expect(seen).toEqual([]);
});
