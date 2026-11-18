import { Fragment, type ReactNode, createElement } from "react";

/**
 * A small Markdown renderer for listing READMEs, safe by construction: it builds React
 * elements (never HTML strings), so text is always escaped. It covers what READMEs use:
 * headings, paragraphs, emphasis, code spans and fenced code, links, images, lists with
 * task items, block quotes, rules and GitHub tables. Raw HTML keeps only a short list of
 * tags (img, a, p, div, br, details, summary, picture, source, b, i, em, strong, code,
 * kbd, sub, sup, h1-h6) with a few harmless attributes; every other tag is dropped, and
 * script, style, iframe and similar drop their content too. Every URL goes through
 * `url(href, kind)`, which returns null to drop it.
 */

export type UrlKind = "link" | "image";
export type UrlRewriter = (href: string, kind: UrlKind) => string | null;

type Node = string | { tag: string; attrs: Record<string, string>; children: Node[] };

const ALLOWED_TAGS = new Set([
  "a", "b", "br", "code", "details", "div", "em", "h1", "h2", "h3", "h4", "h5", "h6", "i", "img",
  "kbd", "p", "picture", "source", "strong", "sub", "summary", "sup",
]);
const VOID_TAGS = new Set(["br", "img", "source", "hr"]);
/** Tags whose content is never shown. */
const DROPPED_WITH_CONTENT = new Set(["script", "style", "iframe", "object", "embed", "noscript", "template", "textarea", "svg", "math"]);
const ALLOWED_ATTRS: Record<string, readonly string[]> = {
  a: ["href", "title"],
  img: ["src", "alt", "title", "width", "height", "align"],
  source: ["srcset", "media"],
  p: ["align"],
  div: ["align"],
  h1: ["align"],
  h2: ["align"],
  h3: ["align"],
  details: ["open"],
};
const SIZE = /^\d{1,4}%?$/;
const ALIGN = /^(left|right|center)$/i;

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", copy: "©" };

export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]{1,6}|#[0-9]{1,7}|[a-z]{2,6});/gi, (match, code: string) => {
    if (code[0] === "#") {
      const value = code[1] === "x" || code[1] === "X" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return value > 0 && value <= 0x10ffff ? String.fromCodePoint(value) : match;
    }
    return ENTITIES[code.toLowerCase()] ?? match;
  });
}

// ---------------------------------------------------------------- inline

/** Inline Markdown (and inline HTML) into nodes. */
export function parseInline(text: string): Node[] {
  const nodes: Node[] = [];
  let index = 0;
  let plain = "";
  const flush = () => {
    if (plain) nodes.push(decodeEntities(plain));
    plain = "";
  };
  while (index < text.length) {
    const match = inlineAt(text, index);
    if (match) {
      flush();
      nodes.push(...match.nodes);
      index = match.end;
    } else {
      plain += text[index];
      index += 1;
    }
  }
  flush();
  return nodes;
}

type InlineMatch = { nodes: Node[]; end: number };
type InlineRule = (text: string, at: number) => InlineMatch | null;

const INLINE_RULES: InlineRule[] = [escapeRule, codeSpanRule, imageRule, linkRule, autolinkRule, bareUrlRule, emphasisRule, breakRule];

function inlineAt(text: string, at: number): InlineMatch | null {
  for (const rule of INLINE_RULES) {
    const match = rule(text, at);
    if (match) return match;
  }
  return null;
}

