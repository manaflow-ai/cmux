// What a tool call's result says, without the JSON a harness wrapped it in. Harnesses hand the pane
// a tool's result as text, and that text is often the protocol's envelope rather than the result:
// an MCP result (`{"content":[{"type":"text","text":"…"}],"structuredContent":…}`), a bare list of
// content blocks, a JSON-RPC style `{"result": …, "error": null}`, or Codex's function output
// (`{"output":"…","metadata":{"exit_code":0}}`), with JSON text again inside the text. The opened
// call shows the result itself: its text (as Markdown when it is Markdown), its images, and any
// other JSON pretty-printed, never as one long raw line. JSON a tool really returned (a JSON file
// it read) is not an envelope: it stays JSON, as it was printed when it was printed on lines.

/// What the opened call draws.
export type ToolResult = {
  /// The text to show: the result's text, or JSON pretty-printed.
  text: string;
  /// How to draw it: JSON (a code block), Markdown, or plain text.
  lang: "json" | "markdown" | "text";
  /// Data URLs of the images the envelope carried.
  images: string[];
  /// The text came out of an envelope (so it is not what the tool printed, and is not shown raw).
  unwrapped: boolean;
};

/// Outputs longer than this are shown as they are: parsing them would stall the pane.
const MAX_PARSE_CHARS = 2_000_000;
/// The largest image block kept (its base64 text), as for a call's ACP image blocks (direct.ts).
const MAX_IMAGE_CHARS = 8 * 1024 * 1024;
/// Envelopes inside envelopes (JSON text in a text block that is itself a result) are peeled this deep.
const MAX_DEPTH = 6;

/// An envelope's parts: its texts and images, and what it holds that draws as neither (`rest`:
/// structured content, an error's data, a block this pane cannot show), kept as JSON.
type Peeled = { texts: string[]; images: string[]; rest: unknown[] };

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
/// types but lacks its value or has other fields (Notion's rich text `{"type":"text","text":{…}}`,
/// Slack's `{"type":"image","image_url":…}`) is a tool's own JSON, not an envelope.
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
const BLOCK_KEYS = ["type", "annotations", "_meta"];

/// `depth` counts ACP `content` wrappers: past MAX_DEPTH a block is not one, so its JSON shows as it is.
function isBlock(value: unknown, depth = 0): value is Block {
  if (depth > MAX_DEPTH || !isRecord(value) || typeof value.type !== "string" || !Object.hasOwn(BLOCKS, value.type))
    return false;
  const shape = BLOCKS[value.type]!;
  return shape.value(value, depth) && onlyKeys(value, [...BLOCK_KEYS, ...shape.keys]);
}

function isBlocks(value: unknown): value is Block[] {
  return Array.isArray(value) && value.length > 0 && value.every((entry) => isBlock(entry));
}

/// A block this pane draws as no text or image (audio, an image in another format or past the
/// size cap) stays in the result as JSON, its base64 replaced by its size.
function residual(block: Block): Block {
  const base64 = (text: string) => `(${text.length} characters of base64)`;
  if (typeof block.data === "string") return { ...block, data: base64(block.data) };
  const resource = block.resource;
  if (isRecord(resource) && typeof resource.blob === "string")
    return { ...block, resource: { ...resource, blob: base64(resource.blob) } };
  return block;
}

/// One content block's parts: its text, an image's data URL, a resource's text or its link, or
/// the block itself as residual JSON.
function peelBlock(block: Block, into: Peeled) {
  switch (block.type) {
    case "text":
      into.texts.push(block.text as string);
      return;
    case "content":
      peelBlock(block.content as Block, into);
      return;
    case "image": {
      const type = String(block.mimeType);
      if (/^image\/(png|jpeg|gif|webp)$/.test(type) && (block.data as string).length <= MAX_IMAGE_CHARS)
        into.images.push(`data:${type};base64,${block.data as string}`);
      else into.rest.push(residual(block));
      return;
    }
    case "resource": {
      // A text resource reads as its text; a binary one (`blob`) stays JSON, its base64 as its length.
      const resource = block.resource as Record<string, unknown>;
      if (typeof resource.text === "string") into.texts.push(resource.text);
      else into.rest.push(residual(block));
      return;
    }
    case "resource_link":
      into.texts.push(
        typeof block.name === "string" && block.name !== block.uri
          ? `${block.name}: ${block.uri as string}`
          : String(block.uri),
      );
      return;
    default:
      into.rest.push(residual(block));
  }
}

const shows = (peeled: Peeled) => peeled.texts.some((text) => text.trim()) || peeled.images.length > 0;

/// The index of the text block that repeats `structured` (MCP asks a tool to send its structured
/// content as text too), or -1.
function repeated(texts: string[], structured: unknown): number {
  if (!printable(structured)) return -1;
  const printed = JSON.stringify(structured);
  return texts.findIndex((text) => {
    const parsed = parseJSONValue(text);
    return parsed !== undefined && JSON.stringify(parsed) === printed;
  });
}

