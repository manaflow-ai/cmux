import { ArxivMark, GitHubMark, Globe } from "./icons";
import { FileKindIcon } from "../chips/FileKindIcon";
import { fenceStep } from "./fenceRule";
import { closesFence, fenceOpening } from "../slashCommands";
import { normalizeMath } from "./mathDelimiters";
import { decorateTimes } from "./timeHoverModel";

export type Align = "left" | "center" | "right" | null;

export type MdBlock =
  | { type: "heading"; level: 1 | 2 | 3 | 4 | 5 | 6; text: string }
  | { type: "paragraph"; text: string }
  | { type: "hr" }
  | { type: "blockquote"; children: MdBlock[] }
  | { type: "list"; ordered: boolean; start: number; items: MdListItem[] }
  | { type: "table"; align: Align[]; header: string[]; rows: string[][] }
  /** `open`: the fence has no closing line yet (a streaming or cut reply). */
  | { type: "code"; lang: string; code: string; open?: true }
  | { type: "math"; tex: string }
  /** `[^id]: text`, drawn in the notes under the reply (`Markdown`), not where it is written. */
  | { type: "footnote"; id: string; text: string };

export type MdListItem = { text: string; task?: boolean; checked?: boolean; children: MdBlock[] };

const LIST_RE = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;

