// Leo, 2026-11-05: "right now it's just Apple System, right? But, like, I feel like we can look into a
// hell of a lot more and try out a hell of a lot more. Actually, I haven't tried switching fonts in my
// own app yet." The chat's interface font (`agentPane.display.font.ui`) picks the face of the whole
// chat; unset, it is the macOS system font (Lawrence 2026-11-07: "default fonts on cmux for everything should be
// macos default, not inter") and the page sets nothing: desktop.css's `--font-ui` is already the system stack.
import { expect, test } from "bun:test";
import { chatDisplayVariables, chatMetrics, resolveChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { CHAT_UI_FONT_KEY, CHAT_UI_FONTS, chatUiFontVariables } from "../src/agent-session/acpmux/chatUiFont";

test("unset or unknown, the interface font is the system font and the page sets no variable", () => {
  for (const raw of [{}, { [CHAT_UI_FONT_KEY]: "comic" }, { [CHAT_UI_FONT_KEY]: true }]) {
    const display = resolveChatDisplay(raw);
    expect(display.uiFont).toBe("system-ui");
    const variables = chatDisplayVariables(display);
    expect(variables["--font-ui"]).toBeNull();
    expect(variables["--cv-tracking"]).toBeNull();
    expect(variables["--text-body--letter-spacing"]).toBeNull();
  }
});

test("each other choice sets the face and its own tracking on the type scale", () => {
  for (const font of CHAT_UI_FONTS.filter((font) => font !== "system-ui")) {
    const variables = chatDisplayVariables(resolveChatDisplay({ [CHAT_UI_FONT_KEY]: font }));
    expect(variables["--font-ui"]).toBeTruthy();
    for (const step of ["caption", "detail", "body", "field", "title", "heading"])
      expect(variables[`--text-${step}--letter-spacing`]).toMatch(/^-?[\d.]+em$/);
  }
  expect(chatUiFontVariables("verdana")["--font-ui"]).toStartWith("Verdana");
  expect(chatUiFontVariables("roboto")["--font-ui"]).toStartWith('"cmux Roboto"');
  // The font study's picks (webviews/src/gallery/fontStudy): our own cmux Sans, Hanken Grotesk and
  // Atkinson Hyperlegible Next, each a bundled face at its designed spacing.
  expect(chatUiFontVariables("cmux-sans")["--font-ui"]).toStartWith('"cmux Sans"');
  expect(chatUiFontVariables("hanken")["--font-ui"]).toStartWith('"cmux Hanken Grotesk"');
  expect(chatUiFontVariables("atkinson")["--font-ui"]).toStartWith('"cmux Atkinson Hyperlegible Next"');
  expect(chatUiFontVariables("cmux-sans")["--text-body--letter-spacing"]).toBe("0em");
  // Inter's own curve is for tuned Inter: stock Inter draws at its designed spacing.
  expect(chatUiFontVariables("inter")["--text-heading--letter-spacing"]).toBe("0em");
  // Inter is opt-in now: its bundled face, with the curve the app used to apply to it.
  const tuned = chatUiFontVariables("inter-tuned");
  expect(tuned["--font-ui"]).toStartWith('"cmux Inter"');
  expect(tuned["--text-body--letter-spacing"]).toBe("-0.0032em");
  expect(tuned["--text-heading--letter-spacing"]).toBe("-0.0167em");
  // System, tight sits a step under the system font's spacing, more at the larger steps.
  const tight = chatUiFontVariables("system-ui-tight");
  expect(tight["--text-body--letter-spacing"]).toBe("-0.008em");
  expect(tight["--text-heading--letter-spacing"]).toBe("-0.02em");
});

test("the row estimator measures the System preset's text in the interface font", () => {
  const plex = chatMetrics(resolveChatDisplay({ [CHAT_UI_FONT_KEY]: "plex" }));
  // Before its bundled face loads it measures the stack's next face (chat-ui-font-load.test.ts).
  expect(plex.measureFont).toContain('"IBM Plex Sans"');
  // A reading preset of its own keeps its own face.
  const serif = chatMetrics(
    resolveChatDisplay({ [CHAT_UI_FONT_KEY]: "plex", "agentPane.display.font.preset": "serif" }),
  );
  expect(serif.measureFont).toContain("Georgia");
  const unset = chatMetrics(resolveChatDisplay({})).measureFont;
  expect(unset).toBe("14px -apple-system, BlinkMacSystemFont, system-ui, sans-serif");
  expect(unset).not.toContain("Inter");
});
