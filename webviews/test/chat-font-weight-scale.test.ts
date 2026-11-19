// A font pack's weights and reply size (chatDisplay.ts UI_WEIGHT_KEY, PROSE_WEIGHT_KEY, PROSE_SCALE_KEY;
// the font pack itself is chat-font-pack.test.ts). A pack copies a reference look in a face whose
// stroke and x-height differ, so it sets the interface weight, the reply prose's weight and the reply
// prose's size as a share of the chat's: the Claude look is its sans at 430 with replies at 1.095.
//   - values clamp to 100..900 (whole numbers) and 0.8..1.4; anything but a finite number is none;
//   - the CSS sets the weights on the page's root and the reply, and the reply's size and line;
//   - prompts, code and the composer keep their sizes; only reply rows measure taller;
//   - with none of the keys, nothing changes.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><html><head></head></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const hadDocument = "document" in globals;
const savedDocument = globals.document;
globals.document = dom.window.document;
afterAll(async () => {
  await settleReact();
  if (hadDocument) globals.document = savedDocument;
  else delete globals.document;
  dom.window.close();
});

const {
  chatDisplayVariables,
  chatMetrics,
  DEFAULT_CHAT_DISPLAY,
  PROSE_FAMILY_KEY,
  PROSE_SCALE_KEY,
  PROSE_WEIGHT_KEY,
  resolveChatDisplay,
  setChatDisplay,
  UI_WEIGHT_KEY,
} = await import("../src/agent-session/acpmux/chatDisplay");
const { layoutConversation } = await import("../src/agent-session/acpmux/model");

const SYSTEM = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif";
const PACK_KEYS = ["--cv-ui-weight", "--cv-reply-weight", "--cv-reply-font-size", "--cv-reply-line-height"];
/// The Claude look's values (cmux#46705): its sans at 430, replies at 1.095.
const CLAUDE_LOOK = { [UI_WEIGHT_KEY]: 430, [PROSE_SCALE_KEY]: 1.095 };

describe("resolution", () => {
  test("none of the keys is the default look", () => {
    const display = resolveChatDisplay({});
    expect(display).toEqual(DEFAULT_CHAT_DISPLAY);
    expect(display.uiWeight).toBeNull();
    expect(display.proseWeight).toBeNull();
    expect(display.proseScale).toBeNull();
    for (const name of PACK_KEYS) expect(chatDisplayVariables(display)[name]).toBeNull();
  });

  test("weights clamp to 100..900 as whole numbers", () => {
    const at = (value: unknown) => resolveChatDisplay({ [UI_WEIGHT_KEY]: value, [PROSE_WEIGHT_KEY]: value });
    expect(at(430).uiWeight).toBe(430);
    expect(at(430).proseWeight).toBe(430);
    expect(at(430.4).uiWeight).toBe(430);
    expect(at(50).uiWeight).toBe(100);
    expect(at(1200).proseWeight).toBe(900);
  });

  test("the scale clamps to 0.8..1.4 in thousandths, and 1 is no scale", () => {
    const at = (value: unknown) => resolveChatDisplay({ [PROSE_SCALE_KEY]: value }).proseScale;
    expect(at(1.095)).toBe(1.095);
    expect(at(1.0954)).toBe(1.095);
    expect(at(0.5)).toBe(0.8);
    expect(at(3)).toBe(1.4);
    expect(at(1)).toBeNull();
    expect(at(1.0004)).toBeNull();
  });

  test("junk is no value", () => {
    for (const junk of ["430", "bold", Number.NaN, Number.POSITIVE_INFINITY, null, true, {}, [430]]) {
      const display = resolveChatDisplay({ [UI_WEIGHT_KEY]: junk, [PROSE_WEIGHT_KEY]: junk, [PROSE_SCALE_KEY]: junk });
      expect(display.uiWeight).toBeNull();
      expect(display.proseWeight).toBeNull();
      expect(display.proseScale).toBeNull();
      expect(display).toEqual(DEFAULT_CHAT_DISPLAY);
    }
  });
});

