// l10n-allow-file: test fixtures.
// A tool call's result without the JSON envelope a harness wrapped it in (toolResult.ts): each
// envelope shape unwraps to its text; an envelope that says more than its text, and JSON a tool
// really returned, stay JSON.
import { expect, test } from "bun:test";
import { envelopeImages, toolResult } from "./toolResult";
import { stripsEnvelopeImages, toolImages } from "../toolImages";
import { cleanText, prettyOutput } from "./mcpCalls";
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

const PNG = "iVBORw0KGgo=";
const pretty = (value: unknown) => JSON.stringify(value, null, 2);

test("what an envelope holds besides its text follows it as the JSON it is", () => {
  const image = { type: "image", data: PNG, mimeType: "image/png" };
  const link = { type: "resource_link", uri: "docs://a", name: "a", title: "A", description: "About a" };
  const blob = { type: "resource", resource: { uri: "report://r1", mimeType: "application/pdf", blob: "JVBERi0=" } };
  expect(toolResult(JSON.stringify([{ type: "text", text: "Shot" }, image, link, blob])).text).toBe(
    ["Shot", pretty(image), pretty(link), pretty(blob)].join("\n\n"),
  );
  const structured = { records: [{ id: 42 }] };
  const found = { content: [{ type: "text", text: "Found one" }], structuredContent: structured };
  expect(toolResult(JSON.stringify(found))).toEqual({ text: `Found one\n\n${pretty(structured)}`, lang: "text" });
  expect(toolResult(JSON.stringify({ content: [], structuredContent: structured }))).toEqual({
    text: pretty(structured),
    lang: "json",
  });
});

test("an error shows its message, then its data or its other fields", () => {
  const rpc = { error: { code: -32602, message: "Invalid params", data: { result: "bad path", id: "request-7" } } };
  expect(toolResult(JSON.stringify(rpc)).text).toBe(`Invalid params\n\n${pretty(rpc.error.data)}`);
  const rest = {
    error: { code: 400, message: "Invalid request", status: "INVALID_ARGUMENT", details: [{ field: "region" }] },
  };
  const { message: _message, ...others } = rest.error;
  expect(toolResult(JSON.stringify(rest)).text).toBe(`Invalid request\n\n${pretty(others)}`);
  expect(prettyOutput(JSON.stringify(rest))).toBe(`Invalid request\n\n${pretty(others)}`);
  // A data the error names as null still shows; only an absent one is left out.
  const named = { error: { code: -32000, message: "Server error", data: null } };
  expect(toolResult(JSON.stringify(named)).text).toBe("Server error\n\nnull");
  expect(prettyOutput(JSON.stringify(named))).toBe("Server error\n\nnull");
  expect(toolResult(JSON.stringify({ error: { code: -32000, message: "Server error" } })).text).toBe("Server error");
});

test("the opened MCP call never rounds a number a double would change", () => {
  for (const output of [
    JSON.stringify({ content: [{ type: "text", text: "Created" }] }).replace(
      "}]}",
      '}],"structuredContent":{"id":9007199254740993}}',
    ),
    '{"error":{"code":-32000,"message":"Conflict","data":{"id":9007199254740993}}}',
  ]) {
    expect(prettyOutput(output)).toBe(output);
    expect(toolResult(output).text).toBe(output);
  }
});

test("a text resource reads as its URI and text", () => {
  const block = {
    type: "resource",
    resource: { uri: "file:///src/auth.ts", mimeType: "text/typescript", text: "export {}" },
  };
  expect(toolResult(JSON.stringify([block])).text).toBe("file:///src/auth.ts\nexport {}");
});

test("structured content a text repeats shows once, as JSON, unless the text is the exact one", () => {
  const structured = { result: "bad path", id: "request-7" };
  const output = { content: [{ type: "text", text: JSON.stringify(structured) }], structuredContent: structured };
  expect(toolResult(JSON.stringify(output))).toEqual({ text: pretty(structured), lang: "json" });
  // Parsed, the text's ID would round to the structured copy's: the text is kept, and the whole
  // output shows as printed, since its structured content cannot be printed again unchanged.
  const exact =
    '{"content":[{"type":"text","text":"{\\"id\\":9007199254740993}"}],"structuredContent":{"id":9007199254740992}}';
  expect(toolResult(exact).text).toContain("9007199254740993");
});

