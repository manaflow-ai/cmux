// Rich text on the clipboard, both ways, as Claude and ChatGPT do it (Leo, 2026-11-05: "we need to
// be doing this where you can copy and it's a rich copy of the transcript ... and we don't even
// render bullet points properly in our thing when we're pasting that stuff in").
//
// Out: a reply copies as its Markdown (text/plain) and the same reply as clean HTML (text/html), so
// a paste into Notes, Slack, Docs or Mail keeps headings, bullets, bold, links and code
// (conversation/CopyButton.tsx, conversation/selectionCopy.ts).
// In: a paste into the composer whose HTML or Markdown has lists, headings, quotes, tables or
// fenced code is read as Markdown, so it lands as the same blocks typing "- " makes
// (MarkdownField.tsx `richPaste`). Any other paste stays its plain lines, as before.
import { Marked } from "marked";
import { copyTextResult } from "./conversation/clipboard";
import { safeHref } from "./replyHref";

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
const escapeHtml = (text: string) => text.replace(/[&<>"]/g, (c) => ESCAPES[c]!);

/// A link target the copy may carry into another app: a web link (`safeHref`) or a mail address.
/// Anything else (`javascript:`, `file:`, `data:`, a relative path) copies as the link's words.
export function copyHref(href: string): string | undefined {
  const web = safeHref(href);
  if (web) return web;
  return /^mailto:[^\s]+$/i.test(href.trim()) ? href.trim() : undefined;
}

// A reply's raw HTML is shown as text in the transcript, so it copies as text too, never as markup
// another app would run or draw; a link or picture keeps its target only where `copyHref` allows.
const toHtml = new Marked({
  gfm: true,
  // A line break inside a paragraph is a line in the transcript, so it is one in the copy too.
  breaks: true,
  renderer: {
    html: ({ text }) => escapeHtml(text),
    link(token) {
      const words = this.parser.parseInline(token.tokens);
      const href = copyHref(token.href);
      // l10n-allow: clipboard HTML markup, not words a person reads
      return href ? `<a href="${escapeHtml(href)}">${words}</a>` : words;
    },
    image({ href, text }) {
      const src = safeHref(href);
      // l10n-allow: clipboard HTML markup, not words a person reads
      return src ? `<img src="${escapeHtml(src)}" alt="${escapeHtml(text)}">` : escapeHtml(text);
    },
  },
});

/** `markdown` as the HTML another app pastes: headings, lists, emphasis, links, code and tables. */
export function markdownHtml(markdown: string): string {
  return toHtml.parse(markdown, { async: false });
}

/// Whether `text` is Markdown with blocks a person would want drawn: a list item or a fenced code
/// block on a line of its own. A heading or quote alone stays text (a pasted script's `# comment`).
const MARKDOWN_BLOCK = /^ {0,3}(?:[-*+]|\d{1,9}[.)])[ \t]+\S|^ {0,3}(?:```|~~~)/m;
export const looksLikeMarkdown = (text: string) => MARKDOWN_BLOCK.test(text);

/// HTML with blocks Markdown can hold; a run of paragraphs and line breaks stays plain lines.
const HTML_BLOCK = /<(?:ul|ol|h[1-6]|blockquote|table)\b/i;
export const htmlHasBlocks = (html: string) => HTML_BLOCK.test(html);

const SKIP = /^(STYLE|SCRIPT|META|TITLE|IMG|SVG|BUTTON|TEMPLATE|NOSCRIPT)$/;
const BLOCK = /^(P|DIV|SECTION|ARTICLE|HEADER|FOOTER|MAIN|FIGURE|DL|DT|DD)$/;
/// Any block inside an inline element (Google Docs wraps a whole copy in a <b>) makes it a container.
const HOLDS_BLOCK = "p, div, ul, ol, li, pre, blockquote, table, hr, h1, h2, h3, h4, h5, h6";

/** What `escape` guards in text read from HTML: characters Markdown would take as syntax. */
const escapeText = (text: string) => text.replace(/[\\`*_[\]<]/g, "\\$&");