function escapeRule(text: string, at: number): InlineMatch | null {
  if (text[at] !== "\\" || !/[\\`*_{}[\]()#+\-.!<>|~]/.test(text[at + 1] ?? "")) return null;
  return { nodes: [text[at + 1]!], end: at + 2 };
}

function codeSpanRule(text: string, at: number): InlineMatch | null {
  if (text[at] !== "`") return null;
  const ticks = /^`+/.exec(text.slice(at))![0];
  const close = text.indexOf(ticks, at + ticks.length);
  if (close < 0) return null;
  const code = text.slice(at + ticks.length, close).replace(/^ (.+) $/, "$1");
  return { nodes: [{ tag: "code", attrs: {}, children: [code] }], end: close + ticks.length };
}

/** `[text](href "title")` at `at` (after an optional `!`): the bracket text, href and end. */
function bracketLink(text: string, at: number): { label: string; href: string; title?: string; end: number } | null {
  if (text[at] !== "[") return null;
  let depth = 0;
  let close = -1;
  for (let i = at; i < text.length; i += 1) {
    if (text[i] === "\\") i += 1;
    else if (text[i] === "[") depth += 1;
    else if (text[i] === "]" && --depth === 0) {
      close = i;
      break;
    }
  }
  if (close < 0 || text[close + 1] !== "(") return null;
  const target = /^\(\s*<?([^\s)>]*)>?(?:\s+"([^"]*)")?\s*\)/.exec(text.slice(close + 1));
  if (!target) return null;
  return { label: text.slice(at + 1, close), href: target[1]!, title: target[2], end: close + 1 + target[0].length };
}

function imageRule(text: string, at: number): InlineMatch | null {
  if (text[at] !== "!") return null;
  const link = bracketLink(text, at + 1);
  if (!link) return null;
  const attrs: Record<string, string> = { src: link.href, alt: decodeEntities(link.label) };
  if (link.title) attrs.title = link.title;
  return { nodes: [{ tag: "img", attrs, children: [] }], end: link.end };
}

function linkRule(text: string, at: number): InlineMatch | null {
  const link = bracketLink(text, at);
  if (!link) return null;
  const attrs: Record<string, string> = { href: link.href };
  if (link.title) attrs.title = link.title;
  return { nodes: [{ tag: "a", attrs, children: parseInline(link.label) }], end: link.end };
}

function autolinkRule(text: string, at: number): InlineMatch | null {
  if (text[at] !== "<") return null;
  const auto = /^<(https?:\/\/[^\s<>]+)>/.exec(text.slice(at));
  if (auto) return { nodes: [{ tag: "a", attrs: { href: auto[1]! }, children: [auto[1]!] }], end: at + auto[0].length };
  return htmlTagRule(text, at);
}

function bareUrlRule(text: string, at: number): InlineMatch | null {
  if (text[at] !== "h" || (at > 0 && /[\w/"'=]/.test(text[at - 1]!))) return null;
  const url = /^https:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/.exec(text.slice(at));
  if (!url) return null;
  return { nodes: [{ tag: "a", attrs: { href: url[0] }, children: [url[0]] }], end: at + url[0].length };
}

const EMPHASIS: Array<{ marker: string; tag: string }> = [
  { marker: "**", tag: "strong" },
  { marker: "__", tag: "strong" },
  { marker: "~~", tag: "del" },
  { marker: "*", tag: "em" },
  { marker: "_", tag: "em" },
];

function emphasisRule(text: string, at: number): InlineMatch | null {
  for (const { marker, tag } of EMPHASIS) {
    if (!text.startsWith(marker, at) || /\s/.test(text[at + marker.length] ?? " ")) continue;
    // `_` inside a word (snake_case) is not emphasis.
    if (marker[0] === "_" && at > 0 && /\w/.test(text[at - 1]!)) continue;
    const close = findCloser(text, at + marker.length, marker);
    if (close < 0) continue;
    return { nodes: [{ tag, attrs: {}, children: parseInline(text.slice(at + marker.length, close)) }], end: close + marker.length };
  }
  return null;
}

function findCloser(text: string, from: number, marker: string): number {
  for (let i = from; i < text.length; i += 1) {
    if (text[i] === "\\" || text[i] === "`") {
      i = text[i] === "`" ? Math.max(i, text.indexOf("`", i + 1)) : i + 1;
      if (i < 0) return -1;
      continue;
    }
    if (text.startsWith(marker, i) && !/\s/.test(text[i - 1] ?? " ") && !(marker[0] === "_" && /\w/.test(text[i + marker.length] ?? ""))) return i;
  }
  return -1;
}

function breakRule(text: string, at: number): InlineMatch | null {
  const hard = /^( {2,}|\\)\n/.exec(text.slice(at));
  if (hard) return { nodes: [{ tag: "br", attrs: {}, children: [] }], end: at + hard[0].length };
  return null;
}

// ---------------------------------------------------------------- inline HTML

