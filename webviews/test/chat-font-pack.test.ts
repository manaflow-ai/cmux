// A font pack (a community typography theme from the app store) in the chat's `display` map
// (chatDisplay.ts, chatFontFaces.ts): `font.uiFamily` wins over the Interface Font, `font.proseFamily`
// over the Chat Font for the agent's replies only, and `font.faces` declares the pack's faces from
// data URLs in one managed <style>. With none of its keys, the chat draws and measures as before.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { PreparedText } from "@chenglou/pretext";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><html><head></head></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const hadDocument = "document" in globals;
const savedDocument = globals.document;
globals.document = dom.window.document;
/// The page's FontFaceSet, as far as the faces module uses it: each load waits for `finish`.
let finish = () => {};
const loads: string[] = [];
Object.defineProperty(dom.window.document, "fonts", {
  configurable: true,
  value: {
    load: (font: string) => {
      loads.push(font);
      return new Promise<void>((resolve) => {
        const previous = finish;
        finish = () => {
          previous();
          resolve();
        };
      });
    },
  },
});
afterAll(async () => {
  await settleReact();
  if (hadDocument) globals.document = savedDocument;
  else delete globals.document;
  dom.window.close();
});

const {
  CHAT_FONT_FACES_KEY,
  chatDisplay,
  chatDisplayVariables,
  chatMetrics,
  currentChatMetrics,
  DEFAULT_CHAT_DISPLAY,
  PROSE_FAMILY_KEY,
  resolveChatDisplay,
  setChatDisplay,
  UI_FAMILY_KEY,
} = await import("../src/agent-session/acpmux/chatDisplay");
const { CHAT_UI_FONT_KEY } = await import("../src/agent-session/acpmux/chatUiFont");
const { CHAT_FONT_FACES_STYLE_ID, chatFontFaceCss, resolveChatFontFaces } =
  await import("../src/agent-session/acpmux/chatFontFaces");
const { layoutConversation } = await import("../src/agent-session/acpmux/model");

const SYSTEM = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif";
const WOFF2 = "data:font/woff2;base64,d09GMgABAAAAAA==";
const TTF = "data:font/ttf;base64,AAEAAAALAIAAAwAw";
const settle = async () => {
  for (let turn = 0; turn < 20; turn++) await Promise.resolve();
};
const style = () => dom.window.document.getElementById(CHAT_FONT_FACES_STYLE_ID);

describe("with no pack keys", () => {
  test("the default look sets exactly the variables it did before, all left to the stylesheet", () => {
    const variables = chatDisplayVariables(resolveChatDisplay({}));
    expect(variables).toEqual({
      "--font-ui": null,
      "--cv-tracking": null,
      "--text-caption--letter-spacing": null,
      "--text-detail--letter-spacing": null,
      "--text-body--letter-spacing": null,
      "--text-field--letter-spacing": null,
      "--text-title--letter-spacing": null,
      "--text-heading--letter-spacing": null,
      "--cv-font": null,
      // New, and unset: replies keep --cv-font (conversation.css falls back to it).
      "--cv-reply-font": null,
      "--cv-reply-tracking": null,
      // New, and unset: code keeps its font's ligatures.
      "--cv-code-ligatures": null,
      "--cv-code-features": null,
      "--cv-font-size": null,
      "--cv-base-font-size": null,
      "--cv-base-line-height": null,
      "--cv-line-height": null,
      "--cv-code-size": null,
      "--cv-codeblock-size": null,
      "--cv-codeblock-line-height": null,
      "--cv-mono": null,
      "--cv-column": null,
      // A transcript look's parts (transcriptLook.ts): unset, the reply and the prompt draw as the chat.
      "--cv-reply-font-size": null,
      "--cv-reply-line-height": null,
      "--cv-prompt-font": null,
      "--cv-prompt-tracking": null,
      "--cv-prompt-font-size": null,
      "--cv-prompt-line-height": null,
      // The transcript look's primitives (transcriptLook.ts), none set by the cmux look.
      "--cv-user-bubble-pad-block": null,
      "--cv-user-bubble-pad-inline": null,
      "--cv-look-bubble-radius": null,
      "--cv-user-bubble-share": null,
      "--cv-user-bubble-fill": null,
      "--cv-user-align": null,
      "--cv-card-radius": null,
      "--cv-code-radius": null,
    });
    expect(chatDisplayVariables(DEFAULT_CHAT_DISPLAY)).toEqual(variables);
  });

  test("replies and prompts measure in the one font they did", () => {
    const metrics = chatMetrics(resolveChatDisplay({}));
    expect(metrics.measureFont).toBe(`14px ${SYSTEM}`);
    expect(metrics.replyMeasureFont).toBe(metrics.measureFont);
    const verdana = chatMetrics(
      resolveChatDisplay({ [CHAT_UI_FONT_KEY]: "verdana", "agentPane.display.font.size": 16 }),
    );
    expect(verdana.replyMeasureFont).toBe(verdana.measureFont);
  });
});

