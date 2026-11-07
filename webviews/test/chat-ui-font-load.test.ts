// Review (gpt-6.1-sol) of #36191: the estimator measured a bundled interface font's rows before its face
// had loaded and cached those heights under the font's name, and the load changed nothing, so offscreen
// rows kept fallback heights and long transcripts jumped. The measure stack now names a bundled face
// only once it has loaded, and the load hands the transcript a new look, which measures every row again.
import { afterAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";

let finishLoad = () => {};
const installed: string[] = [];
await mock.module("../src/agent-session/acpmux/chatFonts/faces", () => ({
  installChatFontFace: (font: string) => {
    installed.push(font);
    return new Promise<void>((resolve) => {
      finishLoad = resolve;
    });
  },
}));

const dom = new JSDOM("<!doctype html><html></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const hadDocument = "document" in globals;
const savedDocument = globals.document;
globals.document = dom.window.document;
afterAll(() => {
  if (hadDocument) globals.document = savedDocument;
  else delete globals.document;
  dom.window.close();
});

const { chatDisplay, currentChatMetrics, resetChatDisplay, setChatDisplay } =
  await import("../src/agent-session/acpmux/chatDisplay");
const { CHAT_UI_FONT_KEY } = await import("../src/agent-session/acpmux/chatUiFont");
/// Lets the face's dynamic import and load chain settle (promise turns only, no clock).
const settle = async () => {
  for (let turn = 0; turn < 20; turn++) await Promise.resolve();
};

test("a bundled interface font is measured once its face has loaded, and the load hands out a new look", async () => {
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "geist" });
  const before = chatDisplay();
  // Loading: the page draws the stack's next face, so the estimate measures that.
  expect(currentChatMetrics().measureFont).not.toContain("cmux Geist");
  expect(currentChatMetrics().measureFont).toContain("Geist");
  await settle();
  expect(installed).toEqual(["geist"]);

  finishLoad();
  await settle();
  expect(currentChatMetrics().measureFont).toContain('"cmux Geist"');
  // The same values under a new identity: App.tsx's `measuredLook` measures every row again.
  expect(chatDisplay()).not.toBe(before);
  expect(chatDisplay()).toEqual(before);

  // Chosen again, a loaded face is not loaded twice.
  resetChatDisplay();
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "geist" });
  expect(installed).toEqual(["geist"]);
  expect(currentChatMetrics().measureFont).toContain('"cmux Geist"');
});