/**
 * HTML (a web page's, Notes', Docs', Slack's or the transcript's) as Markdown: headings, lists
 * (nested), quotes, fenced code, tables, bold, italics, strikethrough, inline code and links.
 * `escape` writes text's own `*`, `_` and the like escaped, for a parser to read back as text; off,
 * the text is as shown (the clipboard's plain text).
 */
export function htmlMarkdown(html: string, { escape = false } = {}): string {
  const template = document.createElement("template");
  template.innerHTML = html;
  const text = (value: string) => (escape ? escapeText(value) : value);

  const inline = (node: Node): string => {
    if (node.nodeType === Node.TEXT_NODE) return text((node.textContent ?? "").replace(/\s+/g, " "));
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const element = node as HTMLElement;
    const tag = element.tagName;
    if (SKIP.test(tag)) return "";
    if (tag === "BR") return "\n";
    const inner = () => [...element.childNodes].map(inline).join("");
    const wrap = (mark: string) => {
      const body = inner();
      // Markdown marks hug their words: `** a **` is not bold.
      const match = /^(\s*)([\s\S]*?)(\s*)$/.exec(body)!;
      return match[2] ? `${match[1]}${mark}${match[2]}${mark}${match[3]}` : body;
    };
    const style = element.getAttribute("style") ?? "";
    // Google Docs wraps a whole copy in <b style="font-weight:normal"> and marks bold and italics
    // on spans' styles.
    const weight = /font-weight\s*:\s*(\w+)/i.exec(style)?.[1];
    const heavy = weight === "bold" || (weight !== undefined && Number(weight) >= 600);
    if ((tag === "B" || tag === "STRONG") && weight === "normal") return inner();
    if (tag === "B" || tag === "STRONG" || (tag === "SPAN" && heavy)) return wrap("**");
    if (tag === "I" || tag === "EM" || (tag === "SPAN" && /font-style\s*:\s*italic/i.test(style))) return wrap("*");
    if (tag === "S" || tag === "DEL" || tag === "STRIKE") return wrap("~~");
    if (tag === "CODE") {
      const code = element.textContent ?? "";
      const fence = code.includes("`") ? "``" : "`";
      return code ? `${fence}${code}${fence}` : "";
    }
    if (tag === "A") {
      const href = copyHref(element.getAttribute("href") ?? "");
      const body = inner();
      if (!href || !body.trim()) return body;
      return body === href ? href : `[${body}](${href.replace(/[()\s]/g, encodeURIComponent)})`;
    }
    return inner();
  };

  /** Lines of Markdown for `node`'s children, each block a run of lines with a blank line between. */
  const blocks = (parent: Node, depth = 0): string[] => {
    const out: string[] = [];
    let run = "";
    const flush = () => {
      const lines = run.replace(/[ \t]+\n/g, "\n").replace(/^\s+|\s+$/g, "");
      if (lines) out.push(lines);
      run = "";
    };
    for (const node of parent.childNodes) {
      if (node.nodeType !== Node.ELEMENT_NODE) {
        run += inline(node);
        continue;
      }
      const element = node as HTMLElement;
      const tag = element.tagName;
      if (SKIP.test(tag)) continue;
      const heading = /^H([1-6])$/.exec(tag);
      if (heading) {
        flush();
        const title = inline(element).replace(/\s+/g, " ").trim();
        if (title) out.push(`${"#".repeat(Number(heading[1]))} ${title}`);
      } else if (tag === "UL" || tag === "OL") {
        flush();
        out.push(list(element, depth));
      } else if (tag === "PRE") {
        flush();
        const code = (element.textContent ?? "").replace(/\n$/, "");
        const language = /language-([\w+#-]+)/.exec(element.querySelector("code")?.className ?? "")?.[1] ?? "";
        const fence = code.includes("```") ? "~~~~" : "```";
        out.push(`${fence}${language}\n${code}\n${fence}`);
      } else if (tag === "BLOCKQUOTE") {
        flush();
        const quoted = blocks(element, depth).join("\n\n");
        if (quoted) out.push(quoted.replace(/^/gm, "> ").replace(/^> $/gm, ">"));
      } else if (tag === "TABLE") {
        flush();
        out.push(table(element));
      } else if (tag === "HR") {
        flush();
        out.push("---");
      } else if (BLOCK.test(tag) || tag === "LI" || element.querySelector(HOLDS_BLOCK)) {
        flush();
        out.push(...blocks(element, depth));
      } else run += inline(element);
    }
    flush();
    return out;
  };

  const list = (element: HTMLElement, depth: number): string => {
    const ordered = element.tagName === "OL";
    let number = Number(element.getAttribute("start") ?? 1) || 1;
    const items: string[] = [];
    for (const child of element.children) {
      // A nested list Notes or Docs writes beside its items, not inside one.
      if (child.tagName === "UL" || child.tagName === "OL") {
        items.push(list(child as HTMLElement, depth + 1).replace(/^/gm, "   "));
        continue;
      }
      if (child.tagName !== "LI") continue;
      const marker = ordered ? `${number++}. ` : "- ";
      // A tight item (no paragraphs of its own) keeps its nested list on the next line.
      const body = blocks(child, depth + 1).join(child.querySelector(":scope > p") ? "\n\n" : "\n");
      const indent = " ".repeat(marker.length);
      items.push(marker + body.replace(/\n/g, `\n${indent}`).replace(new RegExp(`\n${indent}(?=\n)`, "g"), "\n"));
    }
    return items.join("\n");
  };

  const table = (element: HTMLElement): string => {
    const rows = [...element.querySelectorAll("tr")].map((row) =>
      [...row.querySelectorAll("th, td")].map((cell) => inline(cell).replace(/\s+/g, " ").trim().replace(/\|/g, "\\|")),
    );
    if (!rows.length) return "";
    const count = Math.max(...rows.map((row) => row.length));
    const line = (cells: string[]) => `| ${Array.from({ length: count }, (_, i) => cells[i] ?? "").join(" | ")} |`;
    return [line(rows[0]!), line(Array(count).fill("---")), ...rows.slice(1).map(line)].join("\n");
  };

  return blocks(template.content).join("\n\n");
}

/** Puts `entry`'s types on the clipboard: the async clipboard where the page may use it, else a
 * selection copy that writes every type (a WKWebView page loaded from a file is not always allowed
 * the async clipboard), else its plain text alone (conversation/clipboard.ts): a copy never fails
 * where a plain one would have worked. */
async function copyEntry(entry: Record<string, string>): Promise<boolean> {
  try {
    await navigator.clipboard.write([
      new ClipboardItem(
        Object.fromEntries(Object.entries(entry).map(([type, text]) => [type, new Blob([text], { type })])),
      ),
    ]);
    return true;
  } catch {}
  return copyEvent(entry) || copyTextResult(entry["text/plain"] ?? "");
}

/** A selection copy whose copy event writes every type of `entry`; true when the event wrote them. */
function copyEvent(entry: Record<string, string>): boolean {
  const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const field = document.createElement("textarea");
  let wrote = false;
  const write = (event: ClipboardEvent) => {
    if (!event.clipboardData) return;
    for (const [type, text] of Object.entries(entry)) event.clipboardData.setData(type, text);
    event.preventDefault();
    event.stopImmediatePropagation();
    wrote = true;
  };
  try {
    field.value = entry["text/plain"] ?? "";
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.append(field);
    field.select();
    document.addEventListener("copy", write, true);
    return document.execCommand("copy") && wrote;
  } catch {
    return false;
  } finally {
    document.removeEventListener("copy", write, true);
    field.remove();
    if (previousFocus?.isConnected) previousFocus.focus();
  }
}

/// Copies a message as Claude and ChatGPT do: its Markdown as the plain text, its HTML beside it.
export function copyMarkdownResult(markdown: string): Promise<boolean> {
  return copyEntry({ "text/plain": markdown, "text/html": markdownHtml(markdown) });
}
