// l10n-allow-file: synthetic transcript fixtures.
// The reply's and the prompt's own type in a transcript look (conversation/transcriptLook.ts `reply.font`,
// `reply.fontSize`, `userMessage.font`, `userMessage.fontSize`; chatDisplay.ts; conversation.css). The
// Claude app sets its replies in a serif reading face and your messages, in their filled bubble, in
// the sans; the Claude look does too:
//   - cmux (and no key) sets none of the new variables or attributes: today's chat;
//   - Claude draws replies in the system serif stack, prompts in the interface sans, each at its size;
//   - the person's own Agent Chat font or size wins over a look's value, their tokens over both;
//   - a part's face or size moves only that part's rows in the estimator, and the estimator measures
//     each with the same font and line the stylesheet draws.
import { afterAll, describe, expect, test } from "bun:test";
import {
  chatDisplayVariables,
  chatMetrics,
  chatPartAttributes,
  resolveChatDisplay,
  setChatDisplay,
} from "../src/agent-session/acpmux/chatDisplay";
import { layoutConversation, type AcpmuxRow, type ConversationLayout } from "../src/agent-session/acpmux/model";
import { TRANSCRIPT_LOOK_KEY, TRANSCRIPT_TOKENS_KEY } from "../src/agent-session/acpmux/conversation/transcriptLook";

const PART_VARIABLES = [
  "--cv-reply-font",
  "--cv-reply-tracking",
  "--cv-reply-font-size",
  "--cv-reply-line-height",
  "--cv-prompt-font",
  "--cv-prompt-tracking",
  "--cv-prompt-font-size",
  "--cv-prompt-line-height",
];
const SERIF = '"New York", ui-serif, "Iowan Old Style", Georgia, serif';
const look = (name: string, tokens?: Record<string, unknown>, own: Record<string, unknown> = {}) => ({
  [TRANSCRIPT_LOOK_KEY]: name,
  ...(tokens ? { [TRANSCRIPT_TOKENS_KEY]: tokens } : {}),
  ...own,
});

