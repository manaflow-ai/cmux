// l10n-allow-file: synthetic transcript fixtures.
// Guards that a transcript look never shifts the chat it does not mean to (conversation/transcriptLook.ts;
// Leo, 2026-11-18: "make sure stuff is faithful + doesn't shift"). The row estimator (model.ts
// layoutConversation) lays one fixture out at the cmux look and at each change:
//   - a paint-only token (fill, radius, border, timestamps, toolCards, align, card and code radius,
//     and the tool rows' and outputs' type)
//     leaves every row's top and height identical, at cmux and on top of each named look;
//   - a layout token moves rows only by its formula: rowSpacing/density scale every gap and move no
//     height; bubble padding moves only prompt rows, by its delta; maxWidth only prompt rows;
//   - every look's tops are its heights and gaps summed, its gaps the cmux gaps times its gap scale.
import { afterAll, describe, expect, test } from "bun:test";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { layoutConversation, type AcpmuxRow, type ConversationLayout } from "../src/agent-session/acpmux/model";
import { tool } from "../src/gallery/fixtures/acpmux";
import {
  gapScaleOf,
  resolveTranscriptLook,
  TRANSCRIPT_LOOK_KEY,
  TRANSCRIPT_LOOKS,
  TRANSCRIPT_TOKENS_KEY,
} from "../src/agent-session/acpmux/conversation/transcriptLook";

let id = 0;
const row = (kind: string, text: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id: `r${(id += 1)}`, kind, text, at: 0, version: 1, ...fields }) as AcpmuxRow;

const ROWS: AcpmuxRow[] = [
  row("user", "Add retries with backoff to the fetch helper, and make sure POSTs never retry on their own"),
  row("activity", "", {
    items: [tool("Read src/net/client.ts", "read", "completed"), tool("Edit src/net/retry.ts", "edit", "completed")],
    toolCount: 2,
  } as Partial<AcpmuxRow>),
  row(
    "assistant",
    "The fetch helper now retries transient failures with exponential backoff and full jitter.\n\n```ts\nexport const x = 1;\n```",
  ),
  row("turnSummary", "", { status: "completed", durationMs: 48_000, toolCount: 2 } as Partial<AcpmuxRow>),
  row("user", "Great. Now log each retry with its attempt number, and keep the log line short enough to read"),
  row("assistant", "Done: every retry logs its attempt."),
];
const USER = ROWS.map((value) => value.kind === "user");
const WIDTH = 720;

const layoutAt = (display: Record<string, unknown>): ConversationLayout => {
  setChatDisplay(display);
  return layoutConversation(ROWS, WIDTH, new Map());
};
const look = (name: string, tokens?: Record<string, unknown>) => ({
  [TRANSCRIPT_LOOK_KEY]: name,
  ...(tokens ? { [TRANSCRIPT_TOKENS_KEY]: tokens } : {}),
});
const gapsOf = (layout: ConversationLayout) => Array.from(layout.gaps ?? new Float64Array(ROWS.length));

afterAll(() => setChatDisplay({}));

/// Tops are the heights and gaps summed, from the first row's top.
const expectConsistent = (layout: ConversationLayout) => {
  const gaps = gapsOf(layout);
  for (let index = 1; index < ROWS.length; index += 1) {
    if (layout.heights[index] === 0) continue;
    let previous = index - 1;
    while (previous >= 0 && layout.heights[previous] === 0) previous -= 1;
    if (previous < 0) continue;
    expect(layout.tops[index]!).toBeCloseTo(layout.tops[previous]! + layout.heights[previous]! + gaps[index]!, 6);
  }
};
const expectSame = (a: ConversationLayout, b: ConversationLayout) => {
  expect(Array.from(b.heights)).toEqual(Array.from(a.heights));
  expect(Array.from(b.tops)).toEqual(Array.from(a.tops));
  expect(b.totalHeight).toBe(a.totalHeight);
};