test("an envelope whose other parts a double would change, or nest too deep, shows as printed", () => {
  const rounded = '{"content":[{"type":"text","text":"Found"}],"structuredContent":{"value":10.000000000000001}}';
  expect(toolResult(rounded)).toEqual({ text: rounded, lang: "json" });
  let deep: unknown = "deep";
  for (let i = 0; i < 100; i++) deep = { deep };
  const nested = JSON.stringify({ error: { message: "Too deep", data: deep } });
  expect(toolResult(nested)).toEqual({ text: nested, lang: "json" });
  expect(prettyOutput(nested)).toBe(nested);
});

test("the opened MCP call reads an envelope that holds more than text as the row does, nested ones included", () => {
  for (const output of [
    JSON.stringify({ content: [], structuredContent: {} }),
    JSON.stringify({
      content: [
        { type: "audio", mimeType: "audio/wav", data: "UklG" },
        { type: "resource_link", uri: "file:///a" },
      ],
    }),
    JSON.stringify({
      content: [{ type: "text", text: "Saved" }],
      structuredContent: { raw: '{"id":9007199254740993}' },
    }),
    JSON.stringify({ error: { code: -32000, message: "Failed", data: { body: '{"nested":true}' } } }),
    // An envelope inside an envelope: Codex output and a JSON-RPC result holding a whole MCP result.
    JSON.stringify({
      output: JSON.stringify({ content: [{ type: "text", text: "Saved" }], structuredContent: { ok: true } }),
      metadata: { exit_code: 0 },
    }),
    JSON.stringify({
      result: '{"content":[{"type":"text","text":"Found"}],"structuredContent":{"id":9007199254740993}}',
      error: null,
    }),
  ]) {
    expect(prettyOutput(output)).toBe(toolResult(output, cleanText).text);
  }
  const raw = { content: [{ type: "text", text: "Saved" }], structuredContent: { raw: '{"id":9007199254740993}' } };
  expect(prettyOutput(JSON.stringify(raw))).toContain(JSON.stringify(raw.structuredContent.raw));
});

test("the opened MCP call never parses a text into JSON that would round its numbers", () => {
  const text = '{"id":9007199254740993,"name":"run"}';
  expect(prettyOutput(JSON.stringify({ content: [{ type: "text", text }] }))).toBe(text);
});

test("an envelope with nothing to read stays JSON", () => {
  for (const value of [
    { content: [], isError: false },
    [{ type: "text", text: " " }],
    [{ type: "audio", data: "UklG", mimeType: "audio/wav" }],
  ])
    expect(toolResult(JSON.stringify(value))).toEqual({ text: pretty(value), lang: "json" });
});

