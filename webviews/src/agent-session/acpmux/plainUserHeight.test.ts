// l10n-allow-file: synthetic prompt fixtures, not shipped UI.
import { afterEach, expect, spyOn, test } from "bun:test";
import * as marked from "marked";
import { currentChatMetrics, setChatDisplay } from "./chatDisplay";
import { COLLAPSED_PROMPT_LINES, PROMPT_MORE_HEIGHT } from "./conversation/promptCollapse";
import { layoutConversation, type AcpmuxRow } from "./model";

const text = "Describe this synthetic onboarding fixture";
const long = "A long ordinary prompt about a session and its next sensible step. ".repeat(8).trim();
const unicode = "Réponds en français et explique la prochaine étape.";
const prompt = (value: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "prompt",
  version: 1,
  at: 0,
  kind: "user",
  text: value,
  ...extra,
});
const height = (row: AcpmuxRow, width: number) => layoutConversation([row], width).heights[0];

afterEach(() => setChatDisplay({}));

// First-layout estimates include text wrapping and collapse controls. Codex keeps 10px of
// block padding on each side of the bubble, including when the reading font changes.
// Meta controls and the outer gaps belong to the virtual stack, not this content height.
const FOLDED = -1;
const folded = () => {
  const { lineHeight } = currentChatMetrics();
  return 20 + COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT;
};
for (const [font, expected] of [
  [
    14,
    [
      [65.5, FOLDED, 88.25],
      [42.75, 247.5, 42.75],
      [42.75, 133.75, 42.75],
    ],
  ],
  [
    20,
    [
      [85, FOLDED, 117.5],
      [52.5, 345, 52.5],
      [52.5, 182.5, 52.5],
    ],
  ],
] as const) {
  test(`plain prompt estimates keep wrapping and collapse geometry at font ${font}`, () => {
    setChatDisplay({ "agentPane.display.font.size": font });
    [320, 720, 1400].forEach((width, index) => {
      [text, long, unicode].forEach((value, sample) => {
        const want = expected[index]![sample]!;
        expect(height(prompt(value), width)).toBeCloseTo(want === FOLDED ? folded() : want, 5);
      });
    });
  });
}

test("a cold plain user prompt is placed without initializing the Markdown parser", () => {
  const lexer = spyOn(marked, "lexer");
  try {
    for (const width of [320, 720, 1400]) height(prompt(text), width);
    expect(lexer).not.toHaveBeenCalled();
  } finally {
    lexer.mockRestore();
  }
});

test("Markdown-looking, multiline, attachment and Chief paths retain their parser", () => {
  const lexer = spyOn(marked, "lexer");
  try {
    const rows = [
      prompt("> quoted passage"),
      prompt("---"),
      prompt("----"),
      prompt("--- ---"),
      prompt("1. ordered item"),
      prompt("**bold** and `code`"),
      prompt("First paragraph\n\nSecond paragraph"),
      prompt("A &amp; B"),
      prompt("A [link](https://example.com)"),
      prompt("A plain question", { from: "chief" }),
      prompt(text, { images: [{ id: "image", mimeType: "image/png" }] }),
      prompt(text, { retryAttachments: [{ id: "file", name: "note.txt", mimeType: "text/plain", size: 12 }] as never }),
    ];
    for (const row of rows) {
      lexer.mockClear();
      height(row, 720);
      expect(lexer).toHaveBeenCalled();
    }
  } finally {
    lexer.mockRestore();
  }
});

test("thematic breaks keep the same padding at different reading sizes", () => {
  for (const font of [14, 20, 28]) {
    setChatDisplay({ "agentPane.display.font.size": font });
    for (const text of ["---", "----", "--- ---"]) expect(height(prompt(text), 720)).toBe(22);
  }
});

test("a large reading font retains the bubble padding before measurement", () => {
  setChatDisplay({ "agentPane.display.font.size": 28 });
  expect(height(prompt("Short"), 720)).toBeCloseTo(65.5, 5);
});

test("plain height follows width and font changes without stale placement", () => {
  const cache = new Map();
  const row = prompt(long);
  const estimate = (width: number) => layoutConversation([row], width, cache).heights[0]!;
  setChatDisplay({ "agentPane.display.font.size": 14 });
  const narrow = estimate(320);
  const wide = estimate(1400);
  expect(wide).toBeLessThan(narrow);
  setChatDisplay({ "agentPane.display.font.size": 20 });
  const larger = estimate(1400);
  expect(larger).toBeGreaterThan(wide);
  // A repeated layout at the same metrics remains stable for the rows below it.
  expect(estimate(1400)).toBe(larger);
});
