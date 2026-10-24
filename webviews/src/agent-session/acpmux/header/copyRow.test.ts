import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { conversationMarkdown, copyRow } from "./copyRow";

describe("conversationMarkdown", () => {
  test("uses role headings and folds tool calls to short lines", () => {
    const rows: AcpmuxRow[] = [
      { id: "u", version: 1, at: 1, kind: "user", text: "Please inspect the file" },
      {
        id: "a",
        version: 1,
        at: 2,
        kind: "assistant",
        text: "I will inspect it.",
        items: [
          {
            kind: "tool",
            text: "Read package.json",
            tool: { id: "t", title: "Read package.json", kind: "read", status: "completed", output: "secret" },
          },
        ],
      },
    ];

    expect(conversationMarkdown(rows)).toBe(
      "**User:**\nPlease inspect the file\n\n**Assistant:**\nI will inspect it.\n\n- Tool: Read package.json",
    );
  });

  test("bounds folded tool titles and never copies tool output", () => {
    const title = "Read " + "a".repeat(300);
    const rows: AcpmuxRow[] = [
      {
        id: "a",
        version: 1,
        at: 1,
        kind: "assistant",
        items: [{ kind: "tool", text: title, tool: { id: "t", title, status: "completed", output: "secret output" } }],
      },
    ];
    const copied = conversationMarkdown(rows);
    expect(copied.length).toBeLessThan(180);
    expect(copied).not.toContain("secret output");
    expect(copied.endsWith("…")).toBe(true);
  });

  test("skips hidden blank bookkeeping and only labels an empty prompt with images", () => {
    const rows: AcpmuxRow[] = [
      { id: "hidden", version: 1, at: 1, kind: "user", text: "", incoming: { kind: "hidden" } },
      { id: "blank", version: 1, at: 2, kind: "user", text: "" },
      { id: "image", version: 1, at: 3, kind: "user", text: "", images: [{ id: "i", mimeType: "image/png" }] },
    ];
    expect(conversationMarkdown(rows)).toBe("**User:**\n(attachment)");
  });

  test("header Markdown selection can use the complete-history bridge", async () => {
    let copied = "";
    const menu = copyRow(
      {
        link: undefined,
        sessionId: "chat-1",
        rows: [
          { id: "u", version: 1, at: 1, kind: "user", text: "loaded" },
          { id: "a", version: 1, at: 2, kind: "assistant", text: "answer" },
        ],
      },
      (text) => {
        copied = text;
      },
      undefined,
      async () => "**User:**\nolder and loaded",
    );
    const markdown = menu?.children?.find((child) => child.key === "copyMarkdown");
    markdown?.onSelect?.();
    await Promise.resolve();
    await Promise.resolve();
    expect(copied).toBe("**User:**\nolder and loaded");
  });
});
