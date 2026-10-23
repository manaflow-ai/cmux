// What a tool call's result says, without the JSON a harness wrapped it in. Harnesses hand the pane
// a tool's result as text, and that text is often the protocol's envelope rather than the result:
// an MCP result (`{"content":[{"type":"text","text":"…"}]}`), a bare list of content blocks, a
// JSON-RPC style `{"result": …, "error": null}`, or Codex's function output
// (`{"output":"…","metadata":{"exit_code":0}}`), with JSON text again inside the text. The opened
// call shows the result itself: its text, as Markdown when it is Markdown, then what the envelope
// held besides (a block that is not text, structured content, an error's data) as the JSON it is.
// Any other JSON is pretty-printed, never one long raw line, and JSON a tool really returned on
// lines (a JSON file it read) stays as it was printed.

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

type Block = Record<string, unknown>;

/// MCP and ACP content blocks (`ContentBlock`, and ACP's `content` wrapper around one), each with
/// the field that holds its value and the fields it may carry. An object that names one of these
/// types but lacks its value or has other fields (Notion's rich text `{"type":"text","text":{…}}`)
/// is a tool's own JSON, not an envelope.
const BLOCKS: Record<string, { value: (block: Block, depth: number) => boolean; keys: readonly string[] }> = {
  text: { value: (block) => typeof block.text === "string", keys: ["text"] },
  image: {
    value: (block) => typeof block.data === "string" && typeof block.mimeType === "string",
    keys: ["data", "mimeType"],
  },
  audio: {
    value: (block) => typeof block.data === "string" && typeof block.mimeType === "string",
    keys: ["data", "mimeType"],
  },
  resource: {
    value: (block) => isRecord(block.resource) && typeof block.resource.uri === "string",
    keys: ["resource"],
  },
  resource_link: {
    value: (block) => typeof block.uri === "string",
    keys: ["uri", "name", "title", "description", "mimeType", "size"],
  },
  content: { value: (block, depth) => isBlock(block.content, depth + 1), keys: ["content"] },
};

function isBlock(value: unknown, depth = 0): value is Block {
  if (depth > MAX_DEPTH || !isRecord(value) || typeof value.type !== "string" || !Object.hasOwn(BLOCKS, value.type))
    return false;
  const shape = BLOCKS[value.type]!;
  return shape.value(value, depth) && onlyKeys(value, ["type", "annotations", "_meta", ...shape.keys]);
}

const isBlocks = (value: unknown): value is Block[] =>
  Array.isArray(value) && value.length > 0 && value.every((entry) => isBlock(entry));

/// An envelope's parts: its texts, and what it holds besides (`rest`: a block that is not text,
/// structured content, an error's data), which shows after the text as the JSON it is.
type Peeled = { texts: string[]; rest: unknown[] };

/// One block's text (a text resource's after its URI), or the block itself as JSON.
function peelBlock(block: Block, into: Peeled) {
  if (block.type === "content") return peelBlock(block.content as Block, into);
  const resource = block.resource as Record<string, unknown> | undefined;
  if (block.type === "text") into.texts.push(block.text as string);
  else if (
    block.type === "resource" &&
    typeof resource?.text === "string" &&
    onlyKeys(resource, ["uri", "text", "mimeType"])
  )
    into.texts.push(`${resource.uri as string}\n${resource.text}`);
  else into.rest.push(block);
}

/// The index of the text block that repeats `structured` (MCP asks a tool to send its structured
/// content as text too), or -1. A text holding a number a double rounds is never a repeat: parsed,
/// it could match a structured copy that lost the digit, and the text is the exact one.
function repeated(texts: string[], structured: unknown): number {
  if (!printable(structured)) return -1;
  const printed = JSON.stringify(structured);
  return texts.findIndex((text) => {
    if (losesNumbers(text)) return false;
    const parsed = parseJSONValue(text);
    return parsed !== undefined && JSON.stringify(parsed) === printed;
  });
}

const says = (peeled: Peeled) => peeled.texts.some((text) => text.trim());

