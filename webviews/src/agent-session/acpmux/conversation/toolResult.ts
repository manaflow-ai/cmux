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

/// MCP and ACP content block types (`ContentBlock`), and ACP's `content` wrapper around one.
const BLOCK_TYPES = new Set(["text", "image", "audio", "resource", "resource_link", "content"]);

type Peeled = { texts: string[]; images: string[]; rest?: unknown };

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

function isBlock(value: unknown): value is Record<string, unknown> {
  return isRecord(value) && typeof value.type === "string" && BLOCK_TYPES.has(value.type);
}

function isBlocks(value: unknown): value is Record<string, unknown>[] {
  return Array.isArray(value) && value.length > 0 && value.every(isBlock);
}

/// One content block's parts: its text, an image's data URL, a resource's text or its link.
function peelBlock(block: Record<string, unknown>, into: Peeled) {
  switch (block.type) {
    case "text":
      if (typeof block.text === "string") into.texts.push(block.text);
      return;
    case "content":
      if (isBlock(block.content)) peelBlock(block.content, into);
      return;
    case "image": {
      const type = String(block.mimeType ?? "");
      if (
        typeof block.data === "string" &&
        /^image\/(png|jpeg|gif|webp)$/.test(type) &&
        block.data.length <= MAX_IMAGE_CHARS
      )
        into.images.push(`data:${type};base64,${block.data}`);
      return;
    }
    case "resource": {
      const resource = isRecord(block.resource) ? block.resource : undefined;
      if (typeof resource?.text === "string") into.texts.push(resource.text);
      else if (typeof resource?.uri === "string") into.texts.push(resource.uri);
      return;
    }
    case "resource_link":
      if (typeof block.uri === "string")
        into.texts.push(
          typeof block.name === "string" && block.name !== block.uri ? `${block.name}: ${block.uri}` : block.uri,
        );
      return;
    default:
      return;
  }
}

/// The parts of `value` when it is an envelope a harness wrapped a result in, else undefined.
export function peelEnvelope(value: unknown): Peeled | undefined {
  // A list of content blocks: `[{"type":"text","text":"…"}]`.
  if (isBlocks(value)) {
    const peeled: Peeled = { texts: [], images: [] };
    for (const block of value) peelBlock(block, peeled);
    return peeled;
  }
  if (!isRecord(value)) return undefined;
  // One content block.
  if (
    isBlock(value) &&
    (value.type === "text" ? typeof value.text === "string" : true) &&
    onlyKeys(value, ["type", "text", "content", "data", "mimeType", "resource", "uri", "name", "annotations", "_meta"])
  ) {
    const peeled: Peeled = { texts: [], images: [] };
    peelBlock(value, peeled);
    return peeled.texts.length || peeled.images.length ? peeled : undefined;
  }
  // An MCP `CallToolResult`: its content blocks, or its structured content when they say nothing.
  if (
    Array.isArray(value.content) &&
    (value.content.length === 0 || isBlocks(value.content)) &&
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"])
  ) {
    const peeled: Peeled = { texts: [], images: [] };
    for (const block of value.content as Record<string, unknown>[]) peelBlock(block, peeled);
    const structured = value.structuredContent;
    if (
      !peeled.texts.some((text) => text.trim()) &&
      !peeled.images.length &&
      structured !== undefined &&
      structured !== null
    )
      peeled.rest = structured;
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
      return message ? { texts: [message], images: [] } : { texts: [], images: [], rest: error };
    }
    const result = value.result;
    if (result === undefined || result === null) return { texts: [], images: [] };
    if (typeof result === "string") return { texts: [result], images: [] };
    return peelEnvelope(result) ?? { texts: [], images: [], rest: result };
  }
  // Codex's function call output: `{"output": "…", "metadata": {"exit_code": 0, …}}`.
  if (typeof value.output === "string" && "metadata" in value && onlyKeys(value, ["output", "metadata"]))
    return { texts: [value.output], images: [] };
  return undefined;
}

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

/// What an opened non-shell call shows of `output`.
export function toolResult(output: string): ToolResult {
  const parsed = parseJSONValue(output);
  if (parsed === undefined) return { text: output, lang: "text", images: [], unwrapped: false };
  return fromValue(parsed, output, 0);
}

function fromValue(value: unknown, printed: string | undefined, depth: number): ToolResult {
  const peeled = depth < MAX_DEPTH ? peelEnvelope(value) : undefined;
  if (!peeled) {
    // JSON the tool returned. Printed on lines (a file it read) it stays as printed; one long line
    // is pretty-printed.
    const text = printed !== undefined && printed.trim().includes("\n") ? printed.replace(/\n$/, "") : pretty(value);
    return { text, lang: "json", images: [], unwrapped: printed === undefined };
  }
  const text = peeled.texts.join("\n\n");
  if (peeled.rest !== undefined) {
    const rest = fromValue(peeled.rest, undefined, depth + 1);
    return {
      ...rest,
      text: text.trim() ? `${text}\n\n${rest.text}` : rest.text,
      images: [...peeled.images, ...rest.images],
      unwrapped: true,
    };
  }
  // The text inside is JSON again: an envelope in an envelope, or a JSON result.
  const inner = parseJSONValue(text);
  if (inner !== undefined) {
    const result = fromValue(inner, undefined, depth + 1);
    return { ...result, images: [...peeled.images, ...result.images], unwrapped: true };
  }
  return { text: text.replace(/\n$/, ""), lang: textLang(text), images: peeled.images, unwrapped: true };
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
