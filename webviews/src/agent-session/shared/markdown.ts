import "../../../../Resources/markdown-viewer/markdown-sanitizer.js";

type MarkedHTMLToken = string | { text?: string; raw?: string };

type MarkedRendererLike = {
  html(token: MarkedHTMLToken, block?: boolean): string;
};

type MarkedLike = {
  parse(source: string, options?: Record<string, unknown>): string | Promise<string>;
  Renderer?: new () => MarkedRendererLike;
};

declare global {
  interface Window {
    marked?: MarkedLike;
  }
}

const passiveFetchAttributeNames = new Set(["poster", "src", "srcset", "xlink:href"]);

let agentSessionProfile: CmuxMarkdownSanitizerProfile | null = null;

function markdownProfile(): CmuxMarkdownSanitizerProfile {
  agentSessionProfile ??= CmuxMarkdownSanitizer.markdownProfile({
    // Transcript markdown never fetches media on render.
    removeElements: ["img"],
    url: ({ tag, name, value }) => sanitizedMarkdownURLAttribute(tag, name, value) ?? null,
  });
  return agentSessionProfile;
}

/// Renders untrusted transcript markdown into a sanitized fragment owned by
/// `targetDocument`. Insert the fragment directly (`replaceChildren`); never
/// serialize it back into `innerHTML`.
export function renderMarkdownFragment(
  source: string,
  targetDocument: Document = document,
  parser: MarkedLike | undefined = typeof window === "undefined" ? undefined : window.marked,
): DocumentFragment {
  if (parser?.parse) {
    try {
      const rendered = parser.parse(escapeMarkdownRawHTML(source), {
        async: false,
        breaks: true,
        gfm: true,
        renderer: rawHTMLAsTextRenderer(parser),
      });
      if (typeof rendered === "string") {
        return CmuxMarkdownSanitizer.sanitizeToFragment(rendered, {
          document: targetDocument,
          profile: markdownProfile(),
        });
      }
    } catch {
      return renderPlainTextFragment(source, targetDocument);
    }
  }
  return renderPlainTextFragment(source, targetDocument);
}

/// Raw HTML is never markup in a transcript. The pre-escaper below handles the
/// common cases, but the parser's own tokenizer is authoritative: any token it
/// still classifies as HTML is rendered as escaped text.
function rawHTMLAsTextRenderer(parser: MarkedLike): MarkedRendererLike | undefined {
  if (!parser.Renderer) {
    return undefined;
  }
  const renderer = new parser.Renderer();
  renderer.html = (token: MarkedHTMLToken) => {
    const text = typeof token === "string" ? token : (token.text ?? token.raw ?? "");
    return escapeTextHTML(text);
  };
  return renderer;
}

export function escapeMarkdownRawHTML(source: string): string {
  let output = "";
  let activeFence: MarkdownFence | null = null;
  const lines = source.match(/[^\r\n]*(?:\r\n|\n|\r|$)/g) ?? [];
  for (const rawLine of lines) {
    if (rawLine === "") {
      continue;
    }
    const lineEnding = rawLine.match(/(\r\n|\n|\r)$/)?.[0] ?? "";
    const line = lineEnding ? rawLine.slice(0, -lineEnding.length) : rawLine;

    if (activeFence) {
      output += line + lineEnding;
      if (isClosingFence(line, activeFence)) {
        activeFence = null;
      }
      continue;
    }

    const openingFence = markdownFence(line);
    if (openingFence) {
      activeFence = openingFence;
      output += line + lineEnding;
      continue;
    }

    output += escapeInlineRawHTML(line) + lineEnding;
  }
  return output;
}

export function renderPlainTextHTML(source: string): string {
  return escapeTextHTML(source).replace(/\n/g, "<br>");
}

