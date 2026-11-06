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

export type ToolResultOptions = {
  /// A web reader may return prose without Markdown punctuation. It still gets the readable
  /// renderer; JSON and line-oriented logs remain mono even when the caller opts in.
  markdown?: boolean;
  kind?: string;
  title?: string;
  description?: string;
};

/// Outputs longer than this are shown as they are: parsing them would stall the pane.
const MAX_PARSE_CHARS = 2_000_000;
/// Envelopes inside envelopes (JSON text in a text block that is itself a result) are peeled this deep.
const MAX_DEPTH = 6;
/// The most images a call's envelope gives its strip (toolImages.ts): with more, they all stay JSON.
export const MAX_TOOL_IMAGES = 4;
/// The largest image block shown (its base64 text), as for a call's ACP image blocks (direct.ts).
const MAX_IMAGE_CHARS = 8 * 1024 * 1024;
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
/// structured content, an error's data), which shows after the text as the JSON it is. `images`:
/// its image blocks as data URLs, each once, when they all go to the call's strip instead.
type Peeled = { texts: string[]; rest: unknown[]; images?: string[] };

type ImageScan = { sources: Set<string>; invalid: boolean };

function imageSource(block: Block): string {
  return `data:${String(block.mimeType)};base64,${String(block.data)}`;
}

/// Collect every image in an envelope, including envelopes nested in text, JSON-RPC results, and
/// Codex output. One bad image or too many distinct images vetoes the whole strip, so the text and
/// the strip always agree.
function scanImages(value: unknown, depth: number, scan: ImageScan): boolean {
  if (depth > MAX_DEPTH) return false;
  if (isBlocks(value) || isBlock(value)) {
    for (const block of (Array.isArray(value) ? value : [value]) as Block[]) scanBlockImages(block, depth, scan);
    return true;
  }
  if (!isRecord(value)) return false;
  if (
    Array.isArray(value.content) &&
    (value.content.length === 0 || isBlocks(value.content)) &&
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"])
  ) {
    for (const block of value.content as Block[]) scanBlockImages(block, depth, scan);
    return true;
  }
  if (("result" in value || "error" in value) && onlyKeys(value, ["result", "error", "_meta", "id", "jsonrpc"])) {
    if (value.error !== undefined && value.error !== null) return true;
    const result = value.result;
    if (result !== undefined && result !== null) {
      if (typeof result === "string") scanNestedText(result, depth + 1, scan);
      else scanImages(result, depth + 1, scan);
    }
    return true;
  }
  if (typeof value.output === "string" && "metadata" in value && onlyKeys(value, ["output", "metadata"])) {
    scanNestedText(value.output, depth + 1, scan);
    return true;
  }
  return false;
}

function scanNestedText(text: string, depth: number, scan: ImageScan) {
  const nested = parseJSONValue(text);
  if (nested === undefined) return;
  // A nested envelope with an unsafe number must stay byte-for-byte text, including its images.
  if (losesNumbers(text)) {
    if (peelEnvelope(nested)) scan.invalid = true;
    return;
  }
  scanImages(nested, depth, scan);
}

function scanBlockImages(block: Block, depth: number, scan: ImageScan) {
  if (block.type === "content") {
    scanBlockImages(block.content as Block, depth + 1, scan);
    return;
  }
  if (block.type === "image") {
    const { data, mimeType } = block as { data: string; mimeType: string };
    if (!/^image\/(png|jpeg|gif|webp)$/.test(mimeType) || data.length > MAX_IMAGE_CHARS) {
      scan.invalid = true;
      return;
    }
    scan.sources.add(imageSource(block));
    if (scan.sources.size > MAX_TOOL_IMAGES) scan.invalid = true;
    return;
  }
  if (block.type === "text") scanNestedText(block.text as string, depth + 1, scan);
}

function imageStrip(value: unknown): Set<string> {
  const scan: ImageScan = { sources: new Set(), invalid: false };
  scanImages(value, 0, scan);
  return scan.invalid ? new Set() : scan.sources;
}