describe("the pack's families", () => {
  test("an interface family wins over the Interface Font, at its designed spacing", () => {
    const display = resolveChatDisplay({ [UI_FAMILY_KEY]: "Folio Sans", [CHAT_UI_FONT_KEY]: "system-ui-tight" });
    expect(display.uiFamily).toBe("Folio Sans");
    const variables = chatDisplayVariables(display);
    expect(variables["--font-ui"]).toBe(`"Folio Sans", ${SYSTEM}`);
    expect(variables["--cv-tracking"]).toBe("0px");
    for (const step of ["caption", "detail", "body", "field", "title", "heading"])
      expect(variables[`--text-${step}--letter-spacing`]).toBe("0em");
    // No faces declared: an installed family measures at once.
    expect(chatMetrics(display).measureFont).toBe(`14px "Folio Sans", ${SYSTEM}`);
  });

  test("a stack keeps its order, each spaced name quoted", () => {
    const variables = chatDisplayVariables(
      resolveChatDisplay({ [UI_FAMILY_KEY]: " Folio Sans , Avenir Next,sans-serif" }),
    );
    expect(variables["--font-ui"]).toBe(`"Folio Sans", "Avenir Next", sans-serif, ${SYSTEM}`);
  });

  test("every name but a generic keyword is quoted, so an odd name keeps the stack valid", () => {
    const variables = chatDisplayVariables(
      resolveChatDisplay({ [UI_FAMILY_KEY]: "1942, Foo's Sans, ui-serif, serif" }),
    );
    expect(variables["--font-ui"]).toBe(`"1942", "Foo's Sans", ui-serif, serif, ${SYSTEM}`);
  });

  test("an unsafe family is dropped and the Interface Font draws", () => {
    for (const bad of ['Folio"; } body { color: red', "a{b}", "", 12]) {
      const display = resolveChatDisplay({
        [UI_FAMILY_KEY]: bad,
        [PROSE_FAMILY_KEY]: bad,
        [CHAT_UI_FONT_KEY]: "verdana",
      });
      expect(display.uiFamily).toBeNull();
      expect(display.proseFamily).toBeNull();
      expect(chatDisplayVariables(display)["--font-ui"]).toContain("Verdana");
      expect(chatDisplayVariables(display)["--cv-reply-font"]).toBeNull();
    }
  });

  test("a prose family sets the reply's face only, over the Chat Font", () => {
    const display = resolveChatDisplay({ [PROSE_FAMILY_KEY]: "Folio Serif", "agentPane.display.font.preset": "mono" });
    const variables = chatDisplayVariables(display);
    expect(variables["--cv-reply-font"]).toBe('"Folio Serif", var(--cv-font)');
    // At its designed spacing, whatever the Interface Font tracks.
    expect(variables["--cv-reply-tracking"]).toBe("0px");
    // Prompts, cards and chrome keep the chat's font.
    expect(variables["--cv-font"]).toBe("var(--cv-mono)");
    expect(variables["--font-ui"]).toBeNull();
    const metrics = chatMetrics(display);
    expect(metrics.measureFont).toBe('14px "SF Mono", Menlo, monospace');
    expect(metrics.replyMeasureFont).toBe('14px "Folio Serif", "SF Mono", Menlo, monospace');
  });

  test("the estimator measures a reply in the prose family and a prompt in the chat's font", () => {
    setChatDisplay({ [PROSE_FAMILY_KEY]: "Folio Serif" });
    const { measureFont, replyMeasureFont } = currentChatMetrics();
    expect(replyMeasureFont).not.toBe(measureFont);
    const cache = new Map<string, { prepared: Map<string, PreparedText | null> }>();
    layoutConversation(
      [
        { id: "prompt", version: 1, at: 0, kind: "user", text: "Why does **the retry test** fail?\n\n- on CI" },
        { id: "reply", version: 1, at: 1, kind: "assistant", text: "Real timers.\n\n- fake ones now\n- 3 runs" },
      ] as never,
      720,
      cache as never,
    );
    const fonts = (id: string) =>
      [...(cache.get(id)?.prepared.keys() ?? [])].map((key) => key.split("\n")[key.startsWith("lines\n") ? 1 : 0]);
    expect(fonts("reply").length).toBeGreaterThan(0);
    expect(new Set(fonts("reply"))).toEqual(new Set([replyMeasureFont]));
    expect(fonts("prompt").length).toBeGreaterThan(0);
    expect(new Set(fonts("prompt"))).toEqual(new Set([measureFont]));
    setChatDisplay({});
  });
});