export function renderPlainTextFragment(source: string, targetDocument: Document = document): DocumentFragment {
  const fragment = targetDocument.createDocumentFragment();
  const lines = source.split("\n");
  lines.forEach((line, index) => {
    if (index > 0) {
      fragment.append(targetDocument.createElement("br"));
    }
    if (line) {
      fragment.append(targetDocument.createTextNode(line));
    }
  });
  return fragment;
}

function escapeTextHTML(source: string): string {
  return source
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

type MarkdownFence = {
  marker: string;
};

// Mirrors marked's `fences` rule: up to three spaces, then three or more
// backticks or tildes. A backtick fence's info string may not contain a
// backtick; such a line is inline text, not a fence.
function markdownFence(line: string): MarkdownFence | null {
  const match = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
  if (!match) {
    return null;
  }
  const marker = match[1];
  if (marker[0] === "`" && match[2].includes("`")) {
    return null;
  }
  return { marker };
}

// Mirrors marked's closing rule ` {0,3}\1[~`]* *$`: the exact opening marker,
// then any further fence characters, then spaces only.
function isClosingFence(line: string, fence: MarkdownFence): boolean {
  const match = /^ {0,3}(.*)$/.exec(line);
  if (!match) {
    return false;
  }
  const rest = match[1];
  if (!rest.startsWith(fence.marker)) {
    return false;
  }
  return /^[~`]* *$/.test(rest.slice(fence.marker.length));
}

const asciiPunctuation = /[!-/:-@[-`{-~]/;

// CommonMark code spans: a backtick run of length n closes only at the next
// run of exactly n backticks. A backslash-escaped backtick in text is literal
// and cannot open a span.
function escapeInlineRawHTML(line: string): string {
  let output = "";
  let plainStart = 0;
  let index = 0;
  while (index < line.length) {
    const character = line[index];
    if (character === "\\" && index + 1 < line.length && asciiPunctuation.test(line[index + 1])) {
      index += 2;
      continue;
    }
    if (character !== "`") {
      index += 1;
      continue;
    }

    const runStart = index;
    while (index < line.length && line[index] === "`") {
      index += 1;
    }
    const runLength = index - runStart;
    const closeIndex = closingBacktickRun(line, index, runLength);
    if (closeIndex < 0) {
      continue;
    }

    output += escapeRawHTMLSegment(line.slice(plainStart, runStart));
    output += line.slice(runStart, closeIndex + runLength);
    index = closeIndex + runLength;
    plainStart = index;
  }
  output += escapeRawHTMLSegment(line.slice(plainStart));
  return output;
}

function closingBacktickRun(line: string, from: number, length: number): number {
  let index = from;
  while (index < line.length) {
    if (line[index] !== "`") {
      index += 1;
      continue;
    }
    const runStart = index;
    while (index < line.length && line[index] === "`") {
      index += 1;
    }
    if (index - runStart === length) {
      return runStart;
    }
  }
  return -1;
}

function escapeRawHTMLSegment(source: string): string {
  return source.replace(/&/g, "&amp;").replace(/</g, "&lt;");
}

export function sanitizedMarkdownURLAttribute(
  elementName: string,
  attributeName: string,
  value: string,
): string | null | undefined {
  const name = attributeName.toLowerCase();
  if (passiveFetchAttributeNames.has(name)) {
    return null;
  }
  if (name !== "href") {
    return undefined;
  }
  if (elementName.toLowerCase() !== "a") {
    return null;
  }
  return isSafeURL(value) ? value.trim() : null;
}

export function isSafeURL(value: string): boolean {
  const trimmed = value.trim();
  if (hasControlCharacter(trimmed)) {
    return false;
  }
  if (trimmed.startsWith("#")) {
    return true;
  }
  if (trimmed.startsWith("/") || !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    return false;
  }
  try {
    const url = new URL(trimmed);
    return url.protocol === "http:" || url.protocol === "https:" || url.protocol === "mailto:";
  } catch {
    return false;
  }
}

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x20 || code === 0x7f) {
      return true;
    }
  }
  return false;
}