/// The parts of `value` when it is an envelope a harness wrapped a result in, else undefined.
export function peelEnvelope(value: unknown, depth = 0): Peeled | undefined {
  if (depth > MAX_DEPTH) return undefined;
  // A list of content blocks, or one block. Blocks with no text to read (audio alone) stay JSON.
  if (isBlocks(value) || isBlock(value)) {
    const peeled: Peeled = { texts: [], rest: [] };
    for (const block of Array.isArray(value) ? value : [value]) peelBlock(block, peeled);
    return says(peeled) ? peeled : undefined;
  }
  if (!isRecord(value)) return undefined;
  // An MCP `CallToolResult`: its blocks, then its structured content as JSON. A text block that
  // repeats the structured content gives way to it, so the payload shows once, never peeled again.
  if (
    Array.isArray(value.content) &&
    (value.content.length === 0 || isBlocks(value.content)) &&
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"])
  ) {
    const peeled: Peeled = { texts: [], rest: [] };
    for (const block of value.content as Block[]) peelBlock(block, peeled);
    const structured = value.structuredContent;
    if (structured !== undefined && structured !== null) {
      const index = repeated(peeled.texts, structured);
      if (index >= 0) peeled.texts.splice(index, 1);
      peeled.rest.push(structured);
    }
    return peeled;
  }
  // A JSON-RPC style result: `{"result": …, "error": null}`.
  if (("result" in value || "error" in value) && onlyKeys(value, ["result", "error", "_meta", "id", "jsonrpc"])) {
    const error = value.error;
    if (error !== undefined && error !== null) {
      if (typeof error === "string") return { texts: [error], rest: [] };
      if (!isRecord(error) || typeof error.message !== "string") return { texts: [], rest: [error] };
      // The message reads as text. A JSON-RPC error (`code`, `message`, `data`) follows with its
      // data; any other error (a REST API's `status`, `details`) with everything but its message.
      const { message, ...others } = error;
      if (!onlyKeys(others, ["code", "data"])) return { texts: [message], rest: [others] };
      // A `data` the error names, even null, follows it: only an absent one is left out.
      return { texts: [message], rest: "data" in error && error.data !== undefined ? [error.data] : [] };
    }
    const result = value.result;
    if (result === undefined || result === null) return { texts: [], rest: [] };
    if (typeof result === "string") return { texts: [result], rest: [] };
    return peelEnvelope(result, depth + 1) ?? { texts: [], rest: [result] };
  }
  // Codex's function call output: `{"output": "…", "metadata": {"exit_code": 0, …}}`.
  if (typeof value.output === "string" && "metadata" in value && onlyKeys(value, ["output", "metadata"]))
    return { texts: [value.output], rest: [] };
  return undefined;
}

/// Whether `printed` is how a harness passes an envelope on: one line (`JSON.stringify`). JSON
/// printed on lines is a tool's own text (a file it read), which is never taken apart.
export const oneLine = (printed: string) => !printed.trim().includes("\n");

function deeperThan(value: unknown, limit: number): boolean {
  if (limit < 0) return true;
  if (Array.isArray(value)) return value.some((entry) => deeperThan(entry, limit - 1));
  if (isRecord(value)) return Object.values(value).some((entry) => deeperThan(entry, limit - 1));
  return false;
}

/// Whether `value` is shallow enough to indent (mcpCalls.ts asks before it prints a residual).
export const printable = (value: unknown) => !deeperThan(value, MAX_PRETTY_DEPTH);

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
  let peeled = depth < MAX_DEPTH && oneLine(printed) ? peelEnvelope(value) : undefined;
  // An envelope with nothing in it shows as the JSON it is, and so does one whose other parts
  // cannot be printed again unchanged (a number a double rounds, nesting too deep).
  if (peeled && !says(peeled) && !peeled.rest.length) peeled = undefined;
  if (peeled?.rest.length && (losesNumbers(printed) || !peeled.rest.every(printable))) peeled = undefined;
  if (peeled) {
    const text = clean(peeled.texts.join("\n\n")).replace(/\n$/, "");
    if (peeled.rest.length) {
      // Text, then what the envelope held besides, each as the JSON it is: the payload, not a wrapper.
      const rest = peeled.rest.map((part) => JSON.stringify(part, null, 2) ?? "");
      return { text: [text, ...rest].filter((part) => part.trim()).join("\n\n"), lang: text.trim() ? "text" : "json" };
    }
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
