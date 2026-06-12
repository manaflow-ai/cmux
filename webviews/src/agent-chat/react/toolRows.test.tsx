// Server-render smoke tests for the rich tool rows: each item family renders
// its structured view (diff lines, prompt line + exit badge, file preview,
// search links) instead of raw JSON, and unknown shapes fall back to the
// generic expandable row. Static markup is enough here; interaction state
// (expand/collapse) stays local and is not under test.

import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { ConversationItem } from "../protocol";
import { RichToolRow } from "./toolRows";

function render(item: ConversationItem): string {
  return renderToStaticMarkup(<RichToolRow item={item} />);
}

describe("RichToolRow", () => {
  test("file_change with Edit input renders diff lines and the path", () => {
    const html = render({
      id: "t1",
      type: "file_change",
      status: "completed",
      tool_name: "Edit",
      input: {
        file_path: "/repo/src/app.ts",
        old_string: "const a = 1;",
        new_string: "const a = 2;",
      },
    });
    expect(html).toContain("agent-chat-diff-line is-del");
    expect(html).toContain("agent-chat-diff-line is-add");
    expect(html).toContain("/repo/src/app.ts");
    expect(html).toContain("const a = 2;");
    expect(html).not.toContain("old_string");
  });

  test("file_change with apply_patch input renders one section per file", () => {
    const html = render({
      id: "t2",
      type: "file_change",
      status: "completed",
      tool_name: "apply_patch",
      input: "*** Begin Patch\n*** Add File: a.txt\n+hello\n*** End Patch",
    });
    expect(html).toContain("a.txt");
    expect(html).toContain("agent-chat-op-badge is-create");
    expect(html).toContain("hello");
  });

  test("file_change with unknown input falls back to the generic row", () => {
    const html = render({
      id: "t3",
      type: "file_change",
      status: "in_progress",
      tool_name: "Edit",
      title: "src/sparse.ts",
    });
    expect(html).toContain("agent-chat-disclosure");
    expect(html).toContain("src/sparse.ts");
    expect(html).not.toContain("agent-chat-diff-line");
  });

  test("command_execution renders the exit badge in the summary", () => {
    const html = render({
      id: "t4",
      type: "command_execution",
      status: "completed",
      tool_name: "shell",
      input: { command: ["bash", "-lc", "ls"] },
      output: {
        text: JSON.stringify({
          output: "file.txt",
          metadata: { exit_code: 1, duration_seconds: 2.5 },
        }),
      },
    });
    expect(html).toContain("agent-chat-exit-badge is-failure");
    expect(html).toContain("exit 1");
    expect(html).toContain("2.5s");
    expect(html).toContain("ls");
  });

  test("dynamic_tool_call Read renders the path, not raw JSON input", () => {
    const html = render({
      id: "t5",
      type: "dynamic_tool_call",
      status: "completed",
      tool_name: "Read",
      input: { file_path: "/repo/notes.md" },
      output: { text: "# Notes" },
    });
    expect(html).toContain("/repo/notes.md");
    expect(html).not.toContain("file_path");
  });

  test("web_search summary shows the query", () => {
    const html = render({
      id: "t6",
      type: "web_search",
      status: "completed",
      tool_name: "WebSearch",
      input: { query: "bun test runner" },
      output: {
        text: '[{"title": "Bun docs", "url": "https://bun.sh/docs/test"}]',
      },
    });
    expect(html).toContain("bun test runner");
  });

  test("mcp_tool_call keeps the generic expandable row", () => {
    const html = render({
      id: "t7",
      type: "mcp_tool_call",
      status: "failed",
      tool_name: "mcp__browser__screenshot",
      title: "browser_screenshot",
      input: { url: "http://localhost:5173" },
      output: { text: "Error: no browser session connected", is_error: true },
    });
    expect(html).toContain("agent-chat-disclosure");
    expect(html).toContain("browser_screenshot");
  });
});
