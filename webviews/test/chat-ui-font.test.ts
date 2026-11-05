// Leo, 2026-11-05: "right now it's just Apple System, right? But, like, I feel like we can look into a
// hell of a lot more and try out a hell of a lot more. Actually, I haven't tried switching fonts in my
// own app yet." The chat's interface font (`agentPane.display.font.ui`) picks the face of the whole
// chat; unset, it is today's tuned Inter and the page sets nothing.
import { expect, test } from "bun:test";
import { chatDisplayVariables, chatMetrics, resolveChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { CHAT_UI_FONT_KEY, CHAT_UI_FONTS, chatUiFontVariables } from "../src/agent-session/acpmux/chatUiFont";

test("unset or unknown, the interface font is today's tuned Inter and the page sets no variable", () => {
  for (const raw of [{}, { [CHAT_UI_FONT_KEY]: "comic" }, { [CHAT_UI_FONT_KEY]: true }]) {
    const display = resolveChatDisplay(raw);
    expect(display.uiFont).toBe("inter-tuned");
    const variables = chatDisplayVariables(display);
    expect(variables["--font-ui"]).toBeNull();
    expect(variables["--cv-tracking"]).toBeNull();
    expect(variables["--text-body--letter-spacing"]).toBeNull();
  }
});

test("each other choice sets the face and its own tracking on the type scale", () => {
  for (const font of CHAT_UI_FONTS.filter((font) => font !== "inter-tuned")) {
    const variables = chatDisplayVariables(resolveChatDisplay({ [CHAT_UI_FONT_KEY]: font }));
    expect(variables["--font-ui"]).toBeTruthy();
    for (const step of ["caption", "detail", "body", "field", "title", "heading"])
      expect(variables[`--text-${step}--letter-spacing`]).toMatch(/^-?[\d.]+em$/);
  }
  expect(chatUiFontVariables("verdana")["--font-ui"]).toStartWith("Verdana");
  expect(chatUiFontVariables("roboto")["--font-ui"]).toStartWith('"cmux Roboto"');
  // Inter's own curve is for tuned Inter: stock Inter draws at its designed spacing.
  expect(chatUiFontVariables("inter")["--text-heading--letter-spacing"]).toBe("0em");
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
  expect(chatMetrics(resolveChatDisplay({})).measureFont).toBe('14px "Inter", system-ui, sans-serif');
});
