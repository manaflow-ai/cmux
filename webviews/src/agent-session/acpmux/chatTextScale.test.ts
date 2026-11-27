// The agent chat draws at Default's size at Compact (user 2026-11-16: "make it so compact and default density have
// same size of both imessage and chat trajectory"). The host writes the density's text scale
// (`--cmux-density-text-scale`, 0.9 at Compact) for the rest of the page and the chat's own
// (`--cmux-chat-text-scale`, Default's at and below Default); the chat's text, its bubbles and the rows the
// transcript measures read the chat's.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() =>
  teardownDom(
    (["window", "document"] as const).map((key) => [key, saved[key], saved.values[key]] as const),
    { scope },
  ),
);

// chatDisplay binds its cmux-ui-scale-change listener to the window it loads under. Another test file in the same bun
// process (typing-load-control.test.ts) can load it first under its own DOM, whose events these tests never send, so
// they load their own instance (the query makes it a separate module).
const displaySpec = "./chatDisplay.ts?chatTextScale";
const loadDisplay = () => import(displaySpec) as Promise<typeof import("./chatDisplay")>;

/// Writes the host's two scales as its scale script does, then tells the page.
const hostScales = (density: string, chat: string) => {
  const root = dom.window.document.documentElement;
  root.style.setProperty("--cmux-density-text-scale", density);
  root.style.setProperty("--cmux-chat-text-scale", chat);
  dom.window.dispatchEvent(new dom.window.Event("cmux-ui-scale-change"));
};

test("at Compact the chat's text is Default's size", async () => {
  const { chatDensityTextScale, chatMetrics, drawnFontSize, DEFAULT_CHAT_DISPLAY } = await loadDisplay();
  hostScales("1", "1");
  const atDefault = chatMetrics(DEFAULT_CHAT_DISPLAY, chatDensityTextScale());
  hostScales("0.9", "1");
  expect(chatDensityTextScale()).toBe(1);
  expect(drawnFontSize(DEFAULT_CHAT_DISPLAY)).toBe(DEFAULT_CHAT_DISPLAY.fontSize);
  expect(chatMetrics(DEFAULT_CHAT_DISPLAY, chatDensityTextScale())).toEqual(atDefault);
});

test("Text Size still grows the chat at Compact", async () => {
  const { chatDensityTextScale, drawnFontSize, DEFAULT_CHAT_DISPLAY } = await loadDisplay();
  hostScales("1.08", "1.2");
  expect(chatDensityTextScale()).toBe(1.2);
  expect(drawnFontSize(DEFAULT_CHAT_DISPLAY)).toBe(Math.round(DEFAULT_CHAT_DISPLAY.fontSize * 1.2 * 4) / 4);
});
