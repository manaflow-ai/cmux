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

export function markdownFromHtml({
  html,
  origin,
  sourceUrl,
}: {
  html: string;
  origin: string;
  sourceUrl: string;
}): string {
  const title = extractTitle(html);
  const readableHtml = absolutizeUrls(extractReadableHtml(html), origin);
  const body = cleanMarkdown(turndown.turndown(readableHtml));
  const parts: string[] = [];

  if (title && !body.match(/^#\s+/m)) {
    parts.push(`# ${title}`);
  }
  if (body) {
    parts.push(body);
  }
  parts.push(`Canonical: ${sourceUrl}`);

  return `${parts.join("\n\n")}\n`;
}

export function headersForAgentPage({
  format,
  canonicalUrl,
  contentLanguage,
}: {
  format: AgentPageFormat;
  canonicalUrl: string;
  contentLanguage: string;
}): Headers {
  return new Headers({
    "cache-control": "public, max-age=0, s-maxage=3600, stale-while-revalidate=86400",
    "content-language": contentLanguage,
    "content-type":
      format === "md"
        ? "text/markdown; charset=utf-8"
        : "text/plain; charset=utf-8",
    link: `<${canonicalUrl}>; rel="canonical"`,
    "x-robots-tag": "noindex, follow",
  });
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
  return (
    firstElementInnerHtml(html, "main") ??
    firstElementInnerHtml(html, "body") ??
    html
  );
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

  const title = firstElementInnerHtml(html, "title");
  return title ? cleanPlainText(title) : null;
}

function cleanPlainText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function cleanMarkdown(markdown: string): string {
  return markdown
    .replace(/\r\n/g, "\n")
    .replace(/\)\[/g, ") [")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function absolutizeUrls(html: string, origin: string): string {
  return html.replace(
    /\s(href|src)=(["'])(\/(?!\/)[^"']*)\2/g,
    (_match, attribute: string, quote: string, path: string) =>
      ` ${attribute}=${quote}${origin}${path}${quote}`,
  );
}
