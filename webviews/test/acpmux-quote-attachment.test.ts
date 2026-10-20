import { describe, expect, test } from "bun:test";
import { quoteAttachment } from "../src/agent-session/acpmux/quoteAttachment";

// The app's `quote` host event becomes a text chip in the agent chat's composer (viewer-comments-DESIGN.md).
describe("quoteAttachment", () => {
  test("a quote is a text chip named by its title holding its Markdown", () => {
    const markdown = "> **README.md · L3–4**\n> hello\n\nWhy?";
    expect(quoteAttachment({ id: "q1", title: "README.md · L3–4", markdown })).toEqual({
      id: "quote-q1",
      kind: "text",
      name: "README.md · L3–4",
      mimeType: "text/markdown",
      size: markdown.length,
      text: markdown,
    });
  });

  test("an empty or malformed quote is no chip", () => {
    expect(quoteAttachment({ id: "q1", title: "a", markdown: "  " })).toBeUndefined();
    expect(quoteAttachment(null)).toBeUndefined();
    expect(quoteAttachment({ title: "a", markdown: "b" })).toBeUndefined();
  });
});