const TAG = /^<(\/?)([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[a-zA-Z_:][-a-zA-Z0-9_:.]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(\/?)>/;
const ATTR = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
const COMMENT = /^<!--[\s\S]*?-->/;

function parseAttrs(source: string, tag: string): Record<string, string> {
  const allowed = ALLOWED_ATTRS[tag] ?? [];
  const attrs: Record<string, string> = {};
  for (const match of source.matchAll(ATTR)) {
    const name = match[1]!.toLowerCase();
    if (!allowed.includes(name)) continue;
    attrs[name] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? "");
  }
  return attrs;
}

/**
 * One HTML tag (or comment) at `at`. An allowed opening tag takes everything up to its
 * closing tag as children; a dropped tag renders nothing (and, for script and the like,
 * swallows its content).
 */
function htmlTagRule(text: string, at: number): InlineMatch | null {
  const comment = COMMENT.exec(text.slice(at));
  if (comment) return { nodes: [], end: at + comment[0].length };
  const tag = TAG.exec(text.slice(at));
  if (!tag) return null;
  const [whole, closing, rawName, attrSource, selfClosing] = tag;
  const name = rawName!.toLowerCase();
  const end = at + whole.length;
  if (closing) return { nodes: [], end };
  if (DROPPED_WITH_CONTENT.has(name)) {
    const close = text.toLowerCase().indexOf(`</${name}`, end);
    const after = close < 0 ? text.length : text.indexOf(">", close) + 1 || text.length;
    return { nodes: [], end: after };
  }
  if (!ALLOWED_TAGS.has(name)) return { nodes: [], end };
  const attrs = parseAttrs(attrSource ?? "", name);
  if (VOID_TAGS.has(name) || selfClosing) return { nodes: [{ tag: name, attrs, children: [] }], end };
  const close = findClosingTag(text, end, name);
  const inner = text.slice(end, close.start);
  return { nodes: [{ tag: name, attrs, children: parseHtmlContent(inner) }], end: close.end };
}

/** The matching `</name>` after `from`, counting nested `<name>`; the text end when there is none. */
function findClosingTag(text: string, from: number, name: string): { start: number; end: number } {
  const pattern = new RegExp(`<(/?)${name}\\b[^>]*>`, "gi");
  pattern.lastIndex = from;
  let depth = 1;
  for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
    depth += match[1] ? -1 : 1;
    if (depth === 0) return { start: match.index, end: match.index + match[0].length };
  }
  return { start: text.length, end: text.length };
}

/** The content of an HTML element: Markdown blocks when it has blank lines, else inline. */
function parseHtmlContent(inner: string): Node[] {
  return /\n\s*\n/.test(inner) ? parseBlocks(inner) : parseInline(inner.trim());
}

// ---------------------------------------------------------------- blocks

type BlockMatch = { nodes: Node[]; next: number };
type BlockRule = (lines: string[], at: number) => BlockMatch | null;

const BLOCK_RULES: BlockRule[] = [fenceRule, headingRule, ruleRule, quoteRule, listRule, tableRule, htmlBlockRule];

export function parseBlocks(source: string): Node[] {
  const lines = source.replace(/\r\n?/g, "\n").replace(/\t/g, "    ").split("\n");
  const nodes: Node[] = [];
  let at = 0;
  while (at < lines.length) {
    if (lines[at]!.trim() === "") {
      at += 1;
      continue;
    }
    const block = blockAt(lines, at) ?? paragraph(lines, at);
    nodes.push(...block.nodes);
    at = block.next;
  }
  return nodes;
}

function blockAt(lines: string[], at: number): BlockMatch | null {
  for (const rule of BLOCK_RULES) {
    const block = rule(lines, at);
    if (block) return block;
  }
  return null;
}

function paragraph(lines: string[], at: number): BlockMatch {
  const body: string[] = [];
  let next = at;
  while (next < lines.length && lines[next]!.trim() !== "" && (next === at || !blockAt(lines, next))) {
    body.push(lines[next]!);
    next += 1;
  }
  const setext = /^(=+|-+)\s*$/.exec(lines[next] ?? "");
  if (setext && body.length > 0) {
    return { nodes: [{ tag: setext[1]![0] === "=" ? "h1" : "h2", attrs: {}, children: parseInline(body.join(" ").trim()) }], next: next + 1 };
  }
  return { nodes: [{ tag: "p", attrs: {}, children: parseInline(body.map((line) => line.replace(/^ +/, "")).join("\n")) }], next };
}