describe("the CSS", () => {
  test("the interface weight goes on the root, the reply's over it", () => {
    const ui = chatDisplayVariables(resolveChatDisplay({ [UI_WEIGHT_KEY]: 430 }));
    expect(ui["--cv-ui-weight"]).toBe("430");
    // The reply follows the root's weight in the stylesheet.
    expect(ui["--cv-reply-weight"]).toBeNull();
    const both = chatDisplayVariables(resolveChatDisplay({ [UI_WEIGHT_KEY]: 430, [PROSE_WEIGHT_KEY]: 380 }));
    expect(both["--cv-ui-weight"]).toBe("430");
    expect(both["--cv-reply-weight"]).toBe("380");
  });

  test("the scale sets the reply's size, in quarter pixels, on a line of the same ratio", () => {
    const variables = chatDisplayVariables(resolveChatDisplay(CLAUDE_LOOK), 1);
    // 14 x 1.095 = 15.33, drawn at 15.25; 15.25 x 1.625 = 24.78.
    expect(variables["--cv-reply-font-size"]).toBe("15.25px");
    expect(variables["--cv-reply-line-height"]).toBe("24.78px");
    // At a 16px chat and the density's 1.1 text scale: 17.5 x 1.095 = 19.16, drawn at 19.25.
    const larger = chatDisplayVariables(resolveChatDisplay({ ...CLAUDE_LOOK, "agentPane.display.font.size": 16 }), 1.1);
    expect(larger["--cv-reply-font-size"]).toBe("19.25px");
  });

  test("the weights and scale move nothing else: prompts, code, the column and the composer keep theirs", () => {
    const base = { "agentPane.display.font.size": 15, "agentPane.display.code.scale": 0.8 };
    const without = chatDisplayVariables(resolveChatDisplay(base), 1);
    const withPack = chatDisplayVariables(resolveChatDisplay({ ...base, ...CLAUDE_LOOK, [PROSE_WEIGHT_KEY]: 450 }), 1);
    for (const name of Object.keys(without)) {
      if (PACK_KEYS.includes(name)) continue;
      expect([name, withPack[name]]).toEqual([name, without[name]]);
    }
    expect(Object.keys(withPack).sort()).toEqual(Object.keys(without).sort());
  });
});

describe("the row estimator", () => {
  test("prompts measure at the interface weight, replies at theirs and at the reply's size", () => {
    const metrics = chatMetrics(resolveChatDisplay(CLAUDE_LOOK), 1);
    expect(metrics.measureFont).toBe(`430 14px ${SYSTEM}`);
    expect(metrics.replyMeasureFont).toBe(`430 15.25px ${SYSTEM}`);
    expect(metrics.lineHeight).toBe(22.75);
    expect(metrics.replyLineHeight).toBe(24.78);
    // Code keeps its sizes.
    const plain = chatMetrics(DEFAULT_CHAT_DISPLAY, 1);
    expect(metrics.inlineCodeSize).toBe(plain.inlineCodeSize);
    expect(metrics.blockCodeSize).toBe(plain.blockCodeSize);
    expect(metrics.codeLineHeight).toBe(plain.codeLineHeight);

    const prose = chatMetrics(
      resolveChatDisplay({ [PROSE_FAMILY_KEY]: "Folio Serif", [PROSE_WEIGHT_KEY]: 380, [PROSE_SCALE_KEY]: 1.2 }),
      1,
    );
    expect(prose.measureFont).toBe(`14px ${SYSTEM}`);
    // The prose family first (another test file's faces may mark it as a pack face after it).
    expect(prose.replyMeasureFont.startsWith('380 16.75px "Folio Serif", ')).toBe(true);
    expect(prose.replyMeasureFont.endsWith(SYSTEM)).toBe(true);
  });

  test("with none of the keys, the fonts measure as before", () => {
    const metrics = chatMetrics(resolveChatDisplay({ "agentPane.display.font.preset": "serif" }), 1);
    expect(metrics.measureFont).toBe('14px "New York", Georgia, serif');
    expect(metrics.replyMeasureFont).toBe(metrics.measureFont);
    expect(metrics.replyLineHeight).toBe(metrics.lineHeight);
    expect(metrics.replyFontSize).toBe(14);
  });

  test("a scale grows reply rows only; the prompt above keeps its height", () => {
    const rows = [
      { id: "prompt", version: 1, at: 0, kind: "user", text: "Why does the retry test fail on CI?" },
      {
        id: "reply",
        version: 1,
        at: 1,
        kind: "assistant",
        text: "Real timers.\n\nThe third attempt lands after the assertion on a loaded runner.\n\n- fake timers now\n- 3 runs",
      },
    ] as never;
    const measure = (values: Record<string, unknown>) => {
      setChatDisplay(values);
      return layoutConversation(rows, 720, new Map());
    };
    const before = measure({});
    const after = measure(CLAUDE_LOOK);
    expect(after.heights[0]).toBe(before.heights[0]);
    expect(after.heights[1]).toBeGreaterThan(before.heights[1]);
    // Back to no keys: the same heights as before, so removing a pack moves nothing.
    const again = measure({});
    expect(Array.from(again.heights)).toEqual(Array.from(before.heights));
  });
});