test("the opened MCP call shows the same parts", () => {
  const output = JSON.stringify({ content: [{ type: "text", text: "Found one" }], structuredContent: { id: 42 } });
  expect(prettyOutput(output)).toBe(`Found one\n\n${pretty({ id: 42 })}`);
  expect(prettyOutput(JSON.stringify({ error: null, result: { content: [{ type: "text", text: "Rejected" }] } }))).toBe(
    "Rejected",
  );
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

const shot = (i: number) => ({ type: "image", data: `${PNG}${i}`, mimeType: "image/png" });
const url = (i: number) => `data:image/png;base64,${PNG}${i}`;
const call = (output: string, status = "completed") => ({ id: "c1", title: "mcp__shots__take", status, output });
/// What the opened call shows of a finished call's output, its MCP call's response, and its strip.
const shown = (output: string) => {
  const row = toolResult(output, cleanText, true).text;
  expect(prettyOutput(output, true)).toBe(row || undefined);
  return { row, strip: toolImages(call(output)) };
};
const imageJSON = (text: string) => text.match(/"type": "image"/g)?.length ?? 0;

test("a finished call's plain envelope gives its images to the strip, its text to the opened call", () => {
  const output = JSON.stringify({ content: [{ type: "text", text: "Screenshot" }, shot(0)] });
  expect(shown(output)).toEqual({ row: "Screenshot", strip: [url(0)] });
  expect(toolResult(output, cleanText, true).lang).toBe("text");
  // An image alone: the strip shows it, and the opened call nothing more, never its JSON too.
  expect(shown(JSON.stringify([shot(1)]))).toEqual({ row: "", strip: [url(1)] });
});

test("an image repeated in one envelope shows once, in the strip", () => {
  const output = JSON.stringify([{ type: "text", text: "Five" }, ...[0, 0, 0, 0, 0].map(shot)]);
  expect(envelopeImages(output)).toEqual([url(0)]);
  expect(shown(output)).toEqual({ row: "Five", strip: [url(0)] });
});

test("an envelope whose images cannot all go to the strip keeps every one as JSON, as before", () => {
  const svg = { type: "image", data: PNG, mimeType: "image/svg+xml" };
  for (const blocks of [[0, 1, 2, 3, 4].map(shot), [shot(0), svg]]) {
    const output = JSON.stringify([{ type: "text", text: "Shots" }, ...blocks]);
    expect(envelopeImages(output)).toEqual([]);
    expect(shown(output)).toEqual({ row: toolResult(output, cleanText).text, strip: [] });
    expect(imageJSON(toolResult(output, cleanText, true).text)).toBe(blocks.length);
  }
});

test("host context and unsafe numbers keep their images in the text", () => {
  const plain = JSON.stringify([{ type: "text", text: "Shot" }, shot(0)]);
  const outputs = [
    // After a host's context, or holding a number a double changes.
    `${plain}\n<system-reminder>internal</system-reminder>`,
    JSON.stringify({ content: [{ type: "text", text: "Shot" }, shot(0)], _meta: { n: 1 } }).replace(
      '"n":1',
      '"n":9007199254740993',
    ),
  ];
  // Each renders exactly as without the strip, its image in its text.
  for (const output of outputs) {
    expect(envelopeImages(output)).toEqual([]);
    expect(toolImages(call(output))).toEqual([]);
    expect(toolResult(output, cleanText, true)).toEqual(toolResult(output, cleanText));
    expect(toolResult(output, cleanText, true).text).toContain(`${PNG}0`);
    expect(prettyOutput(output, true)).toBe(prettyOutput(output));
    expect(prettyOutput(output, true)).toContain(`${PNG}0`);
  }
});

test("nested, JSON-RPC, and Codex envelopes give their images to the strip", () => {
  const inner = JSON.stringify([{ type: "text", text: "Nested shot" }, shot(0)]);
  const outputs = [
    JSON.stringify({ jsonrpc: "2.0", id: 1, result: JSON.parse(inner) }),
    JSON.stringify({ jsonrpc: "2.0", id: 1, result: inner }),
    JSON.stringify({ output: inner, metadata: { exit_code: 0 } }),
    JSON.stringify([{ type: "text", text: inner }]),
  ];
  for (const output of outputs) expect(shown(output)).toEqual({ row: "Nested shot", strip: [url(0)] });
  const withStructured = JSON.stringify({
    content: [{ type: "text", text: inner }],
    structuredContent: { ok: true },
  });
  expect(shown(withStructured)).toEqual({ row: 'Nested shot\n\n{\n  "ok": true\n}', strip: [url(0)] });
});

test("nested images share the duplicate and all-or-nothing cap", () => {
  const inner = JSON.stringify([{ type: "text", text: "Nested shots" }, shot(0), shot(1), shot(2), shot(3)]);
  const four = JSON.stringify([{ type: "text", text: inner }, shot(3)]);
  expect(shown(four)).toEqual({ row: "Nested shots", strip: [url(0), url(1), url(2), url(3)] });
  const five = JSON.stringify([{ type: "text", text: inner }, shot(4)]);
  expect(envelopeImages(five)).toEqual([]);
  expect(toolImages(call(five))).toEqual([]);
  expect(toolResult(five, cleanText, true).text).toContain(`${PNG}4`);
});

test("nested image strip order follows the envelope block order", () => {
  const inner = JSON.stringify([{ type: "text", text: "Inner" }, shot(1)]);
  const outerFirst = JSON.stringify([
    { type: "image", data: `${PNG}0`, mimeType: "image/png" },
    { type: "text", text: inner },
  ]);
  const textFirst = JSON.stringify([
    { type: "text", text: inner },
    { type: "image", data: `${PNG}0`, mimeType: "image/png" },
  ]);
  expect(envelopeImages(outerFirst)).toEqual([url(0), url(1)]);
  expect(envelopeImages(textFirst)).toEqual([url(1), url(0)]);
});

test("Unicode-escaped image metadata still reaches the strip", () => {
  const output = '[{"\\u0074ype":"\\u0069mage","data":"' + PNG + '0","mimeType":"\\u0069mage/\\u0070ng"}]';
  expect(output).not.toContain("image");
  expect(envelopeImages(output)).toEqual([url(0)]);
  expect(toolImages(call(output))).toEqual([url(0)]);
  expect(toolResult(output, cleanText, true).text).toBe("");
});

test("a JSON-RPC error leaves an image in its result data", () => {
  const output = JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    error: { code: -32000, message: "Failed", data: { result: [{ type: "image", data: PNG, mimeType: "image/png" }] } },
    result: { content: [{ type: "image", data: `${PNG}result`, mimeType: "image/png" }] },
  });
  expect(envelopeImages(output)).toEqual([]);
  expect(toolResult(output, cleanText, true).text).toContain(PNG);
});

