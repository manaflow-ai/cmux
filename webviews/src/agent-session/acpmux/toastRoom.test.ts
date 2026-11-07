import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { installToastRoom, setToastRoom } from "./toastRoom";

// A native toast is a window overlay. Its compatibility bridge must not change the page's layout
// (design/notifications.md rule 10; Leo 2026-11-06, a toast moving the composer).
describe("toast room", () => {
  test("the legacy host bridge leaves no layout variable behind", () => {
    const { document } = new JSDOM("<!doctype html><html><body></body></html>").window;
    installToastRoom(document);
    (globalThis as typeof globalThis & { __cmuxToastRoom?: (px: number) => void }).__cmuxToastRoom?.(84.5);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("");
    setToastRoom(0, document);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("");
    setToastRoom(Number.NaN, document);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("");
  });

  test("the composer's frame is unchanged while a toast appears and leaves", () => {
    const { document } = new JSDOM(
      '<!doctype html><html><body><section class="acpmux-shell"><div class="acpmux-main"><div class="acpmux-composer"></div></div></section></body></html>',
    ).window;
    const composer = document.querySelector<HTMLElement>(".acpmux-composer")!;
    const frame = { x: 12, y: 420, width: 736, height: 92, top: 420, right: 748, bottom: 512, left: 12 };
    composer.getBoundingClientRect = () => frame as DOMRect;
    const before = composer.getBoundingClientRect().toJSON?.() ?? { ...frame };
    setToastRoom(60, document, 300);
    const during = composer.getBoundingClientRect().toJSON?.() ?? { ...frame };
    setToastRoom(0, document, 300);
    const after = composer.getBoundingClientRect().toJSON?.() ?? { ...frame };
    expect(during).toEqual(before);
    expect(after).toEqual(before);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("");
  });

  test("the bottom stack does not reserve a toast room", () => {
    const css = readFileSync(join(import.meta.dir, "bottomStack.css"), "utf8");
    expect(css).not.toMatch(/padding-bottom:\s*var\(--cmux-toast-room/);
  });
});