/// The parts of `value` when it is an envelope a harness wrapped a result in, else undefined.
/// `depth` counts result envelopes inside result envelopes; past MAX_DEPTH the value is not one.
export function peelEnvelope(value: unknown, depth = 0): Peeled | undefined {
  if (depth > MAX_DEPTH) return undefined;
  // A list of content blocks (`[{"type":"text","text":"…"}]`), or one block. Blocks that give no
  // text or image to show (audio alone) stay JSON as they are.
  if (isBlocks(value) || isBlock(value)) {
    const peeled: Peeled = { texts: [], images: [], rest: [] };
    for (const block of Array.isArray(value) ? value : [value]) peelBlock(block, peeled);
    return shows(peeled) ? peeled : undefined;
  }
  if (!isRecord(value)) return undefined;
  // An MCP `CallToolResult`: its content blocks, then its structured content as JSON. A text block
  // that repeats the structured content gives way to it, so the payload shows once, as the JSON it
  // is, never read as another envelope.
  if (
    Array.isArray(value.content) &&
    (value.content.length === 0 || isBlocks(value.content)) &&
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"])
  ) {
    const peeled: Peeled = { texts: [], images: [], rest: [] };
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
      const message =
        typeof error === "string"
          ? error
          : isRecord(error) && typeof error.message === "string"
            ? error.message
            : undefined;
      if (!message) return { texts: [], images: [], rest: [error] };
      // The message reads as text; the error's `data`, when it has any, follows as JSON.
      const data = isRecord(error) ? error.data : undefined;
      return { texts: [message], images: [], rest: data !== undefined && data !== null ? [data] : [] };
    }
    const result = value.result;
    if (result === undefined || result === null) return { texts: [], images: [], rest: [] };
    if (typeof result === "string") return { texts: [result], images: [], rest: [] };
    return peelEnvelope(result, depth + 1) ?? { texts: [], images: [], rest: [result] };
  }
  // Codex's function call output: `{"output": "…", "metadata": {"exit_code": 0, …}}`.
  if (typeof value.output === "string" && "metadata" in value && onlyKeys(value, ["output", "metadata"]))
    return { texts: [value.output], images: [], rest: [] };
  return undefined;
}

/// Whether `printed` is how a harness passes an envelope on: one line (`JSON.stringify`). JSON
/// printed on lines is a tool's own text (a file it read), which is never taken apart.
export const printedAsEnvelope = (printed: string | undefined) =>
  printed === undefined || !printed.trim().includes("\n");

/// JSON nested deeper than this is not indented (each level would indent every line below it): the
/// whole output shows as it was printed.
const MAX_PRETTY_DEPTH = 64;

/// Thrown when JSON cannot be shown other than as printed: nested too deep to indent, or holding a
/// number JavaScript cannot hold exactly. toolResult then shows the output as it was printed.
class AsPrinted extends Error {}

/// A JSON string, or a number token (group 1).
const JSON_TOKEN = /"(?:[^"\\]|\\.)*"|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g;
const NUMBER = /^-?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/;