test("a running call or a shell keeps its envelope's images in its text", () => {
  const output = JSON.stringify([{ type: "text", text: "Shot" }, shot(0)]);
  const shell = { ...call(output), kind: "execute", command: "cat shot.json" };
  for (const tool of [shell]) {
    expect(stripsEnvelopeImages(tool)).toBe(false);
    expect(toolImages(tool)).toEqual([]);
  }
  expect(stripsEnvelopeImages(call(output, "failed"))).toBe(true);
  expect(imageJSON(toolResult(output, cleanText).text)).toBe(1);
});

test("a running call shows its envelope images in the strip", () => {
  const output = JSON.stringify([{ type: "text", text: "Still running" }, shot(0)]);
  const running = call(output, "in_progress");
  expect(stripsEnvelopeImages(running)).toBe(true);
  expect(toolImages(running)).toEqual([url(0)]);
  expect(toolResult(output, cleanText, true).text).toBe("Still running");
});

test("the strip shows an envelope's images, then the call's own as before, each once", () => {
  const output = JSON.stringify([{ type: "text", text: "Four" }, ...[0, 1, 2, 3].map(shot)]);
  const own = "data:image/png;base64,OWN";
  const images = toolImages({ ...call(output), images: [own, url(2)] });
  expect(images).toEqual([...[0, 1, 2, 3].map(url), own]);
});

test("Find in Chat reads a call's text without the images in its strip", () => {
  const output = JSON.stringify([{ type: "text", text: "Shot" }, shot(0)]);
  const row = (tool: ReturnType<typeof call> & { kind?: string }): AcpmuxRow => ({
    id: "work",
    version: 1,
    at: 0,
    kind: "activity",
    text: "",
    items: [{ kind: "tool", text: "Shot", tool }],
  });
  for (const title of ["Lookup", "mcp__shots__take"]) {
    expect(findMatches([row({ ...call(output), title })], "iVBORw0KGgo")).toHaveLength(0);
    expect(findMatches([row({ ...call(output, "in_progress"), title })], "iVBORw0KGgo")).toHaveLength(0);
  }
});