/// A paragraph's lines, each break kept, except one inside a reference: a line that ends with
/// `repo#` and one that starts with its number are one `repo#N`, so it links and wraps whole.
function joinParagraph(lines: string[]): string {
  return lines.reduce((text, line) =>
    /(?:^|[^\s#])#$/.test(text) && /^\d/.test(line) ? text + line : `${text}\n${line}`,
  );
}

/// Whether a line starts a list inside a paragraph. A numbered line does so only from 1, as
/// CommonMark and GitHub read it: a reply wrapped as "the cards (cmux#\n29613) and the fix" kept
/// its text, where reading "29613)" as a list's number drew it bold over "and" (Leo 2026-10-31:
/// "WTF HAPPENED WITH THIS" / "F***ING TEXT????").
function interruptsParagraph(line: string): boolean {
  const m = LIST_RE.exec(line);
  return Boolean(m && (!/\d/.test(m[2]!) || parseInt(m[2]!, 10) === 1));
}

/// The deepest nesting of quotes and lists the parser builds. A reply is untrusted, and each level
/// costs stack while it draws (800 list levels overflowed it), so content below this depth draws
/// as the plain text of one paragraph.
export const MAX_NESTING = 32;
const FOOTNOTE_DEF = /^\[\^([\w-]+)\]:\s*(.*)$/;

/** Parse the supported Markdown subset into blocks. */
/// `commonmark`: fences read as CommonMark reads them (slashCommands.ts fenceOpening and closesFence:
/// tildes too, at most three spaces of indent, no backtick in a backtick fence's info string), as a
/// sent prompt's are, so its code is what send reads as code.
export function parseMarkdown(src: string, options: { messageAt?: number; commonmark?: boolean } = {}): MdBlock[] {
  const lines = normalizeMath(src.replace(/\r\n?/g, "\n").split("\n"));
  const blocks = parseLines(lines, 0, options.commonmark === true);
  return options.messageAt === undefined ? blocks : decorateBlocks(blocks, options.messageAt);
}

function decorateBlocks(blocks: MdBlock[], messageAt?: number): MdBlock[] {
  return blocks.map((block) => {
    switch (block.type) {
      case "heading":
      case "paragraph":
        return { ...block, text: decorateTimes(block.text, messageAt) };
      case "blockquote":
        return { ...block, children: decorateBlocks(block.children, messageAt) };
      case "list":
        return {
          ...block,
          items: block.items.map((item) => ({
            ...item,
            text: decorateTimes(item.text, messageAt),
            children: decorateBlocks(item.children, messageAt),
          })),
        };
      case "table":
        return {
          ...block,
          header: block.header.map((cell) => decorateTimes(cell, messageAt)),
          rows: block.rows.map((row) => row.map((cell) => decorateTimes(cell, messageAt))),
        };
      case "footnote":
        return { ...block, text: decorateTimes(block.text, messageAt) };
      case "code":
      case "math":
      case "hr":
        return block;
    }
  });
}

/// `depth`: how many quotes and lists hold these lines (MAX_NESTING).
function parseLines(lines: string[], depth = 0, commonmark = false): MdBlock[] {
  const out: MdBlock[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i++;
      continue;
    }
    const opening = commonmark ? fenceOpening(line) : undefined;
    if (opening) {
      const body: string[] = [];
      i++;
      while (i < lines.length && !closesFence(lines[i], opening.mark)) body.push(lines[i++]);
      const open = i >= lines.length;
      i++;
      out.push({
        type: "code",
        lang: opening.info.trim().split(/\s/)[0] || "text",
        code: body.join("\n"),
        ...(open ? { open: true as const } : {}),
      });
      continue;
    }
    // A fence is three or more backticks and closes on a line of at least as many (a reply that
    // quotes Markdown opens with four to show its own three).
    const fence = commonmark ? null : line.match(/^\s*(`{3,})([^\s`]*)[^`]*$/);
    if (fence) {
      const body: string[] = [];
      const closer = new RegExp(`^\\s*\`{${fence[1]!.length},}\\s*$`);
      i++;
      while (i < lines.length && !closer.test(lines[i])) body.push(lines[i++]);
      const open = i >= lines.length;
      i++;
      out.push({
        type: "code",
        lang: fence[2] || "text",
        code: body.join("\n"),
        ...(open ? { open: true as const } : {}),
      });
      continue;
    }
    const display = displayMath(lines, i);
    if (display) {
      out.push({ type: "math", tex: display.tex });
      i = display.next;
      continue;
    }
    const note = line.match(FOOTNOTE_DEF);
    if (note) {
      // Lines indented under the definition continue it.
      const text = [note[2]!];
      i++;
      while (i < lines.length && /^\s{2,}\S/.test(lines[i]!)) text.push(lines[i++]!.trim());
      out.push({ type: "footnote", id: note[1]!, text: text.join(" ").trim() });
      continue;
    }
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      out.push({ type: "heading", level: h[1].length as 1 | 2 | 3 | 4 | 5 | 6, text: h[2] });
      i++;
      continue;
    }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
      out.push({ type: "hr" });
      i++;
      continue;
    }
    if (/^\s*>/.test(line)) {
      const body: string[] = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) body.push(lines[i++].replace(/^\s*>\s?/, ""));
      out.push({ type: "blockquote", children: nested(body, depth + 1, commonmark) });
      continue;
    }
    if (
      line.includes("|") &&
      i + 1 < lines.length &&
      /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])
    ) {
      // An escaped pipe (`\|`) is a literal one inside its cell, not a column break.
      const cells = (l: string) =>
        l
          .trim()
          .replace(/^\|/, "")
          .replace(/(?<!\\)\|$/, "")
          .split(/(?<!\\)\|/)
          .map((c) => c.replace(/\\\|/g, "|").trim());
      const header = cells(line);
      const align = cells(lines[i + 1]).map<Align>((c) =>
        c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : c.startsWith(":") ? "left" : null,
      );
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim()) rows.push(cells(lines[i++]));
      out.push({ type: "table", align, header, rows });
      continue;
    }
    if (LIST_RE.test(line)) {
      const [block, next] = parseList(lines, i, depth, commonmark);
      out.push(block);
      i = next;
      continue;
    }
    // The first line is the paragraph's even when it opens like a block that did not parse
    // (a lone `$$`, a half-streamed fence), so the parser always advances.
    const para: string[] = [lines[i++].trim()];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^(#{1,6})\s/.test(lines[i]) &&
      !FOOTNOTE_DEF.test(lines[i]) &&
      (commonmark ? !fenceOpening(lines[i]) : fenceStep(0, lines[i]) === 0) &&
      !/^\s*\$\$/.test(lines[i]) &&
      !/^\s*>/.test(lines[i]) &&
      !interruptsParagraph(lines[i])
    )
      para.push(lines[i++].trim());
    out.push({ type: "paragraph", text: joinParagraph(para) });
  }
  return out;
}