function fenceRule(lines: string[], at: number): BlockMatch | null {
  const open = /^ {0,3}(`{3,}|~{3,})\s*([\w+-]*)/.exec(lines[at]!);
  if (!open) return null;
  const fence = open[1]!;
  let next = at + 1;
  const body: string[] = [];
  while (next < lines.length && !lines[next]!.trimStart().startsWith(fence)) {
    body.push(lines[next]!);
    next += 1;
  }
  const code: Node = { tag: "code", attrs: open[2] ? { "data-language": open[2] } : {}, children: [body.join("\n")] };
  return { nodes: [{ tag: "pre", attrs: {}, children: [code] }], next: next + 1 };
}

function headingRule(lines: string[], at: number): BlockMatch | null {
  const heading = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(lines[at]!);
  if (!heading) return null;
  return { nodes: [{ tag: `h${heading[1]!.length}`, attrs: {}, children: parseInline(heading[2]!) }], next: at + 1 };
}

function ruleRule(lines: string[], at: number): BlockMatch | null {
  if (!/^ {0,3}([-*_])(\s*\1){2,}\s*$/.test(lines[at]!)) return null;
  return { nodes: [{ tag: "hr", attrs: {}, children: [] }], next: at + 1 };
}

function quoteRule(lines: string[], at: number): BlockMatch | null {
  if (!/^ {0,3}>/.test(lines[at]!)) return null;
  const body: string[] = [];
  let next = at;
  while (next < lines.length && /^ {0,3}>/.test(lines[next]!)) {
    body.push(lines[next]!.replace(/^ {0,3}> ?/, ""));
    next += 1;
  }
  return { nodes: [{ tag: "blockquote", attrs: {}, children: parseBlocks(body.join("\n")) }], next };
}

const LIST_ITEM = /^( {0,3})([-*+]|\d{1,9}[.)])\s+(.*)$/;

function listRule(lines: string[], at: number): BlockMatch | null {
  const first = LIST_ITEM.exec(lines[at]!);
  if (!first) return null;
  const ordered = /\d/.test(first[2]!);
  const items: string[][] = [];
  let next = at;
  while (next < lines.length) {
    const line = lines[next]!;
    const item = LIST_ITEM.exec(line);
    if (item && /\d/.test(item[2]!) === ordered && item[1]!.length <= first[1]!.length + 1) {
      items.push([item[3]!]);
    } else if (line.trim() === "" ? /^\s{2,}\S/.test(lines[next + 1] ?? "") : /^\s{2,}/.test(line) || !blockAt(lines, next)) {
      items[items.length - 1]!.push(line.replace(/^ {2,4}/, ""));
    } else {
      break;
    }
    next += 1;
  }
  const children = items.map((item) => listItem(item));
  const attrs: Record<string, string> = ordered && first[2] !== "1." && first[2] !== "1)" ? { start: String(parseInt(first[2]!, 10)) } : {};
  return { nodes: [{ tag: ordered ? "ol" : "ul", attrs, children }], next };
}

function listItem(lines: string[]): Node {
  const task = /^\[([ xX])\]\s+/.exec(lines[0]!);
  const text = task ? [lines[0]!.slice(task[0].length), ...lines.slice(1)] : lines;
  const loose = text.some((line) => line.trim() === "");
  const body = loose || text.slice(1).some((line) => LIST_ITEM.test(line)) ? parseBlocks(text.join("\n")) : parseInline(text.join("\n"));
  const unwrapped = !loose && body.length > 0 && typeof body[0] !== "string" && body[0]!.tag === "p" ? [...body[0]!.children, ...body.slice(1)] : body;
  if (!task) return { tag: "li", attrs: {}, children: unwrapped };
  const box: Node = { tag: "input", attrs: { type: "checkbox", disabled: "", ...(task[1] !== " " ? { checked: "" } : {}) }, children: [] };
  return { tag: "li", attrs: { class: "task-list-item" }, children: [box, " ", ...unwrapped] };
}

function tableCells(line: string): string[] {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split(/(?<!\\)\|/).map((cell) => cell.trim());
}

function tableRule(lines: string[], at: number): BlockMatch | null {
  if (!lines[at]!.includes("|") || !/^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(lines[at + 1] ?? "")) return null;
  const header = tableCells(lines[at]!);
  const aligns = tableCells(lines[at + 1]!).map((cell) => (cell.endsWith(":") ? (cell.startsWith(":") ? "center" : "right") : cell.startsWith(":") ? "left" : ""));
  const cell = (tag: string, text: string, index: number): Node => ({
    tag,
    attrs: aligns[index] ? { align: aligns[index]! } : {},
    children: parseInline(text),
  });
  const rows: Node[] = [];
  let next = at + 2;
  while (next < lines.length && lines[next]!.includes("|") && lines[next]!.trim() !== "") {
    const cells = tableCells(lines[next]!);
    rows.push({ tag: "tr", attrs: {}, children: header.map((_, index) => cell("td", cells[index] ?? "", index)) });
    next += 1;
  }
  const head: Node = { tag: "thead", attrs: {}, children: [{ tag: "tr", attrs: {}, children: header.map((text, index) => cell("th", text, index)) }] };
  return { nodes: [{ tag: "table", attrs: {}, children: [head, { tag: "tbody", attrs: {}, children: rows }] }], next };
}

function htmlBlockRule(lines: string[], at: number): BlockMatch | null {
  if (!/^ {0,3}<(!--|\/?[a-zA-Z][a-zA-Z0-9-]*[\s/>]|\/?[a-zA-Z][a-zA-Z0-9-]*$)/.test(lines[at]!)) return null;
  const body: string[] = [];
  let next = at;
  while (next < lines.length && lines[next]!.trim() !== "") {
    body.push(lines[next]!);
    next += 1;
  }
  return { nodes: parseInline(body.join("\n")), next };
}

// ---------------------------------------------------------------- render

const URL_ATTRS: Record<string, UrlKind> = { href: "link", src: "image" };
const REACT_ATTR: Record<string, string> = { class: "className", srcset: "srcSet" };

/** One HTML attribute as a React prop: URLs are rewritten, sizes and alignment validated; null drops it. */
function attrProp(name: string, value: string, url: UrlRewriter): [string, unknown] | null {
  const urlKind = URL_ATTRS[name];
  if (urlKind) {
    const rewritten = url(value, urlKind);
    return rewritten === null ? null : [name, rewritten];
  }
  if (name === "srcset") {
    const first = url(value.trim().split(/\s+/)[0] ?? "", "image");
    return first === null ? null : ["srcSet", first];
  }
  if ((name === "width" || name === "height") && !SIZE.test(value)) return null;
  if (name === "align" && !ALIGN.test(value)) return null;
  if (name === "checked") return ["defaultChecked", true];
  if (name === "disabled" || name === "open") return [name, true];
  return [REACT_ATTR[name] ?? name, value];
}

function renderAttrs(node: Exclude<Node, string>, url: UrlRewriter): Record<string, unknown> | null {
  const props: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(node.attrs)) {
    const prop = attrProp(name, value, url);
    if (prop) props[prop[0]] = prop[1];
  }
  if (node.tag === "img" && !props.src) return null;
  if (node.tag === "a" && typeof props.href === "string" && !props.href.startsWith("#")) props.rel = "nofollow ugc noopener noreferrer";
  if (node.tag === "img") Object.assign(props, { loading: "lazy", decoding: "async", referrerPolicy: "no-referrer" });
  return props;
}

function renderNodes(nodes: readonly Node[], url: UrlRewriter, prefix = ""): ReactNode[] {
  return nodes.map((node, index) => {
    const key = `${prefix}${index}`;
    if (typeof node === "string") return <Fragment key={key}>{node}</Fragment>;
    const props = renderAttrs(node, url);
    if (props === null) return null;
    const children = VOID_TAGS.has(node.tag) || node.tag === "input" ? undefined : renderNodes(node.children, url, `${key}.`);
    return createElement(node.tag, { key, ...props, ...(node.tag === "input" ? { readOnly: true } : {}) }, children);
  });
}

export function Markdown({ source, url }: { source: string; url: UrlRewriter }) {
  return <>{renderNodes(parseBlocks(source), url)}</>;
}
