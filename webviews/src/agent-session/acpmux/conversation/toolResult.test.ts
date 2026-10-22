// l10n-allow-file: test fixtures.
// A tool call's result without the JSON envelope a harness wrapped it in (toolResult.ts): each
// envelope shape unwraps to its text, images or structured content; JSON a tool really returned
// stays JSON.
import { expect, test } from "bun:test";
import { envelopeImages, toolResult } from "./toolResult";
import { cleanText, prettyOutput } from "./mcpCalls";
import { findMatches } from "./chatFind";
import type { AcpmuxRow } from "../model";
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

test("a tool's own JSON that names a block type but not its shape stays JSON", () => {
  // Notion rich text, a Slack image block, an Anthropic image block.
  const notion = JSON.stringify([{ type: "text", text: { content: "Hi" }, plain_text: "Hi" }]);
  const slack = JSON.stringify({ content: [{ type: "image", image_url: "https://example.com/a.png" }] });
  const anthropic = JSON.stringify([{ type: "image", source: { type: "base64", data: PNG } }]);
  for (const output of [notion, slack, anthropic]) {
    const result = toolResult(output);
    expect(result.lang).toBe("json");
    expect(result.text).toBe(JSON.stringify(JSON.parse(output), null, 2));
  }
});

test("a result envelope's error keeps its data", () => {
  const output = JSON.stringify({ error: { code: -32602, message: "Invalid params", data: { field: "path" } } });
  expect(toolResult(output).text).toBe('Invalid params\n\n{\n  "field": "path"\n}');
});

test("a JSON file read through an MCP tool keeps its own lines", () => {
  const file = '{\n    "name": "cmux",\n    "private": true\n}';
  expect(toolResult(JSON.stringify([{ type: "text", text: file }]))).toMatchObject({ text: file, lang: "json" });
});

test("context a host injected into an envelope's text is dropped once it is unwrapped", () => {
  const text = "<system-reminder>internal</system-reminder>\nThe result";
  expect(toolResult(JSON.stringify([{ type: "text", text }]), cleanText).text).toBe("The result");
});

test("Find in Chat counts what the opened call shows, not the envelope", () => {
  const output = JSON.stringify([{ type: "text", text: 'Said "some text"' }]);
  const row: AcpmuxRow = {
    id: "work",
    version: 1,
    at: 0,
    kind: "activity",
    text: "",
    items: [{ kind: "tool", text: "Lookup", tool: { id: "c1", title: "Lookup", status: "completed", output } }],
  };
  expect(findMatches([row], "text")).toHaveLength(1);
  expect(findMatches([row], '"some')).toHaveLength(1);
});

test("an envelope with nothing in it shows as its JSON", () => {
  expect(toolResult(JSON.stringify({ content: [], isError: false }))).toMatchObject({
    text: '{\n  "content": [],\n  "isError": false\n}',
    lang: "json",
  });
});

test("an MCP error's data shows after its message in the opened MCP call", () => {
  // Codex review finding 2: the MCP row dropped what followed the text.
  const output = JSON.stringify({ error: { code: -32602, message: "Invalid params", data: { field: "path" } } });
  expect(prettyOutput(output)).toBe('Invalid params\n\n{\n  "field": "path"\n}');
});

test("a JSON file printed on lines stays as printed even when it looks like an envelope", () => {
  // Codex review finding 3: a file holding content blocks or a JSON-RPC reply is the file, not a wrapper.
  const blocks = '[\n  { "type": "text", "text": "hello" }\n]\n';
  const rpc = '{\n  "jsonrpc": "2.0",\n  "id": 1,\n  "result": "ok"\n}';
  for (const file of [blocks, rpc]) {
    expect(toolResult(file)).toEqual({ text: file.trimEnd(), lang: "json", images: [], unwrapped: false });
    expect(prettyOutput(file)).toBe(JSON.stringify(JSON.parse(file), null, 2));
    // Read through an MCP tool, the file is the text inside the envelope and stays as printed too.
    expect(toolResult(JSON.stringify([{ type: "text", text: file }]))).toMatchObject({
      text: file.trimEnd(),
      lang: "json",
    });
  }
});

test("blocks the pane cannot draw stay in the result as JSON beside its text", () => {
  // Codex review finding 4: audio and images in other formats were dropped when text was present.
  const output = JSON.stringify({
    content: [
      { type: "text", text: "Caption" },
      { type: "audio", data: "UklGRg==", mimeType: "audio/wav" },
      { type: "image", data: "PHN2Zy8+", mimeType: "image/svg+xml" },
    ],
  });
  const result = toolResult(output);
  expect(result.text.startsWith("Caption\n\n")).toBe(true);
  expect(result.text).toContain('"type": "audio"');
  expect(result.text).toContain('"mimeType": "image/svg+xml"');
  expect(result.text).not.toContain("UklGRg==");
  expect(result.images).toEqual([]);
  expect(prettyOutput(output)).toContain('"type": "audio"');
});