describe("code ligatures", () => {
  const CODE_FAMILY = "agentPane.display.code.family";

  test("a pack's own code face draws without ligatures", () => {
    const display = resolveChatDisplay({ [CODE_FAMILY]: "Folio Mono", [CHAT_FONT_FACES_KEY]: { "Folio Mono": WOFF2 } });
    expect(display.codeLigatures).toBe(false);
    const variables = chatDisplayVariables(display);
    expect(variables["--cv-code-ligatures"]).toBe("none");
    expect(variables["--cv-code-features"]).toBe('"calt" 0, "liga" 0');
    // The first family decides, by name (case and an italic-only key count too).
    expect(
      resolveChatDisplay({ [CODE_FAMILY]: "folio mono, Menlo", [CHAT_FONT_FACES_KEY]: { "Folio Mono:italic": WOFF2 } })
        .codeLigatures,
    ).toBe(false);
  });

  test("an installed code font set by hand keeps its ligatures", () => {
    for (const values of [
      { [CODE_FAMILY]: "Fira Code" },
      // A pack face that is not the code family's first entry.
      { [CODE_FAMILY]: "Fira Code, Folio Mono", [CHAT_FONT_FACES_KEY]: { "Folio Mono": WOFF2 } },
      // A key whose value is not a font data URL declares nothing.
      { [CODE_FAMILY]: "Folio Mono", [CHAT_FONT_FACES_KEY]: { "Folio Mono": "https://example.invalid/f.woff2" } },
    ]) {
      const display = resolveChatDisplay(values);
      expect(display.codeLigatures).toBe(true);
      expect(chatDisplayVariables(display)["--cv-code-ligatures"]).toBeNull();
      expect(chatDisplayVariables(display)["--cv-code-features"]).toBeNull();
    }
  });
});

