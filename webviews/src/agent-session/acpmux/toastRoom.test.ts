import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { installToastRoom, setToastRoom } from "./toastRoom";

// A toast never covers the chat: the host's band reaches the page as --cmux-toast-room, and the
// shell keeps everything above it (Leo 2026-11-06, a toast over his queued prompt).
describe("toast room", () => {
  test("the host's band reaches the page root, and goes when the toasts go", () => {
    const { document } = new JSDOM("<!doctype html><html><body></body></html>").window;
    installToastRoom(document);
    (globalThis as typeof globalThis & { __cmuxToastRoom?: (px: number) => void }).__cmuxToastRoom?.(84.5);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("84.5px");
    setToastRoom(0, document);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("");
    setToastRoom(Number.NaN, document);
    expect(document.documentElement.style.getPropertyValue("--cmux-toast-room")).toBe("");
  });

  test("the shell keeps its stage and bottom stack above the band", () => {
    const css = readFileSync(join(import.meta.dir, "bottomStack.css"), "utf8");
    expect(css).toMatch(/\.acpmux-shell\s*\{[^}]*padding-bottom:\s*var\(--cmux-toast-room,\s*0px\)/);
    expect(css).toMatch(/\.acpmux-shell\s*\{[^}]*box-sizing:\s*border-box/);
  });
});