test("structured content a text block does not repeat shows after the text", () => {
  // Codex re-review finding 1: structured content was dropped whenever there was text.
  const output = JSON.stringify({
    content: [{ type: "text", text: "Found one record" }],
    structuredContent: { records: [{ id: 42 }] },
  });
  expect(toolResult(output).text).toBe('Found one record\n\n{\n  "records": [\n    {\n      "id": 42\n    }\n  ]\n}');
  // MCP's own shape, the structured content also sent as text, shows it once.
  const repeated = JSON.stringify({
    content: [{ type: "text", text: '{"ok":true}' }],
    structuredContent: { ok: true },
  });
  expect(toolResult(repeated)).toMatchObject({ text: '{\n  "ok": true\n}', lang: "json" });
});

test("an error's data that looks like an envelope stays the JSON it is", () => {
  // Codex re-review finding 2: residual data went through envelope detection again.
  const data = { result: "bad path", id: "request-7" };
  const output = JSON.stringify({ error: { message: "Invalid params", data } });
  expect(toolResult(output).text).toBe(`Invalid params\n\n${JSON.stringify(data, null, 2)}`);
  const structured = { content: [{ type: "text", text: "inner" }] };
  const both = JSON.stringify({ content: [{ type: "text", text: "Summary" }], structuredContent: structured });
  expect(toolResult(both).text).toBe(`Summary\n\n${JSON.stringify(structured, null, 2)}`);
});

test("a string that holds JSON stays a string when its object is pretty-printed", () => {
  // Codex re-review finding 3: pretty-printing parsed string values into arrays and objects.
  const value = { payload: "[1,2]", kind: "string" };
  expect(toolResult(JSON.stringify(value)).text).toBe(JSON.stringify(value, null, 2));
});

test("an image block list inside an envelope's text shows in the call's image strip", () => {
  // Codex re-review finding 4: escaped quotes hid nested image blocks from envelopeImages.
  const inner = JSON.stringify([{ type: "image", data: PNG, mimeType: "image/png" }]);
  const output = JSON.stringify([{ type: "text", text: inner }]);
  expect(toolResult(output).images).toEqual([`data:image/png;base64,${PNG}`]);
  expect(envelopeImages(output)).toEqual([`data:image/png;base64,${PNG}`]);
});

test("Find in Chat reads a Markdown result as it draws, without its marks", () => {
  // Codex re-review finding 5: Find searched the Markdown source.
  const output = JSON.stringify([
    { type: "text", text: "## Status\n\n**critical** failure, see [the log](https://example.com/x)" },
  ]);
  const row: AcpmuxRow = {
    id: "work",
    version: 1,
    at: 0,
    kind: "activity",
    text: "",
    items: [{ kind: "tool", text: "Lookup", tool: { id: "c1", title: "Lookup", status: "completed", output } }],
  };
  expect(findMatches([row], "critical failure")).toHaveLength(1);
  expect(findMatches([row], "example.com")).toHaveLength(0);
  expect(findMatches([row], "##")).toHaveLength(0);
});

test("envelopes nested past the depth limit stay JSON instead of overflowing the stack", () => {
  // Codex re-review finding 6: result and content wrappers recursed without a bound.
  let result: unknown = "deep";
  for (let i = 0; i < 5000; i++) result = { result };
  // Past the bound, the output shows as it was printed: never indented level by level.
  const deepResult = JSON.stringify(result);
  expect(toolResult(deepResult)).toEqual({ text: deepResult, lang: "json", images: [], unwrapped: false });
  expect(prettyOutput(deepResult)).toBe(deepResult);
  let block: unknown = { type: "text", text: "deep" };
  for (let i = 0; i < 5000; i++) block = { type: "content", content: block };
  const deepBlocks = JSON.stringify([block]);
  expect(toolResult(deepBlocks)).toEqual({ text: deepBlocks, lang: "json", images: [], unwrapped: false });
  // A shallow chain still unwraps.
  expect(toolResult(JSON.stringify({ result: { result: "shallow" } })).text).toBe("shallow");
});

test("structured content a text block repeats shows once, as the JSON it is", () => {
  // Codex review 3 finding 2: the repeated text was peeled as an envelope, losing the payload's keys.
  const structured = { result: "bad path", id: "request-7" };
  const output = JSON.stringify({
    content: [{ type: "text", text: JSON.stringify(structured) }],
    structuredContent: structured,
  });
  expect(toolResult(output)).toMatchObject({ text: JSON.stringify(structured, null, 2), lang: "json" });
});

test("a binary resource stays JSON, its blob as its length", () => {
  // Codex review 3 finding 3: a resource without text was reduced to its URI.
  const output = JSON.stringify({
    content: [
      { type: "text", text: "Report attached" },
      { type: "resource", resource: { uri: "report://r1", mimeType: "application/pdf", blob: "JVBERi0=" } },
    ],
  });
  const text = toolResult(output).text;
  expect(text.startsWith("Report attached\n\n")).toBe(true);
  expect(text).toContain('"mimeType": "application/pdf"');
  expect(text).toContain('"blob": "(8 characters of base64)"');
  expect(text).not.toContain("JVBERi0=");
  expect(prettyOutput(output)).toContain('"uri": "report://r1"');
});