/// A number's decimal value as `<significant digits>e<point>`, the same for every spelling of one
/// value (`1.50`, `15e-1`, `0.15e1`), or undefined for what is not a finite number (`Infinity`).
function decimal(spelled: string): string | undefined {
  const match = NUMBER.exec(spelled);
  if (!match) return undefined;
  let digits = match[1]! + (match[2] ?? "");
  let point = match[1]!.length + Number(match[3] ?? 0);
  const leading = digits.length - digits.replace(/^0+/, "").length;
  digits = digits.slice(leading).replace(/0+$/, "");
  point -= leading;
  return digits ? `${spelled.startsWith("-") ? "-" : ""}${digits}e${point}` : "0";
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

function deeperThan(value: unknown, limit: number): boolean {
  if (limit < 0) return true;
  if (Array.isArray(value)) return value.some((entry) => deeperThan(entry, limit - 1));
  if (isRecord(value)) return Object.values(value).some((entry) => deeperThan(entry, limit - 1));
  return false;
}

/// Whether `value` is shallow enough to show indented (mcpCalls.ts asks before it prints a residual).
export const printable = (value: unknown) => !deeperThan(value, MAX_PRETTY_DEPTH);

/// JSON indented, its values as they are: a string that holds JSON stays a string. Throws AsPrinted
/// past MAX_PRETTY_DEPTH, so toolResult shows the output as printed instead.
function pretty(value: unknown): string {
  if (!printable(value)) throw new AsPrinted();
  return JSON.stringify(value, null, 2);
}

/// Markdown structure in a result's text: a heading, a fence, a list, a table or a quote line.
const MARKDOWN = /^(?:#{1,6} \S|```|\s*(?:[-*+]|\d+\.) \S|\|.*\|\s*$|> \S)/m;
/// Results longer than this stay plain text: Markdown is for a result someone reads.
const MAX_MARKDOWN_CHARS = 20_000;

function textLang(text: string): ToolResult["lang"] {
  return text.length <= MAX_MARKDOWN_CHARS && MARKDOWN.test(text) ? "markdown" : "text";
}

/// What an opened non-shell call shows of `output` (ToolRow.tsx), and what Find in Chat reads of it
/// (chatFind.ts), so both see one text. `clean` drops what a host injected into the result's text
/// (mcpCalls.ts `cleanText`), once it is out of its envelope.
export function toolResult(output: string, clean: (text: string) => string = identity): ToolResult {
  const parsed = parseJSONValue(output);
  if (parsed !== undefined) return bounded(() => fromValue(parsed, output, 0, clean), output);
  // A host may have put its context around the JSON (a reminder after a result): read it again without.
  const cleaned = clean(output).replace(/\n$/, "");
  const reparsed = cleaned === output ? undefined : parseJSONValue(cleaned);
  if (reparsed !== undefined) return bounded(() => fromValue(reparsed, cleaned, 0, clean), cleaned);
  return { text: cleaned, lang: "text", images: [], unwrapped: false };
}

const identity = (text: string) => text;

/// `read()`, or `printed` as it is when its JSON cannot be shown any other way (AsPrinted).
function bounded(read: () => ToolResult, printed: string): ToolResult {
  try {
    return read();
  } catch (error) {
    if (!(error instanceof AsPrinted) && !(error instanceof RangeError)) throw error;
    return { text: printed.replace(/\n$/, ""), lang: "json", images: [], unwrapped: false };
  }
}

function fromValue(
  value: unknown,
  printed: string | undefined,
  depth: number,
  clean: (text: string) => string,
): ToolResult {
  let peeled = depth < MAX_DEPTH && printedAsEnvelope(printed) ? peelEnvelope(value) : undefined;
  // An envelope with nothing in it (`{"content":[],"isError":false}`) shows as the JSON it is,
  // so an opened call is never empty.
  if (peeled && !shows(peeled) && !peeled.rest.length) peeled = undefined;
  // Numbers past a double's precision would print changed, so this JSON shows only as printed.
  const exact = printed === undefined || !losesNumbers(printed);
  if (!peeled) {
    // JSON the tool returned. Printed on lines (a file it read) it stays as printed; one long line
    // is pretty-printed, unless that would change a number.
    const asPrinted = printed !== undefined && (!printedAsEnvelope(printed) || !exact);
    const text = asPrinted ? printed.replace(/\n$/, "") : pretty(value);
    return { text, lang: "json", images: [], unwrapped: printed === undefined };
  }
  const text = clean(peeled.texts.join("\n\n")).replace(/\n$/, "");
  if (peeled.rest.length) {
    if (!exact) throw new AsPrinted();
    // Text, then what the envelope held besides (structured content, an error's data, a block
    // drawn as neither text nor image), each as the JSON it is: it is the payload, not a wrapper.
    const rests = peeled.rest.map(pretty);
    return {
      text: [text, ...rests].filter((part) => part.trim()).join("\n\n"),
      lang: text.trim() ? "text" : "json",
      images: peeled.images,
      unwrapped: true,
    };
  }
  // The text inside is JSON again: an envelope in an envelope, or a JSON result (kept as printed
  // when it was printed on lines, as a file read through an MCP tool is).
  const inner = parseJSONValue(text);
  if (inner !== undefined) {
    const result = fromValue(inner, text, depth + 1, clean);
    return { ...result, images: [...peeled.images, ...result.images], unwrapped: true };
  }
  return { text, lang: textLang(text), images: peeled.images, unwrapped: true };
}

const imagesCaches = new WeakMap<(text: string) => string, Map<string, string[]>>();

/// The images an output's envelope carried (a result's `image` blocks, as data URLs), read with the
/// same `clean` as its text (ToolRow passes mcpCalls.ts `cleanText`), so text and images come from
/// one reading. Kept for the last few outputs asked, so a transcript re-render parses nothing again.
export function envelopeImages(output: string | undefined, clean: (text: string) => string = identity): string[] {
  // `image` appears in any output with an image block, nested in JSON text (`\"image\"`) or not.
  if (!output || !output.includes("image")) return [];
  let cache = imagesCaches.get(clean);
  if (!cache) imagesCaches.set(clean, (cache = new Map()));
  const known = cache.get(output);
  if (known) return known;
  const images = toolResult(output, clean).images;
  if (cache.size >= 32) cache.delete(cache.keys().next().value!);
  cache.set(output, images);
  return images;
}