describe("a look's reply and prompt type", () => {
  test("cmux and no key set no part variable and no part attribute", () => {
    for (const raw of [{}, look("cmux"), look("codex"), look("studio")]) {
      const display = resolveChatDisplay(raw);
      const variables = chatDisplayVariables(display, 1);
      for (const name of PART_VARIABLES) expect(variables[name]).toBeNull();
      expect(Object.values(chatPartAttributes(display)).every((value) => value === null)).toBe(true);
      const metrics = chatMetrics(display, 1);
      expect(metrics.reply).toEqual({ measureFont: metrics.measureFont, lineHeight: metrics.lineHeight });
      expect(metrics.prompt).toEqual({ measureFont: metrics.measureFont, lineHeight: metrics.lineHeight });
    }
  });

  test("Claude: replies in the system serif at 16, prompts in the sans at 15, on its 1.4 line", () => {
    const display = resolveChatDisplay(look("claude"));
    expect([display.replyFont, display.replyFontSize, display.promptFont, display.promptFontSize]).toEqual([
      "serif",
      16,
      "system",
      15,
    ]);
    const variables = chatDisplayVariables(display, 1);
    expect(variables["--cv-reply-font"]).toBe(SERIF);
    expect(variables["--cv-reply-tracking"]).toBe("0px");
    expect(variables["--cv-reply-font-size"]).toBe("16px");
    expect(variables["--cv-reply-line-height"]).toBe(`${Math.round(16 * display.lineHeight * 100) / 100}px`);
    expect(variables["--cv-prompt-font"]).toBe("var(--font-ui)");
    expect(variables["--cv-prompt-tracking"]).toBeNull();
    expect(variables["--cv-prompt-font-size"]).toBe("15px");
    expect(chatPartAttributes(display)).toEqual({
      "data-transcript-reply-size": "",
      "data-transcript-prompt-font": "system",
      "data-transcript-prompt-size": "",
    });
    // The estimator measures what the stylesheet draws: a serif canvas font for replies.
    const metrics = chatMetrics(display, 1);
    expect(metrics.replyMeasureFont).toBe('16px "New York", Georgia, serif');
    expect(metrics.reply.lineHeight).toBe(Number.parseFloat(variables["--cv-reply-line-height"]!));
    expect(metrics.prompt.measureFont.startsWith("15px ")).toBe(true);
    expect(metrics.prompt.lineHeight).toBe(Number.parseFloat(variables["--cv-prompt-line-height"]!));
  });

  test("sizes follow the chat's density text scale, as the chat's own size does", () => {
    const variables = chatDisplayVariables(resolveChatDisplay(look("claude")), 1.25);
    expect(variables["--cv-reply-font-size"]).toBe("20px");
    expect(variables["--cv-prompt-font-size"]).toBe("18.75px");
  });

  test("the person's own font and size win over a look's; their tokens win over both", () => {
    const own = resolveChatDisplay(
      look("claude", undefined, { "agentPane.display.font.preset": "mono", "agentPane.display.font.size": 13 }),
    );
    expect([own.replyFont, own.replyFontSize, own.promptFont, own.promptFontSize]).toEqual([null, null, null, null]);
    const tokens = resolveChatDisplay(
      look(
        "claude",
        { "reply.font": "serif", "userMessage.fontSize": 17 },
        { "agentPane.display.font.preset": "mono", "agentPane.display.font.size": 13 },
      ),
    );
    expect([tokens.replyFont, tokens.replyFontSize, tokens.promptFont, tokens.promptFontSize]).toEqual([
      "serif",
      null,
      null,
      17,
    ]);
    // On cmux, a token alone sets its part.
    const cmux = resolveChatDisplay(look("cmux", { "reply.font": "mono", "reply.fontSize": 9 }));
    expect(cmux.replyFont).toBe("mono");
    expect(cmux.replyFontSize).toBeNull(); // 9 is out of range: dropped
  });

  test("a font pack's prose family stays first, the look's face behind it", () => {
    const display = resolveChatDisplay(look("claude", undefined, { "agentPane.display.font.proseFamily": "Literata" }));
    expect(chatDisplayVariables(display, 1)["--cv-reply-font"]).toBe(`"Literata", ${SERIF}`);
  });
});

let id = 0;
const row = (kind: string, text: string): AcpmuxRow =>
  ({ id: `p${(id += 1)}`, kind, text, at: 0, version: 1 }) as AcpmuxRow;
const ROWS: AcpmuxRow[] = [
  row("user", "Add retries with backoff to the fetch helper, and make sure POSTs never retry on their own"),
  row(
    "assistant",
    "The fetch helper now retries transient failures with exponential backoff and full jitter, and a POST retries only when it says it is safe to.",
  ),
  row("user", "Great. Now log each retry with its attempt number"),
  row("assistant", "Done: every retry logs its attempt."),
];
const layoutAt = (display: Record<string, unknown>): ConversationLayout => {
  setChatDisplay(display);
  return layoutConversation(ROWS, 720, new Map());
};
afterAll(() => setChatDisplay({}));

describe("a part's type moves only that part's rows", () => {
  test("reply tokens move only replies, prompt tokens only prompts", () => {
    const base = layoutAt({});
    const cases: [Record<string, unknown>, string][] = [
      [{ "reply.fontSize": 20 }, "assistant"],
      [{ "reply.font": "serif" }, "assistant"],
      [{ "userMessage.fontSize": 20 }, "user"],
      [{ "userMessage.font": "mono" }, "user"],
    ];
    for (const [tokens, kind] of cases) {
      const moved = layoutAt(look("cmux", tokens));
      ROWS.forEach((value, index) => {
        if (value.kind !== kind) expect(moved.heights[index]).toBe(base.heights[index]!);
      });
      expect(Array.from(moved.gaps ?? [])).toEqual(Array.from(base.gaps ?? []));
    }
    // A larger size grows its part's rows.
    const larger = layoutAt(look("cmux", { "reply.fontSize": 24, "userMessage.fontSize": 24 }));
    ROWS.forEach((_, index) => expect(larger.heights[index]!).toBeGreaterThan(base.heights[index]!));
  });
});