/// A display equation starting at `lines[start]`: `$$…$$` on one line, or `$$` opening a block
/// whose last line ends with `$$` (`\[ … \]` was rewritten to these by normalizeMath). A line
/// with more text after its closing `$$` is a paragraph (the equation draws inline), and an
/// opener that never closes is too.
function displayMath(lines: string[], start: number): { tex: string; next: number } | null {
  const open = lines[start]!.match(/^\s*\$\$(.*)$/);
  if (!open) return null;
  const rest = open[1]!;
  const closeIndex = rest.indexOf("$$");
  if (closeIndex >= 0) {
    if (rest.slice(closeIndex + 2).trim() || !rest.slice(0, closeIndex).trim()) return null;
    return { tex: rest.slice(0, closeIndex).trim(), next: start + 1 };
  }
  const body = [rest];
  for (let j = start + 1; j < lines.length; j++) {
    const line = lines[j]!;
    const close = line.indexOf("$$");
    if (close < 0) {
      body.push(line);
      continue;
    }
    if (line.slice(close + 2).trim()) return null;
    body.push(line.slice(0, close));
    const tex = body.join("\n").trim();
    return tex ? { tex, next: j + 1 } : null;
  }
  return null;
}

function indentOf(l: string) {
  return l.match(/^\s*/)![0].replace(/\t/g, "    ").length;
}

/// The blocks of lines nested `depth` levels down, or their text as one paragraph at the cap.
function nested(lines: string[], depth: number, commonmark = false): MdBlock[] {
  if (depth < MAX_NESTING) return parseLines(lines, depth, commonmark);
  const text = lines
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n");
  return text ? [{ type: "paragraph", text }] : [];
}

function parseList(lines: string[], start: number, depth: number, commonmark = false): [MdBlock, number] {
  const first = lines[start].match(LIST_RE)!;
  const base = indentOf(lines[start]);
  const ordered = /\d/.test(first[2]);
  const items: MdListItem[] = [];
  let i = start;
  while (i < lines.length) {
    const l = lines[i];
    if (!l.trim()) {
      // A blank line ends the list unless the next line continues it.
      const n = lines[i + 1];
      if (n && LIST_RE.test(n) && indentOf(n) >= base) {
        i++;
        continue;
      }
      break;
    }
    const m = l.match(LIST_RE);
    const ind = indentOf(l);
    if (m && ind === base && /\d/.test(m[2]) === ordered) {
      let text = m[3];
      const task = text.match(/^\[( |x|X)\]\s+(.*)$/);
      const item: MdListItem = task
        ? { text: task[2], task: true, checked: task[1] !== " ", children: [] }
        : { text, children: [] };
      i++;
      // Nested content: lines indented deeper than the marker.
      const inner: string[] = [];
      while (i < lines.length && lines[i].trim() && indentOf(lines[i]) > base) inner.push(lines[i++]);
      if (inner.length) {
        const strip = Math.min(...inner.map(indentOf));
        item.children = nested(
          inner.map((n) => n.slice(strip)),
          depth + 1,
          commonmark,
        );
      }
      items.push(item);
      continue;
    }
    break;
  }
  const startNum = ordered ? parseInt(first[2], 10) : 1;
  return [{ type: "list", ordered, start: startNum, items }, i];
}

