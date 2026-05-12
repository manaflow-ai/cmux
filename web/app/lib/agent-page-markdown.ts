import TurndownService from "turndown";
import { gfm } from "turndown-plugin-gfm";
import type { AgentPageFormat } from "./agent-page-paths";

const turndown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "fenced",
  emDelimiter: "_",
  strongDelimiter: "**",
  linkStyle: "inlined",
});

turndown.use(gfm);
turndown.remove(["script", "style", "noscript", "button"]);
turndown.addRule("removeSvg", {
  filter: (node) => node.nodeName.toLowerCase() === "svg",
  replacement: () => "",
});
turndown.addRule("decorativeListDash", {
  filter: (node) =>
    node.nodeName.toLowerCase() === "span" &&
    node.textContent?.trim() === "-" &&
    node.parentNode?.nodeName.toLowerCase() === "li",
  replacement: () => "",
});
turndown.addRule("ariaHidden", {
  filter: (node) => {
    const element = node as Element;
    return element.getAttribute?.("aria-hidden") === "true";
  },
  replacement: () => "",
});
turndown.addRule("blockLink", {
  filter: (node) =>
    node.nodeName.toLowerCase() === "a" &&
    Array.from(node.childNodes).some((child) =>
      blockMarkdownElementNames.has(child.nodeName.toLowerCase()),
    ),
  replacement: (content, node) => {
    const href = (node as Element).getAttribute?.("href");
    const text = content.trim();
    if (!href) {
      return text ? `\n\n${text}\n\n` : "";
    }
    if (!text) {
      return href;
    }
    return `\n\n${text}\n\nLink: ${href}\n\n`;
  },
});

const blockMarkdownElementNames = new Set([
  "address",
  "article",
  "aside",
  "blockquote",
  "div",
  "dl",
  "figure",
  "footer",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "header",
  "hr",
  "li",
  "main",
  "ol",
  "p",
  "pre",
  "section",
  "table",
  "ul",
]);

export function markdownFromHtml({
  html,
  sourceUrl,
}: {
  html: string;
  sourceUrl: string;
}): string {
  const readableSource = extractReadableHtml(html);
  const title = extractTitle(readableSource) ?? extractDocumentTitle(html);
  const readableHtml = prepareReadableHtml(readableSource, sourceUrl);
  const body = title
    ? ensureMarkdownTitle(cleanMarkdown(turndown.turndown(readableHtml)), title)
    : cleanMarkdown(turndown.turndown(readableHtml));
  const parts: string[] = [];

  if (body) {
    parts.push(body);
  }
  parts.push(`Canonical: ${sourceUrl}`);

  return `${parts.join("\n\n")}\n`;
}

export function plainTextFromMarkdown(markdown: string): string {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const plainLines: string[] = [];
  let inFence = false;

  for (const line of lines) {
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      continue;
    }

    if (inFence) {
      plainLines.push(line);
      continue;
    }

    const tableCells = tableCellsFromMarkdownLine(line);
    const text =
      tableCells?.map(markdownInlineToText).join("\t") ??
      markdownInlineToText(
        line
          .replace(/^\s{0,3}#{1,6}\s+/, "")
          .replace(/^\s{0,3}>\s?/, "")
          .replace(/^\s*[-*+]\s+/, "- "),
      );

    if (!isMarkdownTableDivider(line)) {
      plainLines.push(text);
    }
  }

  return cleanPlainTextBlock(plainLines.join("\n"));
}

export function headersForAgentPage({
  format,
  canonicalUrl,
  contentLanguage,
  privateResponse = false,
  varyAcceptLanguage = false,
}: {
  format: AgentPageFormat;
  canonicalUrl: string;
  contentLanguage: string;
  privateResponse?: boolean;
  varyAcceptLanguage?: boolean;
}): Headers {
  const headers = new Headers({
    "cache-control": privateResponse
      ? "private, no-store"
      : "public, max-age=0, s-maxage=3600, stale-while-revalidate=86400",
    "content-language": contentLanguage,
    "content-type":
      format === "md"
        ? "text/markdown; charset=utf-8"
        : "text/plain; charset=utf-8",
    link: `<${canonicalUrl}>; rel="canonical"`,
    "x-robots-tag": "noindex, follow",
  });

  if (varyAcceptLanguage) {
    headers.set("vary", "Accept-Language");
  }

  return headers;
}

export function headersForLlmsTxt(): Headers {
  return new Headers({
    "cache-control": "public, max-age=0, s-maxage=3600, stale-while-revalidate=86400",
    "content-language": "en",
    "content-type": "text/plain; charset=utf-8",
    "x-robots-tag": "noindex, follow",
  });
}

export function localeFromCanonicalPath(pathname: string): string {
  const localeMatch = pathname.match(/^\/([a-z]{2}(?:-[A-Z]{2})?)(?:\/|$)/);
  return localeMatch?.[1] ?? "en";
}

export function extractReadableHtml(html: string): string {
  const searchableHtml = stripRawIgnoredElements(html);
  return (
    firstElementInnerHtml(searchableHtml, "main") ??
    firstElementInnerHtml(searchableHtml, "body") ??
    html
  );
}

function stripRawIgnoredElements(html: string): string {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<noscript\b[^>]*>[\s\S]*?<\/noscript>/gi, "");
}

function firstElementInnerHtml(html: string, tagName: string): string | null {
  const match = html.match(
    new RegExp(`<${tagName}\\b[^>]*>([\\s\\S]*?)</${tagName}>`, "i"),
  );
  return match?.[1] ?? null;
}

function extractTitle(html: string): string | null {
  const h1 = firstElementInnerHtml(html, "h1");
  if (h1) {
    return cleanPlainText(turndown.turndown(h1));
  }

  return null;
}