/// The image blocks among `blocks` as data URLs, each once, when every one can go to the call's
/// strip: a PNG, JPEG, GIF or WebP under the size cap, at most `MAX_TOOL_IMAGES` different ones.
/// Otherwise undefined, and every one stays JSON, as when the envelope holds no image.
function stripImages(blocks: Block[], allowed: ReadonlySet<string>): string[] {
  const images = new Set<string>();
  for (let block of blocks) {
    while (block.type === "content") block = block.content as Block;
    if (block.type === "image") {
      const source = imageSource(block);
      if (allowed.has(source)) images.add(source);
    }
  }
  return [...images];
}

/// One block's text (a text resource's after its URI), nothing for an image in the strip, or the
/// block itself as JSON.
function peelBlock(block: Block, into: Peeled) {
  if (block.type === "content") return peelBlock(block.content as Block, into);
  if (block.type === "image" && into.images?.includes(imageSource(block))) return;
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
/// `images`: the approved image sources that may go to the call's strip, including envelopes nested
/// in text, JSON-RPC results, and Codex output.
export function peelEnvelope(value: unknown, depth = 0, images?: ReadonlySet<string>): Peeled | undefined {
  if (depth > MAX_DEPTH) return undefined;
  // A list of content blocks, or one block. Blocks with no text to read (audio alone) stay JSON.
  if (isBlocks(value) || isBlock(value)) {
    const blocks = Array.isArray(value) ? value : [value];
    const peeled: Peeled = {
      texts: [],
      rest: [],
      images: images ? stripImages(blocks, images) : undefined,
    };
    for (const block of blocks) peelBlock(block, peeled);
    return says(peeled) || Boolean(peeled.images?.length) ? peeled : undefined;
  }
  if (!isRecord(value)) return undefined;
  // An MCP `CallToolResult`: its blocks, then its structured content as JSON. A text block that
  // repeats the structured content gives way to it, so the payload shows once, never peeled again.
  if (
    Array.isArray(value.content) &&
    (value.content.length === 0 || isBlocks(value.content)) &&
    onlyKeys(value, ["content", "structuredContent", "isError", "_meta"])
  ) {
    const blocks = value.content as Block[];
    const peeled: Peeled = {
      texts: [],
      rest: [],
      images: images ? stripImages(blocks, images) : undefined,
    };
    for (const block of blocks) peelBlock(block, peeled);
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
      return {
        texts: [message],
        rest: "data" in error && error.data !== undefined ? [error.data] : [],
      };
    }
    const result = value.result;
    if (result === undefined || result === null) return { texts: [], rest: [] };
    if (typeof result === "string") return { texts: [result], rest: [] };
    return peelEnvelope(result, depth + 1, images) ?? { texts: [], rest: [result] };
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

/// Markdown structure in a result's text: a heading, a fence, a list, a table, a quote line or
/// clear emphasis. Shell and log output never reaches this classifier; ToolRow keeps those mono.
const MARKDOWN = /^(?:#{1,6} \S|```|\s*(?:[-*+]|\d+\.) \S|\|.*\|\s*$|> \S|.*(?:\*\*[^*\n]+\*\*|\*[^*\n]+\*).*)/m;
const LOG_LINE = [
  /^\s*\[(?:debug|info|warn|error|trace)\]/i,
  /^\s*(?:\[[^\]]+\]\s*)?(?:debug|info|warn|error|trace)\b/i,
  /^\s*(?:line|row|chunk|step|test|pass|fail)\s+\d+\b/i,
  // A timestamp leading the line, bracketed or not: an ISO date and time, or a time of day.
  /^\s*\[?(?:\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?\s/,
];
const CODE_DECLARATION = new RegExp(
  String.raw`^\s*(?:#!|from|import|def|class|const|let|var|function|return|if|for|while|` +
    String.raw`try|except|async|await|export)\b`,
  "m",
);
const CODE_ASSIGNMENT = /^\s*[A-Za-z_]\w*\s*=\s*[^=]/m;
const DUNDER = /(?:^|[^\w])__\w+__(?=$|[^\w])/;
/// Results longer than this stay plain text: Markdown is for a result someone reads.
const MAX_MARKDOWN_CHARS = 20_000;

/// A fence line: up to three spaces, then three or more backticks or tildes (CommonMark).
const FENCE = /^ {0,3}(`{3,}|~{3,})/;

/// `text` without the contents of its closed fenced code blocks, so a snippet a Markdown document
/// quotes (a fenced `const` or `import`) is not read as the result being source. An unclosed fence
/// keeps its lines: a file that merely starts with backticks is still checked as code.
function outsideFences(text: string): string {
  const lines = text.split("\n");
  const kept: string[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const open = FENCE.exec(lines[index]!)?.[1];
    if (!open) {
      kept.push(lines[index]!);
      continue;
    }
    const close = new RegExp(`^ {0,3}${open[0] === "`" ? "`" : "~"}{${open.length},}\\s*$`);
    let end = index + 1;
    while (end < lines.length && !close.test(lines[end]!)) end += 1;
    if (end === lines.length) {
      kept.push(lines[index]!);
      continue;
    }
    index = end;
  }
  return kept.join("\n");
}

/// A stack frame or cause under a log line, indented or not.
const LOG_FRAME = /^\s*(?:at\s|Caused by:|\.\.\.)/;

/// Log output: the first line is a log line, every other line is one, a frame, or indented detail,
/// and at least half are log lines or frames, so Markdown with indented code is not read as a log.
function isLog(lines: string[]): boolean {
  const isLine = (line: string) => LOG_LINE.some((pattern) => pattern.test(line));
  if (!isLine(lines[0]!)) return false;
  let logged = 0;
  for (const line of lines) {
    if (isLine(line) || LOG_FRAME.test(line)) logged += 1;
    else if (!/^\s/.test(line)) return false;
  }
  return logged * 2 >= lines.length;
}

function isMarkdownText(text: string, web = false): boolean {
  if (text.length > MAX_MARKDOWN_CHARS) return false;
  const lines = text.split("\n").filter((line) => line.trim());
  if (!lines.length || isLog(lines)) return false;
  const prose = outsideFences(text);
  if (CODE_DECLARATION.test(prose) || CODE_ASSIGNMENT.test(prose) || DUNDER.test(prose)) return false;
  return web || MARKDOWN.test(text);
}

/// What an opened non-shell call shows of `output` (ToolRow.tsx), and what Find in Chat reads of it
/// (chatFind.ts), so both see one text. `clean` drops what a host injected into the result's text
/// (mcpCalls.ts `cleanText`), once it is out of its envelope. `strip`: whether the call's strip
/// shows its envelope's images (toolImages.ts `stripsEnvelopeImages`), so its text leaves them out.
export function toolResult(
  output: string,
  clean: (text: string) => string = identity,
  strip = false,
  options: ToolResultOptions = {},
): ToolResult {
  const { text, lang } = read(output, clean, strip);
  return formatResult({ text, lang }, options);
}

/// Text already cleaned by a caller (the MCP request/response reader): classify its format
/// without peeling or rewriting it again. All output surfaces share this one format rule.
export function formatToolText(text: string, options: ToolResultOptions = {}): ToolResult {
  return formatResult({ text, lang: parseJSONValue(text) === undefined ? "text" : "json" }, options);
}

function formatResult({ text, lang }: ToolResult, options: ToolResultOptions): ToolResult {
  if (lang === "json" || text.length > MAX_MARKDOWN_CHARS) return { text, lang };
  if (options.kind === "execute") return { text, lang: "text" };
  const webRead =
    options.markdown ||
    options.kind === "fetch" ||
    /^\s*(?:fetch|web[\s._:-]*read)(?:\s|:|$)/i.test(options.title ?? "");
  return {
    text,
    lang: isMarkdownText(text, lang === "markdown" || webRead) ? "markdown" : "text",
  };
}

const identity = (text: string) => text;
type Read = ToolResult & { images: string[] };

function orderedImages(images: string[], allowed: ReadonlySet<string>): string[] {
  if (!allowed.size) return images;
  return [...allowed].filter((source) => images.includes(source));
}

function read(output: string, clean: (text: string) => string, strip: boolean): Read {
  const parsed = parseJSONValue(output);
  // Only an envelope the output is, as it came, gives its images to the strip, and never one holding
  // a number a double would change: that one shows as printed, its images included.
  if (parsed !== undefined) {
    const allowed = strip && !losesNumbers(output) ? imageStrip(parsed) : new Set<string>();
    return fromJSON(parsed, output, 0, clean, allowed);
  }
  // A host may have put its context around the JSON (a reminder after a result): read it again without.
  const cleaned = clean(output).replace(/\n$/, "");
  const reparsed = cleaned === output ? undefined : parseJSONValue(cleaned);
  if (reparsed !== undefined) return fromJSON(reparsed, cleaned, 0, clean, new Set<string>());
  return { text: cleaned, lang: "text", images: [] };
}

function fromJSON(
  value: unknown,
  printed: string,
  depth: number,
  clean: (text: string) => string,
  allowed: ReadonlySet<string>,
): Read {
  let peeled = depth < MAX_DEPTH && oneLine(printed) ? peelEnvelope(value, 0, allowed) : undefined;
  // An envelope with nothing in it shows as the JSON it is, and so does one whose other parts
  // cannot be printed again unchanged (a number a double rounds, nesting too deep).
  if (peeled && !says(peeled) && !peeled.rest.length && !peeled.images?.length) peeled = undefined;
  if (peeled?.rest.length && (losesNumbers(printed) || !peeled.rest.every(printable))) peeled = undefined;
  // Its images, when the strip shows them: its text below leaves them out, so each shows once.
  let images = peeled?.images ?? [];
  if (peeled) {
    // A text block can itself hold an envelope while this envelope also has structured content.
    // Remove only a nested envelope that actually contributed approved strip images; ordinary JSON
    // text keeps its original spelling and formatting.
    const textParts = peeled.texts.map((part) => {
      const inner = parseJSONValue(part);
      if (inner === undefined) return part;
      const nested = fromJSON(inner, part, depth + 1, clean, allowed);
      if (!nested.images.length) return part;
      images = [...nested.images.filter((image) => !images.includes(image)), ...images];
      return nested.text;
    });
    const text = clean(textParts.join("\n\n")).replace(/\n$/, "");
    if (peeled.rest.length) {
      // Text, then what the envelope held besides, each as the JSON it is: the payload, not a wrapper.
      const rest = peeled.rest.map((part) => JSON.stringify(part, null, 2) ?? "");
      const lang = text.trim() ? "text" : "json";
      return {
        text: [text, ...rest].filter((part) => part.trim()).join("\n\n"),
        lang,
        images: orderedImages(images, allowed),
      };
    }
    // The text inside is JSON again: an envelope in an envelope, or a JSON result.
    const inner = parseJSONValue(text);
    if (inner !== undefined) {
      const nested = fromJSON(inner, text, depth + 1, clean, allowed);
      return { ...nested, images: orderedImages([...nested.images, ...images], allowed) };
    }
    const markdown = isMarkdownText(text);
    return { text, lang: markdown ? "markdown" : "text", images: orderedImages(images, allowed) };
  }
  // JSON the tool returned. On one line it is indented, unless that would change it (a number a
  // double rounds) or it is nested too deep; printed on lines (a file it read) it stays as printed.
  const asPrinted = !oneLine(printed) || losesNumbers(printed) || deeperThan(value, MAX_PRETTY_DEPTH);
  return {
    text: asPrinted ? printed.replace(/\n$/, "") : JSON.stringify(value, null, 2),
    lang: "json",
    images: [],
  };
}

const imagesCache = new Map<string, string[]>();

/// The images the call's strip shows from its output's envelope, the ones `toolResult(output, …,
/// true)` leaves out of its text (which `clean` never changes). Kept for the last few outputs, so a
/// transcript re-render parses nothing again.
export function envelopeImages(output: string | undefined): string[] {
  if (!output) return [];
  const known = imagesCache.get(output);
  if (known) return known;
  const images = read(output, identity, true).images;
  if (imagesCache.size >= 32) imagesCache.delete(imagesCache.keys().next().value!);
  imagesCache.set(output, images);
  return images;
}
