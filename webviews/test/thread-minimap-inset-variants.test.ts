import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import gallery from "../src/agent-session/acpmux/threadMinimap/threadMinimapNarrow.gallery";
import type { PlayContext } from "../src/gallery/play";

test.each([
  ["inset-current", 29],
  ["inset-4-lawrence-candidate", 4],
  ["inset-8-reference-candidate", 8],
  ["inset-12-alternative", 12],
  ["inset-16-alternative", 16],
  ["gap-4-chosen", 40],
  ["gap-8", 36],
  ["gap-12", 32],
] as const)("%s places the prompt rail at %i px", async (variantName, expectedLeft) => {
  const dom = new JSDOM(`<!doctype html><div id="frame">
    <nav class="acpmux-minimap__rail acpmux-scrollmap" style="left: 73px"></nav>
    <nav id="prompt-rail" class="acpmux-minimap__rail" style="left: 29px"></nav>
    <div class="acpmux-row"></div>
  </div>`);
  try {
    const document = dom.window.document;
    const rail = document.querySelector<HTMLElement>("#prompt-rail")!;
    const scrollMap = document.querySelector<HTMLElement>(".acpmux-scrollmap")!;
    const frame = document.querySelector<HTMLElement>("#frame")!;
    const row = document.querySelector<HTMLElement>(".acpmux-row")!;
    // jsdom has no layout. Keep a known transcript gutter for the pre-existing gap plays.
    Object.defineProperty(rail, "offsetParent", { value: frame });
    frame.getBoundingClientRect = () => new dom.window.DOMRect(20, 0, 780, 640);
    row.getBoundingClientRect = () => new dom.window.DOMRect(100, 0, 600, 100);
    rail.getBoundingClientRect = () => new dom.window.DOMRect(49, 0, 36, 180);
    let waits = 0;
    const ctx = {
      document,
      waitFor: async (condition: Parameters<PlayContext["waitFor"]>[0]) => {
        waits += 1;
        expect(condition()).toBe(rail);
      },
    } as PlayContext;
    const variant = gallery.variants[variantName];
    expect(variant).toBeDefined();
    await variant!.play?.(ctx);

    expect(rail.style.left).toBe(`${expectedLeft}px`);
    expect(scrollMap.style.left).toBe("73px");
    expect(waits).toBe(variantName === "inset-current" ? 0 : 1);
  } finally {
    dom.window.close();
  }
});