describe("the pack's faces", () => {
  test("only font data URLs under a safe family name are declared, every weight, italic by key", () => {
    const faces = resolveChatFontFaces({
      "Folio Serif:italic": WOFF2,
      "Folio Serif": WOFF2,
      "Folio Mono": TTF,
      "Remote Face": "https://example.com/face.woff2",
      "Svg Face": "data:image/svg+xml;base64,PHN2Zz4=",
      'Bad"Name': WOFF2,
      "Stack, Name": WOFF2,
      "Broken Face": "data:font/woff2;base64,not base64!",
      "Number Face": 3,
    });
    expect(faces.map((face) => `${face.family}${face.italic ? ":italic" : ""}`)).toEqual([
      "Folio Mono",
      "Folio Serif",
      "Folio Serif:italic",
    ]);
    const css = chatFontFaceCss(faces);
    expect(css).toContain(`@font-face{font-family:"Folio Mono";src:url("${TTF}") format("truetype");`);
    expect(css.match(/font-weight:1 1000/g)?.length).toBe(3);
    expect(css.match(/font-style:italic/g)?.length).toBe(1);
    expect(css.match(/font-display:block/g)?.length).toBe(3);
    expect(resolveChatFontFaces(["Folio"])).toEqual([]);
    expect(resolveChatFontFaces(null)).toEqual([]);
  });

  test("one managed style, replaced when the map changes and removed when it empties; measured once loaded", async () => {
    setChatDisplay({ [UI_FAMILY_KEY]: "Folio Sans", [CHAT_FONT_FACES_KEY]: { "Folio Sans": WOFF2 } });
    expect(dom.window.document.querySelectorAll(`#${CHAT_FONT_FACES_STYLE_ID}`).length).toBe(1);
    expect(style()?.textContent).toContain('font-family:"Folio Sans"');
    // Loading: the page draws the stack's next face, so the estimate measures that.
    expect(currentChatMetrics().measureFont).toBe(`14px ${SYSTEM}`);
    expect(loads).toEqual(['400 1em "Folio Sans"']);
    const before = chatDisplay();
    finish();
    await settle();
    const loadedFont = currentChatMetrics().measureFont;
    expect(loadedFont).toMatch(/^14px "Folio Sans", "cmux-pack-\d+", -apple-system/);
    // The same values under a new identity: App.tsx's `measuredLook` measures every row again.
    expect(chatDisplay()).not.toBe(before);
    expect(chatDisplay()).toEqual(before);

    // The same map again (another key changed) declares and loads nothing again.
    const faces = { "Folio Sans": WOFF2 };
    setChatDisplay({ [UI_FAMILY_KEY]: "Folio Sans", [CHAT_FONT_FACES_KEY]: faces, "agentPane.display.font.size": 15 });
    setChatDisplay({
      [UI_FAMILY_KEY]: "Folio Sans",
      [CHAT_FONT_FACES_KEY]: { ...faces },
      "agentPane.display.font.size": 15,
    });
    expect(loads.length).toBe(1);
    expect(currentChatMetrics().measureFont).toBe(loadedFont.replace("14px", "15px"));

    // A new map replaces the faces in the same style.
    setChatDisplay({
      [UI_FAMILY_KEY]: "Folio Sans",
      [PROSE_FAMILY_KEY]: "Folio Serif",
      [CHAT_FONT_FACES_KEY]: { "Folio Sans": WOFF2, "Folio Serif": WOFF2, "Folio Serif:italic": WOFF2 },
    });
    expect(dom.window.document.querySelectorAll(`#${CHAT_FONT_FACES_STYLE_ID}`).length).toBe(1);
    expect(style()?.textContent?.match(/@font-face/g)?.length).toBe(3);
    expect(currentChatMetrics().replyMeasureFont).toBe(`14px ${SYSTEM}`);
    finish();
    await settle();
    expect(currentChatMetrics().replyMeasureFont).toMatch(
      /^14px "Folio Serif", "cmux-pack-\d+", "Folio Sans", "cmux-pack-\d+", -apple-system/,
    );

    // Emptied: the style goes, and the families measure as installed ones, under a font string no
    // face measured before, so no cache hands back the pack face's widths.
    setChatDisplay({ [UI_FAMILY_KEY]: "Folio Sans" });
    expect(style()).toBeNull();
    expect(currentChatMetrics().measureFont).toMatch(/^14px "Folio Sans", "cmux-pack-\d+", -apple-system/);
    expect(currentChatMetrics().measureFont).not.toBe(loadedFont);
    setChatDisplay({});
    expect(chatDisplayVariables(chatDisplay())["--font-ui"]).toBeNull();
  });
});
