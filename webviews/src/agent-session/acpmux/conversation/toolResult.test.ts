// l10n-allow-file: test fixtures.
// A tool call's result without the JSON envelope a harness wrapped it in (toolResult.ts): each
// envelope shape unwraps to its text, images or structured content; JSON a tool really returned
// stays JSON.
import { expect, test } from "bun:test";
import { envelopeImages, toolResult } from "./toolResult";
import { prettyOutput } from "./mcpCalls";
import { toolImages } from "../toolImages";

const PNG = "iVBORw0KGgo=";

test("an MCP content block list unwraps to its text", () => {
  const result = toolResult(JSON.stringify([{ type: "text", text: "Deployed to staging." }]));
  expect(result).toEqual({ text: "Deployed to staging.", lang: "text", images: [], unwrapped: true });
});

test("ACP content wrappers unwrap too", () => {
  const result = toolResult(JSON.stringify([{ type: "content", content: { type: "text", text: "ok" } }]));
  expect(result.text).toBe("ok");
});

test("an MCP CallToolResult unwraps to its texts, joined as paragraphs", () => {
  const output = JSON.stringify({
    content: [
      { type: "text", text: "First" },
      { type: "text", text: "Second" },
    ],
    isError: false,
  });
  expect(toolResult(output).text).toBe("First\n\nSecond");
});

test("a CallToolResult with no text shows its structured content, pretty-printed", () => {
  const output = JSON.stringify({ content: [], structuredContent: { workspace: "ws_1", ok: true } });
  const result = toolResult(output);
  expect(result.lang).toBe("json");
  expect(result.text).toBe('{\n  "workspace": "ws_1",\n  "ok": true\n}');
  expect(result.unwrapped).toBe(true);
});

test("a result envelope unwraps to the result inside it", () => {
  const output = JSON.stringify({
    error: null,
    result: {
      _meta: null,
      content: [{ type: "text", text: "Tool call rejected by review." }],
      structuredContent: null,
    },
  });
  expect(toolResult(output).text).toBe("Tool call rejected by review.");
});

test("a result envelope's error shows its message", () => {
  const output = JSON.stringify({ result: null, error: { code: -32000, message: "Server unreachable" } });
  expect(toolResult(output).text).toBe("Server unreachable");
});

test("Codex's function call output unwraps to its output", () => {
  const output = JSON.stringify({ output: "3 pass\n0 fail\n", metadata: { exit_code: 0, duration_seconds: 0.4 } });
  expect(toolResult(output)).toEqual({ text: "3 pass\n0 fail", lang: "text", images: [], unwrapped: true });
});

test("JSON text inside an envelope is parsed and pretty-printed, not shown as one line", () => {
  const inner = { thread: { id: "t1", title: "Coordination hub" } };
  const result = toolResult(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(inner) }] }));
  expect(result.lang).toBe("json");
  expect(result.text).toBe(JSON.stringify(inner, null, 2));
});

test("an envelope inside an envelope's text is peeled too", () => {
  const inner = JSON.stringify([{ type: "text", text: "Inner text" }]);
  expect(toolResult(JSON.stringify({ result: { content: [{ type: "text", text: inner }] } })).text).toBe("Inner text");
});

test("Markdown text inside an envelope reads as Markdown", () => {
  const text = "## Open issues\n\n- #12 Crash on launch\n- #14 Slow scroll";
  expect(toolResult(JSON.stringify([{ type: "text", text }]))).toMatchObject({ text, lang: "markdown" });
});

test("image and resource blocks unwrap to images and their text", () => {
  const output = JSON.stringify({
    content: [
      { type: "image", data: PNG, mimeType: "image/png" },
      { type: "resource", resource: { uri: "file:///notes.md", text: "Notes body" } },
      { type: "resource_link", uri: "https://example.com/a", name: "Report" },
    ],
  });
  const result = toolResult(output);
  expect(result.images).toEqual([`data:image/png;base64,${PNG}`]);
  expect(result.text).toBe("Notes body\n\nReport: https://example.com/a");
  expect(envelopeImages(output)).toEqual([`data:image/png;base64,${PNG}`]);
});

test("a call's envelope images show in its image strip", () => {
  const output = JSON.stringify([{ type: "image", data: PNG, mimeType: "image/png" }]);
  expect(toolImages({ id: "c1", title: "mcp__shots__take", status: "completed", output })).toEqual([
    `data:image/png;base64,${PNG}`,
  ]);
});

test("a JSON file a tool read stays a JSON code block, as it was printed", () => {
  const file = '{\n  "name": "@cmux/webviews",\n  "private": true,\n  "scripts": { "test": "bun test" }\n}\n';
  expect(toolResult(file)).toEqual({ text: file.trimEnd(), lang: "json", images: [], unwrapped: false });
});

test("a JSON object printed on one line is pretty-printed", () => {
  const output = JSON.stringify({ message: "Successfully stopped task: b5m", task_id: "b5m", task_type: "local_bash" });
  const result = toolResult(output);
  expect(result.lang).toBe("json");
  expect(result.text.split("\n")).toHaveLength(5);
});

test("an object that only looks like an envelope stays JSON", () => {
  const output = JSON.stringify({ content: "plain string", author: "leo" });
  expect(toolResult(output).lang).toBe("json");
  const blocks = JSON.stringify([{ type: "user", name: "Leo" }]);
  expect(toolResult(blocks).lang).toBe("json");
});

test("plain text stays as it is", () => {
  expect(toolResult("Updated 3 files")).toEqual({
    text: "Updated 3 files",
    lang: "text",
    images: [],
    unwrapped: false,
  });
  expect(toolResult("{ not json").lang).toBe("text");
});

test("an MCP response under a result envelope unwraps in the opened MCP call", () => {
  const output = JSON.stringify({ error: null, result: { content: [{ type: "text", text: "Rejected" }] } });
  expect(prettyOutput(output)).toBe("Rejected");
  const structured = JSON.stringify({ content: [{ type: "text", text: "" }], structuredContent: { ok: true } });
  expect(prettyOutput(structured)).toBe('{\n  "ok": true\n}');
});
