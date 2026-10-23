// What a tool call's result says, without the JSON a harness wrapped it in. Harnesses hand the pane
// a tool's result as text, and that text is often the protocol's envelope rather than the result:
// an MCP result (`{"content":[{"type":"text","text":"…"}]}`), a bare list of content blocks, a
// JSON-RPC style `{"result": …, "error": null}`, or Codex's function output
// (`{"output":"…","metadata":{"exit_code":0}}`), with JSON text again inside the text. The opened
// call shows the result itself: its text, as Markdown when it is Markdown. An envelope is taken
// apart only when its text is all it says; any other JSON is pretty-printed, never one long raw
// line, and JSON a tool really returned on lines (a JSON file it read) stays as it was printed.

/// What the opened call draws.
export type ToolResult = {
  /// The text to show: the result's text, or JSON.
  text: string;
  /// How to draw it: JSON (a code block), Markdown, or plain text.
  lang: "json" | "markdown" | "text";
};

/// Outputs longer than this are shown as they are: parsing them would stall the pane.
const MAX_PARSE_CHARS = 2_000_000;
/// Envelopes inside envelopes (JSON text in a text block that is itself a result) are peeled this deep.
const MAX_DEPTH = 6;
/// JSON nested deeper than this is shown as printed: indenting it would grow it by its depth squared.
const MAX_PRETTY_DEPTH = 64;

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/// `text` parsed as JSON when it is an object or an array, else undefined.
export function parseJSONValue(text: string | undefined): unknown {
  if (!text || text.length > MAX_PARSE_CHARS || !/^\s*[[{]/.test(text)) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/// Whether every key of `value` is one of `keys`.
function onlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}

const BLOCK_KEYS = ["type", "annotations", "_meta"];

/// The text of an MCP/ACP text block (`{"type":"text","text":"…"}`, or ACP's `content` wrapper
/// around one), else undefined. A block with other fields, or of another type (an image, a
/// resource), is not taken apart: the envelope then shows as the JSON it is, so nothing is lost.
function blockText(value: unknown, depth = 0): string | undefined {
  if (depth > MAX_DEPTH || !isRecord(value)) return undefined;
  if (value.type === "text" && typeof value.text === "string" && onlyKeys(value, [...BLOCK_KEYS, "text"]))
    return value.text;
  if (value.type === "content" && onlyKeys(value, [...BLOCK_KEYS, "content"]))
    return blockText(value.content, depth + 1);
  return undefined;
}

/// The texts of a list of text blocks, else undefined.
function blockTexts(value: unknown): string[] | undefined {
  if (!Array.isArray(value) || value.length === 0) return undefined;
  const texts = value.map((block) => blockText(block));
  return texts.every((text) => text !== undefined) ? (texts as string[]) : undefined;
}

/// The texts `value` holds when it is an envelope a harness wrapped a result in and its texts are
/// all it says, else undefined.
export function envelopeTexts(value: unknown, depth = 0): string[] | undefined {
  if (depth > MAX_DEPTH) return undefined;
  const single = blockText(value);
  if (single !== undefined) return [single];
  const list = blockTexts(value);
  if (list) return list;
  if (!isRecord(value)) return undefined;
  // An MCP `CallToolResult` with no structured content.
  if (
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"]) &&
    (value.structuredContent === undefined || value.structuredContent === null)
  )
    return blockTexts(value.content);
  // A JSON-RPC style result: `{"result": …, "error": null}`, or an error that is only its message.
  if (("result" in value || "error" in value) && onlyKeys(value, ["result", "error", "_meta", "id", "jsonrpc"])) {
    const error = value.error;
    if (error !== undefined && error !== null) {
      if (typeof error === "string") return [error];
      const message = isRecord(error) && onlyKeys(error, ["code", "message"]) ? error.message : undefined;
      return typeof message === "string" ? [message] : undefined;
    }
    const result = value.result;
    return typeof result === "string" ? [result] : envelopeTexts(result, depth + 1);
  }
  // Codex's function call output: `{"output": "…", "metadata": {"exit_code": 0, …}}`.
  if (typeof value.output === "string" && "metadata" in value && onlyKeys(value, ["output", "metadata"]))
    return [value.output];
  return undefined;
}

/// Whether `printed` is how a harness passes an envelope on: one line (`JSON.stringify`). JSON
/// printed on lines is a tool's own text (a file it read), which is never taken apart.
const oneLine = (printed: string) => !printed.trim().includes("\n");

function deeperThan(value: unknown, limit: number): boolean {
  if (limit < 0) return true;
  if (Array.isArray(value)) return value.some((entry) => deeperThan(entry, limit - 1));
  if (isRecord(value)) return Object.values(value).some((entry) => deeperThan(entry, limit - 1));
  return false;
}

/// A JSON string, or a number token (group 1).
const JSON_TOKEN = /"(?:[^"\\]|\\.)*"|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g;
const NUMBER = /^-?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/;