test("an envelope's images show when a host put context after it", () => {
  // Codex review 3 finding 4: the image strip read the output without the row's cleaning.
  const envelope = JSON.stringify([
    { type: "text", text: "Screenshot" },
    { type: "image", data: PNG, mimeType: "image/png" },
  ]);
  const output = `${envelope}\n<system-reminder>internal</system-reminder>`;
  expect(toolResult(output, cleanText)).toMatchObject({ text: "Screenshot", images: [`data:image/png;base64,${PNG}`] });
  expect(toolImages({ id: "c1", title: "mcp__shots__take", status: "completed", output })).toEqual([
    `data:image/png;base64,${PNG}`,
  ]);
});

test("JSON with a number past a double's precision shows as printed, never rounded", () => {
  // Codex review 4: pretty-printing turned 9007199254740993 into 9007199254740992.
  const output = '{"id":9007199254740993,"name":"row"}';
  expect(toolResult(output)).toEqual({ text: output, lang: "json", images: [], unwrapped: false });
  // Inside an envelope's text, the text is shown as printed too.
  expect(toolResult(JSON.stringify([{ type: "text", text: output }]))).toMatchObject({ text: output, lang: "json" });
  // Beside text in an envelope, the whole output shows as printed rather than lose the digit.
  const both = `{"content":[{"type":"text","text":"Found"}],"structuredContent":{"id":9007199254740993}}`;
  expect(toolResult(both).text).toBe(both);
  // Long digit runs inside strings, and numbers a double holds exactly, still pretty-print.
  const safe = { id: "9007199254740993", count: 12345678901234, ratio: 0.5, tiny: 1.5e-7, big: 1e21 };
  expect(toolResult(JSON.stringify(safe)).text).toBe(JSON.stringify(safe, null, 2));
  expect(toolResult('{"ratio":1.50,"scaled":15e-1,"zero":-0.0}').lang).toBe("json");
  expect(toolResult('{"ratio":1.50,"scaled":15e-1,"zero":-0.0}').text).toBe(
    '{\n  "ratio": 1.5,\n  "scaled": 1.5,\n  "zero": 0\n}',
  );
});

test("JSON with a decimal past a double's precision shows as printed, never rounded", () => {
  // Codex review 5: `10.000000000000001` has 15 digits in a row, so a digit-run check missed it.
  for (const output of [
    '{"value":10.000000000000001}',
    '{"value":1e400}',
    '{"value":0.1000000000000000055511151231257827}',
  ]) {
    expect(toolResult(output)).toEqual({ text: output, lang: "json", images: [], unwrapped: false });
    expect(toolResult(JSON.stringify([{ type: "text", text: output }]))).toMatchObject({ text: output, lang: "json" });
  }
  const both = '{"content":[{"type":"text","text":"Found"}],"structuredContent":{"value":10.000000000000001}}';
  expect(toolResult(both).text).toBe(both);
});

test("a text with an exact ID is kept beside structured content that rounded it", () => {
  // Codex review 6: dedup parsed the text, rounded its ID, matched the rounded copy and dropped it.
  const output =
    '{"content":[{"type":"text","text":"{\\"id\\":9007199254740993}"}],"structuredContent":{"id":9007199254740992}}';
  const result = toolResult(output);
  expect(result.text).toContain("9007199254740993");
});

test("a resource link keeps its title and description", () => {
  // Codex review 7 finding 1: a link was reduced to its name and URI.
  const output = JSON.stringify([
    {
      type: "resource_link",
      uri: "docs://restore",
      name: "restore",
      title: "Restore a backup",
      description: "Supports point-in-time recovery for the last seven days.",
    },
  ]);
  expect(toolResult(output).text).toBe(
    "Restore a backup: docs://restore\nSupports point-in-time recovery for the last seven days.",
  );
});

test("images past the strip's limit stay in the result as JSON", () => {
  // Codex review 7 finding 2: the strip showed four, and the rest were gone.
  const images = Array.from({ length: 6 }, (_, i) => ({ type: "image", data: `${PNG}${i}`, mimeType: "image/png" }));
  const output = JSON.stringify([{ type: "text", text: "Six shots" }, ...images]);
  const result = toolResult(output);
  expect(result.images).toHaveLength(4);
  expect(result.text.startsWith("Six shots\n\n")).toBe(true);
  expect(result.text.match(/"type": "image"/g)).toHaveLength(2);
  expect(toolImages({ id: "c1", title: "mcp__shots__take", status: "completed", output })).toHaveLength(4);
});

test("images past the strip's limit stay JSON across envelopes inside envelopes", () => {
  // Codex review 8: each level had its own four, so five came out and the strip dropped one.
  const image = (i: number) => ({ type: "image", data: `${PNG}${i}`, mimeType: "image/png" });
  const child = JSON.stringify({ content: [{ type: "text", text: "Child" }, image(1), image(2), image(3), image(4)] });
  const output = JSON.stringify([image(0), { type: "text", text: child }]);
  const result = toolResult(output);
  expect(result.images).toHaveLength(4);
  expect(result.text.match(/"type": "image"/g)).toHaveLength(1);
  expect(result.text.startsWith("Child\n\n")).toBe(true);
});