/// Footnotes are numbered in the order the reply first refers to them, so a number never
/// changes as the reply streams (a note's definition usually arrives last). Code is skipped, and
/// so is a label shaped like a regex class (`[^a-z]`), which prose writes outside code too.
export function footnoteOrder(source: string): string[] {
  // A reference needs "[" and "^"; the scan below only deletes text, so without both there is none.
  // A streaming reply runs this on every reveal frame, and most replies have no footnote.
  if (!source.includes("^") || !source.includes("[")) return [];
  const prose = source.replace(/^\s*```[\s\S]*?(?:^\s*```|(?![\s\S]))/gm, "").replace(/(`+)[^`]*?\1/g, "");
  const ids: string[] = [];
  for (const match of prose.matchAll(/\[\^([\w-]+)\](?!:)/g)) {
    const id = match[1]!;
    if (!/^\w-\w$/.test(id) && !ids.includes(id)) ids.push(id);
  }
  return ids;
}

/// An image's source the pane can show: a data URL of a raster or SVG image. The pane's CSP
/// loads no other image, so a web image draws as a link to it.
export const INLINE_IMAGE = /^data:image\/(?:png|jpe?g|gif|webp|svg\+xml);/i;
/// The longest data URL an image draws from (2 MB of text); a longer one draws as its name only,
/// so a reply cannot make the pane decode and hold an arbitrarily large image.
export const MAX_DATA_URL_LENGTH = 2_000_000;
/// What an over-long data URL is replaced with before the inline parser sees it (`capDataUrls`).
export const OVERSIZED_DATA_URL = "data:image/x-cmux-oversized;";
/// A long data URL's short stand-in for the inline parser, `<prefix><index in dataRefs>`: the
/// inline pattern does not match a target of megabytes, so such an image drew as its source.
export const DATA_REF = "data:image/x-cmux-ref;";
const DATA_REF_FROM = 4096;
/// The data URL text one reply may draw in all (8 MB); images after it draw as their name.
export const MAX_REPLY_DATA_URLS = 8_000_000;

/// The data URL image targets of `source` past the reply's budget, in reading order. Each image
/// over MAX_DATA_URL_LENGTH draws as its name anyway and does not count.
export function dataUrlsOverBudget(source: string): Set<string> {
  const over = new Set<string>();
  if (source.length <= MAX_REPLY_DATA_URLS) return over;
  let total = 0;
  for (let at = source.indexOf("](data:image/"); at >= 0; at = source.indexOf("](data:image/", at + 2)) {
    URL_END.lastIndex = at + 2;
    const end = URL_END.exec(source)?.index ?? source.length;
    const url = source.slice(at + 2, end);
    if (url.length > MAX_DATA_URL_LENGTH) continue;
    total += url.length;
    if (total > MAX_REPLY_DATA_URLS) over.add(url);
  }
  return over;
}
const URL_END = /[\s()]/g;

/// `text` with every link or image target that is a data URL over MAX_DATA_URL_LENGTH replaced by
/// OVERSIZED_DATA_URL, in one linear scan. The inline pattern does not match such a long target
/// (it would draw the whole URL as text), and the pane never decodes it.
export function capDataUrls(text: string, refs: string[]): string {
  if (text.length <= DATA_REF_FROM) return text;
  let out = "";
  let from = 0;
  for (let at = text.indexOf("](data:"); at >= 0; at = text.indexOf("](data:", from)) {
    const start = at + 2;
    URL_END.lastIndex = start;
    const end = URL_END.exec(text)?.index ?? text.length;
    const url = text.slice(start, end);
    const short =
      url.length > MAX_DATA_URL_LENGTH
        ? OVERSIZED_DATA_URL
        : url.length > DATA_REF_FROM
          ? `${DATA_REF}${refs.push(url) - 1}`
          : url;
    out += text.slice(from, start) + short;
    from = end;
  }
  return out + text.slice(from);
}

/**
 * A link is marked with its site: GitHub mark, the arXiv favicon (a citation), a file
 * glyph for a local path (`/Users/…/README.md`, `file://…`), or a globe.
 */