function extractDocumentTitle(html: string): string | null {
  const title = firstElementInnerHtml(html, "title");
  return title ? cleanDocumentTitle(decodeHtmlEntities(title)) : null;
}

function cleanPlainText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function cleanPlainTextBlock(text: string): string {
  return text
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .concat("\n");
}

function cleanDocumentTitle(text: string): string {
  return cleanPlainText(text)
    .replace(/\s+(?:\||-|\u2013|\u2014)\s+cmux$/i, "")
    .trim();
}

function decodeHtmlEntities(text: string): string {
  return text.replace(
    /&(#\d+|#x[\da-f]+|amp|lt|gt|quot|apos);/gi,
    (entity, value: string) => {
      const lowerValue = value.toLowerCase();
      if (lowerValue.startsWith("#x")) {
        return htmlEntityCodePoint(
          Number.parseInt(lowerValue.slice(2), 16),
          entity,
        );
      }
      if (lowerValue.startsWith("#")) {
        return htmlEntityCodePoint(
          Number.parseInt(lowerValue.slice(1), 10),
          entity,
        );
      }
      return (
        {
          amp: "&",
          apos: "'",
          gt: ">",
          lt: "<",
          quot: '"',
        }[lowerValue] ?? entity
      );
    },
  );
}

function htmlEntityCodePoint(codePoint: number, fallback: string): string {
  if (!Number.isFinite(codePoint) || codePoint < 0 || codePoint > 0x10ffff) {
    return fallback;
  }
  return String.fromCodePoint(codePoint);
}

function cleanMarkdown(markdown: string): string {
  return spaceAdjacentMarkdownLinks(markdown)
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function spaceAdjacentMarkdownLinks(markdown: string): string {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  let inFence = false;

  return lines
    .map((line) => {
      if (/^\s*```/.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) {
        return line;
      }
      return rewriteOutsideInlineCode(line, (text) =>
        text.replace(/(\]\([^)]+\))(?=\[)/g, "$1 "),
      );
    })
    .join("\n");
}

function rewriteOutsideInlineCode(
  markdown: string,
  rewrite: (text: string) => string,
): string {
  const parts = markdown.split(/(`[^`]*`)/g);
  return parts
    .map((part) => (part.startsWith("`") ? part : rewrite(part)))
    .join("");
}

function markdownInlineToText(markdown: string): string {
  const codeSpans: string[] = [];
  const withoutCode = markdown.replace(/`([^`]+)`/g, (_match, code: string) => {
    const token = `CMUXCODESPAN${codeSpans.length}TOKEN`;
    codeSpans.push(code);
    return token;
  });

  const text = withoutCode
    .replace(/!\[([^\]]*)]\(([^)]+)\)/g, (_match, label: string, url: string) =>
      label ? `${label} (${url})` : url,
    )
    .replace(/\[([^\]]+)]\(([^)]+)\)/g, (_match, label: string, url: string) =>
      `${label} (${url})`,
    )
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/(^|[^\w])__([^_\n]+)__([^\w]|$)/g, "$1$2$3")
    .replace(/\*([^*]+)\*/g, "$1")
    .replace(/(^|[^\w])_([^_\n]+)_([^\w]|$)/g, "$1$2$3");

  return codeSpans.reduce(
    (current, code, index) =>
      current.replace(`CMUXCODESPAN${index}TOKEN`, code),
    text,
  );
}

function tableCellsFromMarkdownLine(line: string): string[] | null {
  if (!line.includes("|") || isMarkdownTableDivider(line)) {
    return null;
  }

  const trimmed = line.trim();
  if (!trimmed.startsWith("|") && !trimmed.endsWith("|")) {
    return null;
  }

  return trimmed
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function isMarkdownTableDivider(line: string): boolean {
  return /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(line);
}

function ensureMarkdownTitle(markdown: string, title: string): string {
  const titleHeading = `# ${title}`;
  if (!markdown) {
    return titleHeading;
  }

  const lines = markdown.split("\n");
  const firstContentIndex = lines.findIndex((line) => line.trim() !== "");
  const firstContentLine =
    firstContentIndex === -1 ? "" : lines[firstContentIndex].trim();
  if (isMatchingTopLevelHeading(firstContentLine, title)) {
    return markdown;
  }

  const matchingHeadingIndex = lines.findIndex((line) =>
    isMatchingTopLevelHeading(line.trim(), title),
  );
  if (matchingHeadingIndex !== -1) {
    lines.splice(matchingHeadingIndex, 1);
  }

  const remaining = lines.join("\n").trim();
  return remaining ? `${titleHeading}\n\n${remaining}` : titleHeading;
}

function isMatchingTopLevelHeading(line: string, title: string): boolean {
  const match = line.match(/^#\s+(.+)$/);
  return match ? normalizeTitle(match[1]) === normalizeTitle(title) : false;
}

function normalizeTitle(title: string): string {
  return markdownInlineToText(title).replace(/\s+/g, " ").trim().toLowerCase();
}

function prepareReadableHtml(html: string, baseUrl: string): string {
  return spaceAdjacentAnchors(absolutizeUrls(html, baseUrl));
}

function absolutizeUrls(html: string, baseUrl: string): string {
  return html.replace(
    /\s(href|src)=(["'])([^"']*)\2/g,
    (match, attribute: string, quote: string, value: string) => {
      if (!value || /^(?:[a-z][a-z\d+\-.]*:|\/\/)/i.test(value)) {
        return match;
      }

      try {
        return ` ${attribute}=${quote}${new URL(value, baseUrl).toString()}${quote}`;
      } catch {
        return match;
      }
    },
  );
}

function spaceAdjacentAnchors(html: string): string {
  return html.replace(/<\/a>(\s*)<a\b/g, "</a> <a");
}
