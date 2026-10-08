import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readScrollPosition, restoreScrollPosition, scrollTargetFor } from "../src/gallery/shell/scroll";

const dom = new JSDOM(`<!doctype html><main class="gallery-main"><iframe></iframe></main>`);
const iframe = dom.window.document.querySelector("iframe")!;
const main = dom.window.document.querySelector(".gallery-main")! as HTMLElement;

afterAll(() => dom.window.close());

describe("gallery stage scroll restoration", () => {
  test("uses the shell scroll container on desktop and the window on mobile", () => {
    main.style.overflowY = "auto";
    expect(scrollTargetFor(iframe)).toBe(main);
    main.style.overflowY = "visible";
    expect(scrollTargetFor(iframe)).toBeNull();
  });

  test("captures and restores one element position", () => {
    main.scrollLeft = 12;
    main.scrollTop = 34;
    const position = readScrollPosition(main);
    main.scrollLeft = 0;
    main.scrollTop = 0;
    restoreScrollPosition(main, position);
    expect(readScrollPosition(main)).toEqual({ x: 12, y: 34 });
  });
});