export function linkKind(href: string): "github" | "citation" | "file" | "web" {
  if ((href.startsWith("/") && !href.startsWith("//")) || href.startsWith("file:")) return "file";
  if (/github\.com/.test(href)) return "github";
  if (/arxiv\.org/.test(href)) return "citation";
  return "web";
}

export const linkIcon = (href: string) => {
  const kind = linkKind(href);
  if (kind === "github") return <GitHubMark size={14} className="cv-link__icon cv-link__icon--gh" />;
  if (kind === "citation") return <ArxivMark size={16} className="cv-link__icon" />;
  if (kind === "file") return <FileKindIcon path={href} className="cv-link__icon" />;
  return <Globe size={16} className="cv-link__icon" />;
};

// Groups: code, bold, strikethrough, italic, image or link, line break, `$$…$$` inside a
// paragraph (not prose, words and punctuation, beside a space, so the shell's "echo $$ and $$"
// and "echo $$ prints the shell's PID, and echo $$" stay text while
// "$$ E = mc^2 $$" typesets), `$…$` (Pandoc's rule: no space, `(` or `{` after the opener, no
// space before or letter/digit after the closer, so "$PATH and $HOME" and
// `$(cmd)` stay text; no backtick inside, so "$5 or `$PATH`" does too), explicit `\(…\)`, a backslash escape (`\$`, `\*`) that
// draws its character, and a footnote reference (`[^id]`).
export const INLINE_RE =
  /(`[^`]+`)|(\*\*[^*]+\*\*)|(~~[^~]+~~)|((?<![\w*])\*[^*\s][^*]*\*(?![\w*])|(?<![\w_])_[^_\s][^_]*_(?![\w_]))|(!\[[^\]]*\]\((?:[^()\s]|\([^()\s]*\))+\)|\[[^\]]+\]\((?:[^()\s]|\([^()\s]*\))+\))|(\n)|(\$\$(?!\s[A-Za-z\s'’,.;:!?"()-]*\$\$|[A-Za-z\s'’,.;:!?"()-]*\s\$\$)[^$\n]+?\$\$)|(?<![\\$])(\$(?![({])(?=[^\s$])(?:\\.|[^$\\\n`])*?[^\s\\`$]\$(?![A-Za-z0-9])|\\\(.+?\\\))|(\\[\\`*_{}[\]()#+\-.!$|~<>])|(\[\^[\w-]+\](?!:))/g;

/// The data URL images `renderInline(source)` draws, in order: the same pattern, the same
/// recursion into bold, italic, strikethrough and link text (so code never counts), the same
/// stand-ins for long data URLs, and none of the reply's images past its budget (`overBudget`).
export function inlineImages(
  source: string,
  overBudget: ReadonlySet<string> = new Set(),
  outerRefs: string[] = [],
): { src: string; alt: string }[] {
  const found: string[] = [];
  const text = capDataUrls(source, found);
  const refs = found.length ? found : outerRefs;
  const out: { src: string; alt: string }[] = [];
  const inner = (part: string) => inlineImages(part, overBudget, refs);
  for (const m of text.matchAll(INLINE_RE)) {
    const t = m[0];
    if (m[2] || m[3]) out.push(...inner(t.slice(2, -2)));
    else if (m[4]) out.push(...inner(t.slice(1, -1)));
    else if (m[5]?.startsWith("!")) {
      const [, alt = "", written = ""] = t.match(/^!\[([^\]]*)\]\((.+)\)$/) ?? [];
      const src = written.startsWith(DATA_REF) ? (refs[Number(written.slice(DATA_REF.length))] ?? "") : written;
      if (INLINE_IMAGE.test(src) && src.length <= MAX_DATA_URL_LENGTH && !overBudget.has(src)) out.push({ src, alt });
    } else if (m[5]) out.push(...inner(t.match(/^\[([^\]]+)\]/)?.[1] ?? ""));
  }
  return out;
}
