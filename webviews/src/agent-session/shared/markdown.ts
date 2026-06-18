type MarkedLike = {
  parse(source: string, options?: Record<string, unknown>): string | Promise<string>;
};

declare global {
  interface Window {
    marked?: MarkedLike;
  }
}

const unsafeElementNames = new Set([
  "base",
  "embed",
  "form",
  "iframe",
  "link",
  "meta",
  "object",
  "script",
  "style",
]);

const passiveFetchAttributeNames = new Set(["poster", "src", "srcset", "xlink:href"]);

export function renderMarkdownHTML(source: string): string {
  const parser = typeof window === "undefined" ? undefined : window.marked;
  if (parser?.parse) {
    try {
      const rendered = parser.parse(escapeMarkdownRawHTML(source), {
        async: false,
        breaks: true,
        gfm: true,
      });
      if (typeof rendered === "string") {
        return sanitizeRenderedHTML(rendered);
      }
    } catch {
      return renderPlainTextHTML(source);
    }
  }
  return renderPlainTextHTML(source);
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

function escapeTextHTML(source: string): string {
  return source
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

type MarkdownFence = {
  character: "`" | "~";
  length: number;
};

function markdownFence(line: string): MarkdownFence | null {
  const match = /^( {0,3})(`{3,}|~{3,})/.exec(line);
  if (!match) {
    return null;
  }
  const marker = match[2];
  return {
    character: marker[0] as MarkdownFence["character"],
    length: marker.length,
  };
}

function isClosingFence(line: string, fence: MarkdownFence): boolean {
  const match = /^( {0,3})(`{3,}|~{3,})\s*$/.exec(line);
  if (!match) {
    return false;
  }
  const marker = match[2];
  return marker[0] === fence.character && marker.length >= fence.length;
}

function escapeInlineRawHTML(line: string): string {
  let output = "";
  let plainStart = 0;
  let index = 0;
  while (index < line.length) {
    if (line[index] !== "`") {
      index += 1;
      continue;
    }

    const runStart = index;
    while (index < line.length && line[index] === "`") {
      index += 1;
    }
    const marker = line.slice(runStart, index);
    const closeIndex = line.indexOf(marker, index);
    if (closeIndex < 0) {
      continue;
    }

    output += escapeRawHTMLSegment(line.slice(plainStart, runStart));
    output += line.slice(runStart, closeIndex + marker.length);
    index = closeIndex + marker.length;
    plainStart = index;
  }
  output += escapeRawHTMLSegment(line.slice(plainStart));
  return output;
}

function escapeRawHTMLSegment(source: string): string {
  return source.replace(/&/g, "&amp;").replace(/</g, "&lt;");
}

function sanitizeRenderedHTML(html: string): string {
  if (typeof document === "undefined") {
    return html;
  }
  const template = document.createElement("template");
  template.innerHTML = html;

  for (const element of Array.from(template.content.querySelectorAll("*"))) {
    if (unsafeElementNames.has(element.localName)) {
      element.remove();
      continue;
    }

    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith("on") || name === "srcdoc" || name === "style") {
        element.removeAttribute(attribute.name);
        continue;
      }
      const sanitizedURL = sanitizedMarkdownURLAttribute(element.localName, name, attribute.value);
      if (sanitizedURL === null) {
        element.removeAttribute(attribute.name);
      } else if (typeof sanitizedURL === "string" && sanitizedURL !== attribute.value) {
        element.setAttribute(attribute.name, sanitizedURL);
      }
    }

    if (element.localName === "a") {
      element.setAttribute("rel", "noreferrer");
    }
  }

  return template.innerHTML;
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
  return isSafeURL(value) ? value : null;
}

export function isSafeURL(value: string): boolean {
  const trimmed = value.trim();
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
