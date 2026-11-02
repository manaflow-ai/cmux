// A `repo#N` reference that a reply hard-wraps at its `#` (Leo 2026-10-31, on "the sent-message
// cards (cmux#\n29613) and the bottom-gap fix": "WTF HAPPENED WITH THIS" / "F***ING TEXT????").
// The next line's "29613)" read as an ordered list's number; the reply now stays one paragraph that
// names cmux#29613 whole. The Chromium layout check is markdown-reference-wrap-browser.test.tsx.
import { describe, expect, test } from "bun:test";
import { parseMarkdown } from "../src/agent-session/acpmux/conversation/Markdown";

const REPLY =
  "Several fixes are stuck on that: the sent-message cards (cmux#\n" +
  "29613) and the bottom-gap fix (cmux#28905), with the model picker likely next.";

describe("a reference wrapped at its # stays text", () => {
  test("one paragraph that names cmux#29613 whole", () => {
    const blocks = parseMarkdown(REPLY);
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ type: "paragraph" });
    expect((blocks[0] as { text: string }).text).toContain("(cmux#29613) and");
  });
  test("a numbered line other than 1 never starts a list inside a paragraph", () => {
    expect(parseMarkdown("the total was\n2026. A good year").map((block) => block.type)).toEqual(["paragraph"]);
    expect(parseMarkdown("steps:\n1. one\n2. two").map((block) => block.type)).toEqual(["paragraph", "list"]);
    expect(parseMarkdown("2026. A list may start anywhere\n2027. after a blank").map((b) => b.type)).toEqual(["list"]);
  });
  test("a bare `#` at a line's end keeps its break", () => {
    expect((parseMarkdown("see issue #\n12 more")[0] as { text: string }).text).toBe("see issue #\n12 more");
  });
});
