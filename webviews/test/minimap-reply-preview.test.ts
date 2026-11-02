import { expect, test } from "bun:test";
import { type ReplyBlock, replyPreview } from "../src/agent-session/acpmux/threadMinimap/model";

// The minimap previews the live turn's reply again on every streamed token. replyPreview stops
// reading once its preview is full, so what follows a full preview never changes the result
// (and is never read), and short replies preview exactly as before.

const fixtures = [
  "",
  "\n",
  "One line",
  "Para one\nstill para one\n\nPara two",
  "# Heading\n\n- item one\n- item two\n\n1. numbered\n\n> quoted\n> more",
  "```ts\nconst hidden = 1;\n```\nAfter the fence with **bold** and `code` and [a link](https://x.y).",
  "---\n| table | row |\n|---|---|\n\nText after table\n~~~\nfenced\n~~~\nend",
  "trailing newline\n\n",
  "x".repeat(500),
  "a\n\nb\n\nc\n\nd\n\ne\n\nf",
];

/// What the previous implementation (split the whole reply into lines, read every line) returned
/// for each fixture, with inline code now kept as a code span rather than flattened into prose.
const expected: ReplyBlock[][] = [
  [],
  [],
  [{ kind: "paragraph", spans: [{ text: "One line", bold: false }] }],
  [
    { kind: "paragraph", spans: [{ text: "Para one still para one", bold: false }] },
    { kind: "paragraph", spans: [{ text: "Para two", bold: false }] },
  ],
  [
    { kind: "paragraph", spans: [{ text: "Heading", bold: false }] },
    { kind: "item", spans: [{ text: "item one", bold: false }] },
    { kind: "item", spans: [{ text: "item two", bold: false }] },
    { kind: "item", spans: [{ text: "numbered", bold: false }] },
  ],
  [
    {
      kind: "paragraph",
      spans: [
        { text: "After the fence with ", bold: false },
        { text: "bold", bold: true },
        { text: " and ", bold: false },
        { text: "code", bold: false, code: true },
        { text: " and a link.", bold: false },
      ],
    },
  ],
  [
    { kind: "paragraph", spans: [{ text: "Text after table", bold: false }] },
    { kind: "paragraph", spans: [{ text: "end", bold: false }] },
  ],
  [{ kind: "paragraph", spans: [{ text: "trailing newline", bold: false }] }],
  [
    {
      kind: "paragraph",
      spans: [
        {
          text: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
          bold: false,
        },
      ],
    },
  ],
  [
    { kind: "paragraph", spans: [{ text: "a", bold: false }] },
    { kind: "paragraph", spans: [{ text: "b", bold: false }] },
    { kind: "paragraph", spans: [{ text: "c", bold: false }] },
    { kind: "paragraph", spans: [{ text: "d", bold: false }] },
  ],
];

for (const [index, fixture] of fixtures.entries()) {
  test(`replyPreview matches the whole-reply reading for fixture ${index}`, () => {
    expect(replyPreview(fixture)).toEqual(expected[index]);
  });
}

test("a full preview ignores everything after it", () => {
  const head = "First paragraph.\n\n- one\n- two\n- three\n\nMore";
  const preview = replyPreview(head);
  expect(preview.length).toBe(4);
  const tail = "\n\n" + "A later paragraph that streams in.\n\n".repeat(50_000);
  expect(replyPreview(head + tail)).toEqual(preview);
});

test("a preview full by length ignores the rest", () => {
  const head = "y".repeat(400);
  const preview = replyPreview(head);
  expect(replyPreview(`${head}\n\n${"z ".repeat(200_000)}`)).toEqual(preview);
});

test("a long reply's preview costs about as much as a short one's", () => {
  const short = "Intro.\n\n- a\n- b\n- c\n\nrest";
  const long = short + "\n\n" + "more text\n".repeat(200_000);
  const time = (text: string) => {
    const start = performance.now();
    for (let round = 0; round < 50; round++) replyPreview(text);
    return performance.now() - start;
  };
  time(long);
  // Splitting 200,000 lines on every call took tens of milliseconds a call; reading stops now.
  expect(time(long)).toBeLessThan(Math.max(50, time(short) * 50));
});
