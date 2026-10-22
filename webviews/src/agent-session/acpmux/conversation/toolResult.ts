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
const BLOCKS: Record<string, { value: (block: Block) => boolean; keys: readonly string[] }> = {
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
  content: { value: (block) => isBlock(block.content), keys: ["content"] },
};
const BLOCK_KEYS = ["type", "annotations", "_meta"];

function isBlock(value: unknown): value is Block {
  if (!isRecord(value) || typeof value.type !== "string" || !Object.hasOwn(BLOCKS, value.type)) return false;
  const shape = BLOCKS[value.type]!;
  return shape.value(value) && onlyKeys(value, [...BLOCK_KEYS, ...shape.keys]);
}

function isBlocks(value: unknown): value is Block[] {
  return Array.isArray(value) && value.length > 0 && value.every(isBlock);
}

/// A block this pane draws as no text or image (audio, an image in another format or past the
/// size cap) stays in the result as JSON, its base64 replaced by its size.
function residual(block: Block): Block {
  return typeof block.data === "string" ? { ...block, data: `(${block.data.length} characters of base64)` } : block;
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
      const resource = block.resource as Record<string, unknown>;
      into.texts.push(typeof resource.text === "string" ? resource.text : String(resource.uri));
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

/// The parts of `value` when it is an envelope a harness wrapped a result in, else undefined.
export function peelEnvelope(value: unknown): Peeled | undefined {
  // A list of content blocks (`[{"type":"text","text":"…"}]`), or one block. Blocks that give no
  // text or image to show (audio alone) stay JSON as they are.
  if (isBlocks(value) || isBlock(value)) {
    const peeled: Peeled = { texts: [], images: [], rest: [] };
    for (const block of Array.isArray(value) ? value : [value]) peelBlock(block, peeled);
    return shows(peeled) ? peeled : undefined;
  }
  if (!isRecord(value)) return undefined;
  // An MCP `CallToolResult`: its content blocks, and its structured content when they say nothing
  // (it repeats them otherwise).
  if (
    Array.isArray(value.content) &&
    (value.content.length === 0 || isBlocks(value.content)) &&
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"])
  ) {
    const peeled: Peeled = { texts: [], images: [], rest: [] };
    for (const block of value.content as Block[]) peelBlock(block, peeled);
    const structured = value.structuredContent;
    if (!shows(peeled) && structured !== undefined && structured !== null) peeled.rest.push(structured);
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
    return peelEnvelope(result) ?? { texts: [], images: [], rest: [result] };
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

/// A value with each string that holds JSON parsed in its place, so nested results read as JSON.
function parseNested(value: unknown, depth = 0): unknown {
  if (depth > 8) return value;
  if (typeof value === "string") {
    const parsed = parseJSONValue(value);
    return parsed === undefined ? value : parseNested(parsed, depth + 1);
  }
  if (Array.isArray(value)) return value.map((entry) => parseNested(entry, depth + 1));
  if (isRecord(value)) {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) out[key] = parseNested(entry, depth + 1);
    return out;
  }
  return value;
}

const pretty = (value: unknown) => JSON.stringify(parseNested(value), null, 2);

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
export function toolResult(output: string, clean: (text: string) => string = (text) => text): ToolResult {
  const parsed = parseJSONValue(output);
  if (parsed !== undefined) return fromValue(parsed, output, 0, clean);
  // A host may have put its context around the JSON (a reminder after a result): read it again without.
  const cleaned = clean(output).replace(/\n$/, "");
  const reparsed = cleaned === output ? undefined : parseJSONValue(cleaned);
  if (reparsed !== undefined) return fromValue(reparsed, cleaned, 0, clean);
  return { text: cleaned, lang: "text", images: [], unwrapped: false };
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
  if (!peeled) {
    // JSON the tool returned. Printed on lines (a file it read) it stays as printed; one long line
    // is pretty-printed.
    const text = printed !== undefined && !printedAsEnvelope(printed) ? printed.replace(/\n$/, "") : pretty(value);
    return { text, lang: "json", images: [], unwrapped: printed === undefined };
  }
  const text = clean(peeled.texts.join("\n\n")).replace(/\n$/, "");
  if (peeled.rest.length) {
    // Text, then what the envelope held besides (structured content, an error's data, a block
    // drawn as neither text nor image), each as JSON.
    const rests = peeled.rest.map((rest) => fromValue(rest, undefined, depth + 1, clean));
    const parts = [text, ...rests.map((rest) => rest.text)].filter((part) => part.trim());
    return {
      text: parts.join("\n\n"),
      lang: !text.trim() && rests.length === 1 ? rests[0]!.lang : "text",
      images: [...peeled.images, ...rests.flatMap((rest) => rest.images)],
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

const imagesCache = new Map<string, string[]>();

/// The images an output's envelope carried (a result's `image` blocks, as data URLs). Kept for the
/// last few outputs asked, so a transcript re-render parses nothing again.
export function envelopeImages(output: string | undefined): string[] {
  if (!output || !output.includes('"image"')) return [];
  const known = imagesCache.get(output);
  if (known) return known;
  const images = toolResult(output).images;
  if (imagesCache.size >= 32) imagesCache.delete(imagesCache.keys().next().value!);
  imagesCache.set(output, images);
  return images;
}