/// A number's decimal value as `<significant digits>e<point>`, the same for every spelling of one
/// value (`1.50`, `15e-1`), or undefined for what is not a finite number.
function decimal(spelled: string): string | undefined {
  const match = NUMBER.exec(spelled);
  if (!match) return undefined;
  let digits = match[1]! + (match[2] ?? "");
  let point = match[1]!.length + Number(match[3] ?? 0);
  const leading = digits.length - digits.replace(/^0+/, "").length;
  digits = digits.slice(leading).replace(/0+$/, "");
  point -= leading;
  const sign = spelled.startsWith("-") ? "-" : "";
  // Negative zero keeps its sign: JSON.stringify prints -0 as 0, so it reads as a number that changes.
  return digits ? `${sign}${digits}e${point}` : `${sign}0`;
}

/// Whether `printed` JSON holds a number a double cannot hold exactly (a 64-bit ID
/// `9007199254740993`, a decimal `10.000000000000001`): parsed and printed again, it would change.
export function losesNumbers(printed: string): boolean {
  for (const match of printed.matchAll(JSON_TOKEN)) {
    const spelled = match[1];
    if (spelled && decimal(spelled) !== decimal(String(Number(spelled)))) return true;
  }
  return false;
}

/// Markdown structure in a result's text: a heading, a fence, a list, a table or a quote line.
const MARKDOWN = /^(?:#{1,6} \S|```|\s*(?:[-*+]|\d+\.) \S|\|.*\|\s*$|> \S)/m;
/// Results longer than this stay plain text: Markdown is for a result someone reads.
const MAX_MARKDOWN_CHARS = 20_000;

/// What an opened non-shell call shows of `output` (ToolRow.tsx), and what Find in Chat reads of it
/// (chatFind.ts), so both see one text. `clean` drops what a host injected into the result's text
/// (mcpCalls.ts `cleanText`), once it is out of its envelope.
export function toolResult(output: string, clean: (text: string) => string = (text) => text): ToolResult {
  const parsed = parseJSONValue(output);
  if (parsed !== undefined) return fromJSON(parsed, output, 0, clean);
  // A host may have put its context around the JSON (a reminder after a result): read it again without.
  const cleaned = clean(output).replace(/\n$/, "");
  const reparsed = cleaned === output ? undefined : parseJSONValue(cleaned);
  if (reparsed !== undefined) return fromJSON(reparsed, cleaned, 0, clean);
  return { text: cleaned, lang: "text" };
}

function fromJSON(value: unknown, printed: string, depth: number, clean: (text: string) => string): ToolResult {
  const texts = depth < MAX_DEPTH && oneLine(printed) ? envelopeTexts(value) : undefined;
  if (texts?.some((text) => text.trim())) {
    const text = clean(texts.join("\n\n")).replace(/\n$/, "");
    // The text inside is JSON again: an envelope in an envelope, or a JSON result.
    const inner = parseJSONValue(text);
    if (inner !== undefined) return fromJSON(inner, text, depth + 1, clean);
    const markdown = text.length <= MAX_MARKDOWN_CHARS && MARKDOWN.test(text);
    return { text, lang: markdown ? "markdown" : "text" };
  }
  // JSON the tool returned. On one line it is indented, unless that would change it (a number a
  // double rounds) or it is nested too deep; printed on lines (a file it read) it stays as printed.
  const asPrinted = !oneLine(printed) || losesNumbers(printed) || deeperThan(value, MAX_PRETTY_DEPTH);
  return { text: asPrinted ? printed.replace(/\n$/, "") : JSON.stringify(value, null, 2), lang: "json" };
}
