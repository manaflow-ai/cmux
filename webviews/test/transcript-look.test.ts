// The transcript's looks as data (conversation/transcriptLook.ts, schemas/transcript-look/transcript-look.json;
// Leo, 2026-11-18: "esp the like... claude style, chatgpt/codex style, and "studio" style things"):
//   - every look in the JSON resolves with every token it sets valid;
//   - the cmux look (and no key) sets no CSS variable and no root attribute: today's chat;
//   - a bad override is dropped per token, a good one wins over the look;
//   - the person's own agentPane.display.* key wins over the look's overlapping token.
import { describe, expect, test } from "bun:test";
import {
  chatDisplayVariables,
  DEFAULT_CHAT_DISPLAY,
  resolveChatDisplay,
} from "../src/agent-session/acpmux/chatDisplay";
import { chatColumnOf } from "../src/agent-session/acpmux/chatWidth";
import {
  gapScaleOf,
  resolveTranscriptLook,
  TRANSCRIPT_LOOK_KEY,
  TRANSCRIPT_LOOKS,
  TRANSCRIPT_TOKENS,
  TRANSCRIPT_TOKENS_KEY,
  transcriptLookAttributes,
  transcriptLookVariables,
  userBubbleBox,
  validTokenValue,
} from "../src/agent-session/acpmux/conversation/transcriptLook";

const LOOK_VARIABLES = [
  "--cv-user-bubble-pad-block",
  "--cv-user-bubble-pad-inline",
  "--cv-look-bubble-radius",
  "--cv-user-bubble-share",
  "--cv-user-bubble-fill",
  "--cv-user-align",
  "--cv-card-radius",
  "--cv-code-radius",
];

