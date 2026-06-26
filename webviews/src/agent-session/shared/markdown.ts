import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import csharp from "highlight.js/lib/languages/csharp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import go from "highlight.js/lib/languages/go";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import kotlin from "highlight.js/lib/languages/kotlin";
import markdown from "highlight.js/lib/languages/markdown";
import python from "highlight.js/lib/languages/python";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";

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

const highlightLanguageAliases = new Map([
  ["c++", "cpp"],
  ["c#", "csharp"],
  ["cc", "cpp"],
  ["cjs", "javascript"],
  ["cs", "csharp"],
  ["cxx", "cpp"],
  ["golang", "go"],
  ["h", "cpp"],
  ["hpp", "cpp"],
  ["htm", "xml"],
  ["html", "xml"],
  ["js", "javascript"],
  ["jsx", "javascript"],
  ["kt", "kotlin"],
  ["kts", "kotlin"],
  ["mjs", "javascript"],
  ["md", "markdown"],
  ["py", "python"],
  ["rb", "ruby"],
  ["rs", "rust"],
  ["sh", "bash"],
  ["shell", "bash"],
  ["svg", "xml"],
  ["ts", "typescript"],
  ["tsx", "typescript"],
  ["yml", "yaml"],
  ["zsh", "bash"],
]);

for (const [languageName, language] of [
  ["bash", bash],
  ["c", c],
  ["cpp", cpp],
  ["csharp", csharp],
  ["css", css],
  ["diff", diff],
  ["go", go],
  ["java", java],
  ["javascript", javascript],
  ["json", json],
  ["kotlin", kotlin],
  ["markdown", markdown],
  ["python", python],
  ["ruby", ruby],
  ["rust", rust],
  ["sql", sql],
  ["swift", swift],
  ["typescript", typescript],
  ["xml", xml],
  ["yaml", yaml],
] as const) {
  hljs.registerLanguage(languageName, language);
}

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

  highlightRenderedCodeBlocks(template.content);

  return template.innerHTML;
}

function highlightRenderedCodeBlocks(root: ParentNode): void {
  for (const codeElement of Array.from(root.querySelectorAll("pre > code"))) {
    const language = highlightLanguageFromCodeClassName(codeElement.className);
    const highlighted = highlightCodeHTML(codeElement.textContent ?? "", language);
    if (!highlighted) {
      continue;
    }
    codeElement.innerHTML = highlighted;
    codeElement.classList.add("hljs");
    if (language) {
      (codeElement as HTMLElement).dataset.highlightLanguage = language;
    }
  }
}

export function highlightLanguageFromCodeClassName(className: string): string | null {
  for (const token of className.split(/\s+/)) {
    const match = /^(?:lang|language)-(.+)$/.exec(token);
    if (!match) {
      continue;
    }
    return normalizeHighlightLanguage(match[1]);
  }
  return null;
}

export function normalizeHighlightLanguage(language: string | null | undefined): string | null {
  const normalized = language?.trim().toLowerCase().split(/[\s,{:]/, 1)[0]?.replace(/^language-/, "") ?? "";
  if (!normalized || !/^[a-z0-9#+._-]+$/.test(normalized)) {
    return null;
  }
  return highlightLanguageAliases.get(normalized) ?? normalized;
}

export function highlightCodeHTML(code: string, language: string | null | undefined): string | null {
  const normalizedLanguage = normalizeHighlightLanguage(language);
  if (!normalizedLanguage || !hljs.getLanguage(normalizedLanguage)) {
    return null;
  }
  try {
    return hljs.highlight(code, {
      language: normalizedLanguage,
      ignoreIllegals: true,
    }).value;
  } catch {
    return null;
  }
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
