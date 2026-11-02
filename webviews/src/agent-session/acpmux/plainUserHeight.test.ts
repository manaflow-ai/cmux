// l10n-allow-file: synthetic prompt fixtures, not shipped UI.
import { afterEach, expect, spyOn, test } from "bun:test";
import * as marked from "marked";
import { setChatDisplay } from "./chatDisplay";
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

// These are the first-layout estimates, including wrapping, collapse chrome and the user's font
// size. A performance repair must not move the next row before the DOM measures it. On the layout
// grid a row's height is its content alone: "A gap belongs to its container" (leo-workspace
// design/grid.md Rule 5), so #27580 (044769ae) took the prompt's meta gap, meta row and message gap
// (4 + 24 + 8 = 36) out of the row, and the stack places the turn gap (transcriptGrid.ts
// transcriptGap). Every estimate here is 36 under its pre-grid value.
for (const [font, expected] of [
  [
    14,
    [
      [61.5, 267.5, 84.25],
      [38.75, 243.5, 38.75],
      [38.75, 129.75, 38.75],
    ],
  ],
  [
    20,
    [
      [81, 365, 113.5],
      [48.5, 341, 48.5],
      [48.5, 178.5, 48.5],
    ],
  ],
] as const) {
  test(`plain prompt estimates keep wrapping and collapse geometry at font ${font}`, () => {
    setChatDisplay({ "agentPane.display.font.size": font });
    [320, 720, 1400].forEach((width, index) => {
      [text, long, unicode].forEach((value, sample) => {
        expect(height(prompt(value), width)).toBeCloseTo(expected[index]![sample]!, 5);
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

// The rule's parser-backed height, without the 36 of row chrome #27580 moved to the stack's gap.
test("hyphen thematic breaks keep their original parser-backed height", () => {
  for (const font of [14, 20]) {
    setChatDisplay({ "agentPane.display.font.size": font });
    for (const text of ["---", "----", "--- ---"]) expect(height(prompt(text), 720)).toBe(18);
  }
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
