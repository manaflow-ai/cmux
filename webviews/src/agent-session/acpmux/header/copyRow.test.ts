import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { conversationMarkdown } from "./copyRow";

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
});