const PAINT_ONLY: Record<string, unknown>[] = [
  { "userMessage.fill": 0.25 },
  { "userMessage.fill": 0 },
  { "userMessage.radius": 0 },
  { "userMessage.radius": 28 },
  { "userMessage.align": "left" },
  { "toolCard.border": "none" },
  { "toolCard.radius": 20 },
  { "codeCard.radius": 0 },
  { timestamps: "always" },
  { timestamps: "off" },
  { toolCards: "card" },
  { toolCards: "minimal" },
  // Tool row type: a row's words sit on its fixed line at any size the token allows; the output's
  // type moves only an opened call's body, measured once drawn, never a row the estimator places.
  { "toolRow.textSize": 0.75 },
  { "toolRow.textSize": 1 },
  { "toolRow.weight": 300 },
  { "toolRow.weight": 700 },
  { "toolRow.font": "mono" },
  { "toolRow.commandFont": "mono" },
  { "toolOutput.textSize": 0.7 },
  { "toolOutput.textSize": 1 },
  { "toolOutput.font": "text" },
];

describe("transcript looks never shift what they only paint", () => {
  const base = layoutAt({});

  test("the fixture lays out with rows, gaps and consistent tops", () => {
    expect(base.heights.every((height) => height >= 0)).toBe(true);
    expect(gapsOf(base).some((gap) => gap > 0)).toBe(true);
    expectConsistent(base);
    // The cmux look by name is the chat with no key.
    expectSame(base, layoutAt(look("cmux")));
  });

  test("a paint-only token moves no row, at cmux and on each look (a hot reload of one token)", () => {
    for (const name of TRANSCRIPT_LOOKS.map((value) => value.name)) {
      const before = layoutAt(look(name));
      for (const tokens of PAINT_ONLY) expectSame(before, layoutAt(look(name, tokens)));
    }
  });

  test("row spacing and density scale the gaps and nothing else", () => {
    for (const tokens of [{ rowSpacing: 1.5 }, { density: "compact" }, { density: "comfortable", rowSpacing: 0.5 }]) {
      const factor = gapScaleOf(resolveTranscriptLook(look("cmux", tokens)));
      const moved = layoutAt(look("cmux", tokens));
      expect(Array.from(moved.heights)).toEqual(Array.from(base.heights));
      gapsOf(moved).forEach((gap, index) => expect(gap).toBeCloseTo(gapsOf(base)[index]! * factor, 6));
      expectConsistent(moved);
    }
  });

  test("bubble padding moves only prompt rows, by twice its delta", () => {
    const moved = layoutAt(look("cmux", { "userMessage.paddingBlock": 14 }));
    ROWS.forEach((_, index) =>
      expect(moved.heights[index]!).toBeCloseTo(base.heights[index]! + (USER[index] ? 2 * (14 - 10) : 0), 6),
    );
    expect(gapsOf(moved)).toEqual(gapsOf(base));
    expectConsistent(moved);
  });

  test("the bubble's share and side padding move only prompt rows", () => {
    for (const tokens of [
      { "userMessage.maxWidth": 0.4 },
      { "userMessage.paddingInline": 24 },
      { "userMessage.style": "plain" },
    ]) {
      const moved = layoutAt(look("cmux", tokens));
      ROWS.forEach((_, index) => {
        if (!USER[index]) expect(moved.heights[index]).toBe(base.heights[index]!);
      });
      expect(gapsOf(moved)).toEqual(gapsOf(base));
      expectConsistent(moved);
    }
  });

  test("each look's gaps are the cmux gaps times its gap scale, its tops their sum", () => {
    for (const spec of TRANSCRIPT_LOOKS) {
      const factor = gapScaleOf(resolveTranscriptLook(look(spec.name)));
      const laid = layoutAt(look(spec.name));
      gapsOf(laid).forEach((gap, index) => expect(gap).toBeCloseTo(gapsOf(base)[index]! * factor, 6));
      expectConsistent(laid);
    }
  });
});
