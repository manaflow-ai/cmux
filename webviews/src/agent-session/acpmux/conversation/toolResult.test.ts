// l10n-allow-file: test fixtures.
// A tool call's result without the JSON envelope a harness wrapped it in (toolResult.ts): each
// envelope shape unwraps to its text; an envelope that says more than its text, and JSON a tool
// really returned, stay JSON.
import { expect, test } from "bun:test";
import { toolResult } from "./toolResult";
import { cleanText } from "./mcpCalls";
import { findMatches } from "./chatFind";
import type { AcpmuxRow } from "../model";

test("each envelope shape unwraps to its text", () => {
  const shapes = [
    [{ type: "text", text: "Done" }],
    [{ type: "content", content: { type: "text", text: "Done" } }],
    { type: "text", text: "Done" },
    { content: [{ type: "text", text: "Done" }], isError: false },
    { error: null, result: { _meta: null, content: [{ type: "text", text: "Done" }], structuredContent: null } },
    { result: "Done", error: null },
    { error: { code: -32000, message: "Done" } },
    { output: "Done\n", metadata: { exit_code: 0, duration_seconds: 0.4 } },
  ];
  for (const shape of shapes) expect(toolResult(JSON.stringify(shape))).toEqual({ text: "Done", lang: "text" });
  expect(
    toolResult(
      JSON.stringify([
        { type: "text", text: "A" },
        { type: "text", text: "B" },
      ]),
    ).text,
  ).toBe("A\n\nB");
});

test("envelopes inside envelopes and JSON text inside text unwrap too", () => {
  const inner = JSON.stringify([{ type: "text", text: "Inner" }]);
  expect(toolResult(JSON.stringify({ result: { content: [{ type: "text", text: inner }] } })).text).toBe("Inner");
  const data = { thread: { id: "t1" } };
  expect(toolResult(JSON.stringify([{ type: "text", text: JSON.stringify(data) }]))).toEqual({
    text: JSON.stringify(data, null, 2),
    lang: "json",
  });
});

test("Markdown text reads as Markdown", () => {
  const text = "## Open issues\n\n- **#12** Crash on launch";
  expect(toolResult(JSON.stringify([{ type: "text", text }]))).toEqual({ text, lang: "markdown" });
});

test("an envelope that says more than its text stays JSON, so nothing is lost", () => {
  const PNG = "iVBORw0KGgo=";
  const outputs = [
    [
      { type: "text", text: "Shot" },
      { type: "image", data: PNG, mimeType: "image/png" },
    ],
    { content: [{ type: "text", text: "Found" }], structuredContent: { id: 42 } },
    { error: { code: -32602, message: "Invalid params", data: { field: "path" } } },
    { error: { message: "Invalid request", status: "INVALID_ARGUMENT" } },
    [{ type: "resource_link", uri: "docs://a", name: "a", description: "About a" }],
    { content: [], isError: false },
    [{ type: "text", text: " " }],
  ];
  for (const value of outputs)
    expect(toolResult(JSON.stringify(value))).toEqual({ text: JSON.stringify(value, null, 2), lang: "json" });
});

test("a tool's own JSON that names a block type but not its shape stays JSON", () => {
  const notion = [{ type: "text", text: { content: "Hi" }, plain_text: "Hi" }];
  const lookalike = { content: "plain string", author: "leo" };
  for (const value of [notion, lookalike]) expect(toolResult(JSON.stringify(value)).lang).toBe("json");
});

test("a JSON file a tool read stays as printed, even when it looks like an envelope", () => {
  const files = [
    '{\n  "name": "@cmux/webviews",\n  "private": true\n}\n',
    '[\n  { "type": "text", "text": "hello" }\n]\n',
    '{\n  "jsonrpc": "2.0",\n  "id": 1,\n  "result": "ok"\n}',
  ];
  for (const file of files) {
    expect(toolResult(file)).toEqual({ text: file.trimEnd(), lang: "json" });
    // Read through an MCP tool, the file is the text inside the envelope, and stays as printed too.
    expect(toolResult(JSON.stringify([{ type: "text", text: file }]))).toEqual({ text: file.trimEnd(), lang: "json" });
  }
});

test("one-line JSON is indented, its strings left as strings", () => {
  const value = { message: "Stopped task b5m", task_id: "b5m", payload: "[1,2]" };
  expect(toolResult(JSON.stringify(value))).toEqual({ text: JSON.stringify(value, null, 2), lang: "json" });
});

test("JSON a double would change shows as printed, never rounded", () => {
  for (const output of [
    '{"id":9007199254740993}',
    '{"value":10.000000000000001}',
    '{"value":1e400}',
    '{"value":-0}',
    '{"value":-0.0}',
  ]) {
    expect(toolResult(output)).toEqual({ text: output, lang: "json" });
    expect(toolResult(JSON.stringify([{ type: "text", text: output }]))).toEqual({ text: output, lang: "json" });
  }
  // Spellings of a value a double holds exactly still indent.
  expect(toolResult('{"a":1.50,"b":15e-1,"c":1e21}').text).toBe('{\n  "a": 1.5,\n  "b": 1.5,\n  "c": 1e+21\n}');
});

test("deeply nested JSON shows as printed instead of indenting level by level", () => {
  let value: unknown = "deep";
  for (let i = 0; i < 5000; i++) value = { result: value };
  const output = JSON.stringify(value);
  expect(toolResult(output)).toEqual({ text: output, lang: "json" });
  let block: unknown = { type: "text", text: "deep" };
  for (let i = 0; i < 5000; i++) block = { type: "content", content: block };
  expect(toolResult(JSON.stringify([block])).lang).toBe("json");
});

test("plain text stays as it is, and context a host injected is dropped once unwrapped", () => {
  expect(toolResult("Updated 3 files")).toEqual({ text: "Updated 3 files", lang: "text" });
  expect(toolResult("{ not json").lang).toBe("text");
  const text = "<system-reminder>internal</system-reminder>\nThe result";
  expect(toolResult(JSON.stringify([{ type: "text", text }]), cleanText).text).toBe("The result");
});

test("Find in Chat reads what the opened call draws", () => {
  const row = (output: string): AcpmuxRow => ({
    id: "work",
    version: 1,
    at: 0,
    kind: "activity",
    text: "",
    items: [{ kind: "tool", text: "Lookup", tool: { id: "c1", title: "Lookup", status: "completed", output } }],
  });
  const plain = row(JSON.stringify([{ type: "text", text: 'Said "some text"' }]));
  expect(findMatches([plain], "text")).toHaveLength(1);
  expect(findMatches([plain], '"some')).toHaveLength(1);
  const markdown = row(
    JSON.stringify([{ type: "text", text: "## Status\n\n**critical** failure, [log](https://example.com/x)" }]),
  );
  expect(findMatches([markdown], "critical failure")).toHaveLength(1);
  expect(findMatches([markdown], "example.com")).toHaveLength(0);
});