describe("transcript looks", () => {
  test("the JSON's cmux, claude, codex and studio looks are there", () => {
    expect(TRANSCRIPT_LOOKS.map((look) => look.name)).toEqual(["cmux", "claude", "codex", "studio"]);
  });

  test("every look resolves with every token it sets valid", () => {
    for (const look of TRANSCRIPT_LOOKS) {
      const resolved = resolveTranscriptLook({ [TRANSCRIPT_LOOK_KEY]: look.name });
      expect(resolved.look).toBe(look.name);
      // Nothing the look sets is dropped, and nothing it does not set appears.
      expect(resolved.tokens).toEqual(look.tokens);
      for (const [name, value] of Object.entries(look.tokens)) expect(validTokenValue(name, value)).toBe(value);
      // Every variable and attribute is a string or null, never a NaN or undefined.
      for (const value of [
        ...Object.values(transcriptLookVariables(resolved)),
        ...Object.values(transcriptLookAttributes(resolved)),
      ]) {
        expect(
          value === null || (typeof value === "string" && !value.includes("NaN") && !value.includes("undefined")),
        ).toBe(true);
      }
      expect(Number.isFinite(gapScaleOf(resolved))).toBe(true);
    }
  });

  test("every token's default is valid for it", () => {
    for (const spec of TRANSCRIPT_TOKENS) expect(validTokenValue(spec.name, spec.default)).toBe(spec.default);
  });

  test("cmux and no key: no variable, no attribute, gap scale 1", () => {
    for (const raw of [{}, { [TRANSCRIPT_LOOK_KEY]: "cmux" }, { [TRANSCRIPT_LOOK_KEY]: "nope" }, null, "x"]) {
      const resolved = resolveTranscriptLook(raw);
      expect(resolved).toEqual({ look: "cmux", tokens: {} });
      expect(Object.values(transcriptLookVariables(resolved)).every((value) => value === null)).toBe(true);
      expect(Object.values(transcriptLookAttributes(resolved)).every((value) => value === null)).toBe(true);
      expect(gapScaleOf(resolved)).toBe(1);
      expect(userBubbleBox(resolved)).toEqual({ padBlock: null, padInline: null, share: null });
    }
    // The whole chat display too: today's look, every variable left to the stylesheet.
    const display = resolveChatDisplay({ [TRANSCRIPT_LOOK_KEY]: "cmux" });
    expect(display).toEqual(DEFAULT_CHAT_DISPLAY);
    const variables = chatDisplayVariables(display, 1);
    for (const name of LOOK_VARIABLES) expect(name in variables).toBe(true);
    expect(Object.values(variables).every((value) => value === null)).toBe(true);
  });

  test("a bad override is dropped, a good one wins over the look", () => {
    const resolved = resolveTranscriptLook({
      [TRANSCRIPT_LOOK_KEY]: "claude",
      [TRANSCRIPT_TOKENS_KEY]: {
        "userMessage.radius": 99, // out of range: the look's 16
        "userMessage.fill": "0.2", // wrong type: the look's 0.06
        density: "airy", // not a choice: the look's comfortable
        sparkle: 3, // unknown: dropped
        timestamps: "always", // valid: wins over hover
        rowSpacing: 1.5, // valid, the look leaves it out
      },
    });
    // The look's own values, read from the JSON so an edit to the data never breaks this.
    const claude = TRANSCRIPT_LOOKS.find((look) => look.name === "claude")!.tokens;
    expect(resolved.tokens["userMessage.radius"]).toBe(claude["userMessage.radius"]);
    expect(resolved.tokens["userMessage.fill"]).toBe(claude["userMessage.fill"]);
    expect(resolved.tokens.density).toBe(claude.density);
    expect("sparkle" in resolved.tokens).toBe(false);
    expect(resolved.tokens.timestamps).toBe("always");
    expect(resolved.tokens.rowSpacing).toBe(1.5);
    expect(gapScaleOf(resolved)).toBe(gapScaleOf(resolveTranscriptLook({ [TRANSCRIPT_LOOK_KEY]: "claude" })) * 1.5);
    expect(transcriptLookAttributes(resolved)["data-transcript-timestamps"]).toBe("always");
    // Overrides that are not an object are ignored whole.
    expect(resolveTranscriptLook({ [TRANSCRIPT_LOOK_KEY]: "codex", [TRANSCRIPT_TOKENS_KEY]: [1, 2] }).tokens).toEqual(
      TRANSCRIPT_LOOKS.find((look) => look.name === "codex")!.tokens,
    );
  });

  test("the look's variables and the estimator's box agree", () => {
    // A fixed set of overrides, so the numbers are this test's own, not a look's.
    const studio = resolveTranscriptLook({
      [TRANSCRIPT_TOKENS_KEY]: {
        density: "compact",
        "userMessage.paddingBlock": 12,
        "userMessage.paddingInline": 12,
        "userMessage.radius": 16,
        "userMessage.maxWidth": 0.8,
        "userMessage.fill": 0.08,
        "toolCard.radius": 6,
      },
    });
    const variables = transcriptLookVariables(studio);
    // Grid units of the 4 pt base: 12 / 4, 16 / 4.
    expect(variables["--cv-user-bubble-pad-block"]).toBe("3");
    expect(variables["--cv-user-bubble-pad-inline"]).toBe("3");
    expect(variables["--cv-look-bubble-radius"]).toBe("4");
    expect(variables["--cv-user-bubble-share"]).toBe("80%");
    expect(variables["--cv-user-bubble-fill"]).toBe("8%");
    expect(variables["--cv-card-radius"]).toBe("calc(6px * var(--cmux-interface-scale, 1))");
    expect(userBubbleBox(studio)).toEqual({ padBlock: 12, padInline: 12, share: 0.8 });
    expect(gapScaleOf(studio)).toBe(0.75);
    // A plain prompt: the whole column, left, no fill or corner.
    const plain = resolveTranscriptLook({ [TRANSCRIPT_TOKENS_KEY]: { "userMessage.style": "plain" } });
    expect(userBubbleBox(plain)).toEqual({ padBlock: 4, padInline: 12, share: 1 });
    expect(transcriptLookVariables(plain)).toMatchObject({
      "--cv-user-bubble-share": "100%",
      "--cv-user-align": "flex-start",
      "--cv-look-bubble-radius": "0",
      "--cv-user-bubble-fill": "0%",
    });
    expect(transcriptLookAttributes(plain)).toEqual({
      "data-transcript-look": null,
      "data-transcript-user": "plain",
      "data-transcript-timestamps": null,
      "data-transcript-tool-cards": null,
      "data-transcript-card-border": null,
    });
  });

  test("the person's own width, font and sizes win over the look's", () => {
    const base = {
      [TRANSCRIPT_LOOK_KEY]: "cmux",
      [TRANSCRIPT_TOKENS_KEY]: { messageWidth: 720, fontSize: 15, lineHeight: 1.65 },
    };
    const look = resolveChatDisplay(base);
    expect(look.width).toBe(720);
    expect(look.fontSize).toBe(15);
    expect(look.lineHeight).toBe(1.65);
    expect(chatColumnOf(look, 1)).toEqual({ min: 720, max: 720 });
    const own = resolveChatDisplay({
      ...base,
      "agentPane.display.width": 960,
      "agentPane.display.font.size": 13,
      "agentPane.display.font.lineHeight": 1.4,
      "agentPane.display.font.preset": "serif",
    });
    expect(own.width).toBe(960);
    expect(own.fontSize).toBe(13);
    expect(own.lineHeight).toBe(1.4);
    expect(own.font).toBe("serif");
    expect(chatColumnOf(own, 1)).toEqual({ min: 720, max: 960 });
    // The look's font stands in for the Markdown viewer's, but an explicit `markdown` follows it.
    const mono = {
      [TRANSCRIPT_LOOK_KEY]: "cmux",
      [TRANSCRIPT_TOKENS_KEY]: { font: "mono" },
      "markdown.font.preset": "serif",
    };
    expect(resolveChatDisplay(mono).font).toBe("mono");
    expect(resolveChatDisplay({ ...mono, "agentPane.display.font.preset": "markdown" }).font).toBe("serif");
    // The look's width sets the column variable the stylesheet reads.
    expect(chatDisplayVariables(look, 1)["--cv-column"]).toContain("720px");
  });
});
