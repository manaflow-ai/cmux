import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { accessibleName, resolveTarget } from "../src/gallery/play";

const page = (html: string) => new JSDOM(`<!doctype html><body>${html}</body>`).window.document;

describe("gallery play target names", () => {
  test("a checked menu item is named without its aria-hidden check glyph", () => {
    const document = page(
      `<div role="menuitemradio" aria-checked="true"><span aria-hidden="true"><span aria-hidden="true">✓</span></span>Comfortable</div>`,
    );
    const item = document.querySelector('[role="menuitemradio"]')!;
    expect(accessibleName(item)).toBe("Comfortable");
    expect(resolveTarget(document, { role: "menuitemradio", name: "Comfortable" })).toBe(item);
  });

  test("hidden icons and nested labels keep the visible words, spaced", () => {
    const document = page(
      `<button><svg aria-hidden="true"><title>icon</title></svg><span>Open</span> <span>file</span></button>`,
    );
    expect(accessibleName(document.querySelector("button")!)).toBe("Open file");
  });

  test("aria-labelledby text skips aria-hidden parts too", () => {
    const document = page(
      `<span id="l">Model <span aria-hidden="true">⌘M</span></span><button aria-labelledby="l"></button>`,
    );
    expect(accessibleName(document.querySelector("button")!)).toBe("Model");
  });
});
