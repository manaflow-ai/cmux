// u51892 (2026-11-23, on the sidebar's "Updated to Nightly" card): "why the x icon is not aligned vertically
// with the Updated to Nightly thing? let's put it on the right side in line with the Updated to Nightly". The
// host's native x sat at the corner's concentric inset, below the title. The page reports the title line's
// middle with its size (surface.tsx `cardTitleMid`, `title` in `cmux.changelog.surface.size`), down from the
// top of the card's own box, and the host centers the x on it (UpdatedCardCloseTitleLineTests in Swift).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { cardTitleMid } from "../src/pages/changelog/surface";

function rect(top: number, height: number): DOMRect {
  return {
    top,
    height,
    bottom: top + height,
    left: 0,
    right: 200,
    width: 200,
    x: 0,
    y: top,
    toJSON: () => ({}),
  } as DOMRect;
}

function page(html: string, rects: Record<string, [number, number]>): HTMLElement {
  const dom = new JSDOM(`<!doctype html><div id="root">${html}</div>`);
  const root = dom.window.document.getElementById("root")!;
  root.getBoundingClientRect = () => rect(...(rects["#root"] ?? [0, 0]));
  for (const [selector, [top, height]] of Object.entries(rects)) {
    const element = root.querySelector<HTMLElement>(selector);
    if (element) element.getBoundingClientRect = () => rect(top, height);
  }
  return root;
}

test("the title line's middle is measured from the card's own box, not the page with its open preview", () => {
  // The open preview stands 120 px above the card's box; the title's capitals start 12 px into the box.
  const root = page(
    `<section class="wn-updated"><div class="wn-preview"></div><div class="wn-card-rest"><div class="wn-card-head"><div class="wn-card-title">Updated to Nightly</div></div><p class="wn-card-note">A change</p></div></section>`,
    { "#root": [0, 186], ".wn-card-rest": [120, 66], ".wn-card-title": [132, 8.6] },
  );
  expect(cardTitleMid(root)).toBe(16.25);
});

test("the middle stays on the title line however tall the card grows for its change line", () => {
  const markup = `<div class="wn-card-rest"><div class="wn-card-head"><div class="wn-card-title">Updated to Nightly</div></div><p class="wn-card-note">x</p></div>`;
  const short = page(markup, { "#root": [0, 48], ".wn-card-rest": [0, 48], ".wn-card-title": [12, 9] });
  const tall = page(markup, { "#root": [0, 92], ".wn-card-rest": [0, 92], ".wn-card-title": [12, 9] });
  expect(cardTitleMid(short)).toBe(16.5);
  expect(cardTitleMid(tall)).toBe(cardTitleMid(short));
});

test("a card with no title reports none, and the host keeps its x in the corner", () => {
  expect(cardTitleMid(page(`<div class="wn-card-rest"></div>`, { "#root": [0, 48] }))).toBe(0);
});
