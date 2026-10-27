// Ported from the agent-pane reference prototype (src/conversation/Markdown.tsx).
// A small GFM-subset Markdown renderer for assistant messages. It produces the same
// DOM shape for every transcript: headings, paragraphs (single newlines are line
// breaks), nested ordered/bullet/task lists, blockquotes, rules, aligned tables, fenced
// code blocks rendered by @pierre/diffs (see CodeBlock.tsx), vega-lite charts (DiagramBlock.tsx), live
// ```cmux-render pages (RenderCard.tsx), and `$…$`, `$$…$$`, `\(…\)`
// and `\[…\]` math typeset by KaTeX (see Math.tsx).
import { Fragment, memo, useId, useMemo, useRef, type ReactNode } from "react";
import { useT } from "../i18n";
import { appHref, safeHref } from "../model";
import { needsYouListOff, needsYouTarget, openNeedsYou } from "../needsYou/links";
import { CodeBlock } from "./CodeBlock";
import { TableBlock } from "./TableBlock";
import { DiagramBlock, isChart } from "./DiagramBlock";
import { canRender, RenderCard } from "./RenderCard";
import { renderFence } from "./renderCall";
import { isRemoteMedia, RemoteMedia } from "../chips/ReplyMedia";
import { CodeHandoff, PlainCode } from "./StreamingCode";
import type { Reveal } from "./RevealedMarkdown";
import { ArxivMark, FileDoc, GitHubMark, Globe, ImageIcon } from "./icons";
import { MathDisplay, MathInline } from "./Math";
import { normalizeMath } from "./mathDelimiters";
import { IncrementalMarkdown, type KeyedBlock } from "./incrementalMarkdown";
import { linkedText, PathChip, UrlChip } from "../chips/LinkChips";
import { BareReferenceChip } from "../chips/BareReferenceChip";
import { codePath, linkPath, pathName, textLinks } from "../chips/paths";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import "../../../markdown-task-checkbox.css";
import { TaskCheckbox } from "../../../ui/TaskCheckbox";
import {
  commitReferences,
  githubReferences,
  type CommitReference,
  type GithubReference,
} from "../../../githubReferences";
import { imageOnlyItems, proseImages, type ThumbItem } from "./inlineMedia";
import { acpmuxPerf } from "../perf";
import { StartedSessionChip, useStartedMentions, type StartedMentions } from "../started/StartedSessionCard";
import { splitMentions } from "../started/startedSessions";
import { entranceAllowed } from "../../shared/pageReveal";
import { isAgentMotionOff } from "../../shared/motion";
import { decorateTimes, splitTimeTokens, TimeHover } from "./timeHover";

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
/// The deepest nesting of quotes and lists the parser builds. A reply is untrusted, and each level
/// costs stack while it draws (800 list levels overflowed it), so content below this depth draws
/// as the plain text of one paragraph.
export const MAX_NESTING = 32;
const FOOTNOTE_DEF = /^\[\^([\w-]+)\]:\s*(.*)$/;

/** Parse the supported Markdown subset into blocks. */
export function parseMarkdown(src: string, options: { messageAt?: number } = {}): MdBlock[] {
  const lines = normalizeMath(src.replace(/\r\n?/g, "\n").split("\n"));
  const blocks = parseLines(lines);
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
function parseLines(lines: string[], depth = 0): MdBlock[] {
  const out: MdBlock[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i++;
      continue;
    }
    const fence = line.match(/^\s*```([^\s`]*)[^`]*$/);
    if (fence) {
      const body: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) body.push(lines[i++]);
      const open = i >= lines.length;
      i++;
      out.push({
        type: "code",
        lang: fence[1] || "text",
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
      out.push({ type: "blockquote", children: nested(body, depth + 1) });
      continue;
    }
    if (
      line.includes("|") &&
      i + 1 < lines.length &&
      /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])
    ) {
      const cells = (l: string) =>
        l
          .trim()
          .replace(/^\|/, "")
          .replace(/\|$/, "")
          .split("|")
          .map((c) => c.trim());
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
      const [block, next] = parseList(lines, i, depth);
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
      !/^\s*```/.test(lines[i]) &&
      !/^\s*\$\$/.test(lines[i]) &&
      !/^\s*>/.test(lines[i]) &&
      !LIST_RE.test(lines[i])
    )
      para.push(lines[i++].trim());
    out.push({ type: "paragraph", text: para.join("\n") });
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
function nested(lines: string[], depth: number): MdBlock[] {
  if (depth < MAX_NESTING) return parseLines(lines, depth);
  const text = lines
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n");
  return text ? [{ type: "paragraph", text }] : [];
}

function parseList(lines: string[], start: number, depth: number): [MdBlock, number] {
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

/* ---------------- Inline ---------------- */

export type InlineOptions = {
  /** Icon drawn before a link's text; default `linkIcon` below. */
  linkIcon?: (href: string) => ReactNode | null;
  /** The reply's footnotes: each id's number and the element id of its note. */
  notes?: FootnoteNumbers;
  /** Long data URLs of this text, by the index their short stand-in names (`capDataUrls`). */
  dataRefs?: string[];
  /** Data URLs past the reply's total budget (MAX_REPLY_DATA_URLS): drawn as their name. */
  overBudget?: Set<string>;
  /** The workspace's GitHub `owner/repo`, used for bare issue references. */
  githubRepository?: string;
  /** Link GitHub references in prose; labels of an outer link disable this. */
  linkGithubReferences?: boolean;
  /** The chats the open chat started, whose names draw as chips (started/startedSessions.ts). */
  started?: StartedMentions;
  /** How a commit SHA draws: a GitHub chip (replies), or quiet monospace text that links to its
   *  commit when its repository is known (another agent's message, IncomingMessageCard.tsx). */
  commits?: "chip" | "quiet";
  /** An image path draws as a thumbnail too (default): under its sentence, or in its place in a
   *  paragraph of images. Off, only its chip: another machine's files in another agent's message
   *  (IncomingMessageCard.tsx). Markdown image syntax (`![shot](/a.png)`) still draws in place. */
  thumbnails?: boolean;
};

export type FootnoteNumbers = { numbers: Map<string, number>; anchor: (id: string) => string };

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
const INLINE_IMAGE = /^data:image\/(?:png|jpe?g|gif|webp|svg\+xml);/i;
/// The longest data URL an image draws from (2 MB of text); a longer one draws as its name only,
/// so a reply cannot make the pane decode and hold an arbitrarily large image.
export const MAX_DATA_URL_LENGTH = 2_000_000;
/// What an over-long data URL is replaced with before the inline parser sees it (`capDataUrls`).
const OVERSIZED_DATA_URL = "data:image/x-cmux-oversized;";
/// A long data URL's short stand-in for the inline parser, `<prefix><index in dataRefs>`: the
/// inline pattern does not match a target of megabytes, so such an image drew as its source.
const DATA_REF = "data:image/x-cmux-ref;";
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
function capDataUrls(text: string, refs: string[]): string {
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
  if (kind === "github") return <GitHubMark size={13} className="cv-link__icon cv-link__icon--gh" />;
  if (kind === "citation") return <ArxivMark size={16} className="cv-link__icon" />;
  if (kind === "file") return <FileDoc size={16} className="cv-link__icon" />;
  return <Globe size={16} strokeWidth={1.1} className="cv-link__icon" />;
};

/// `src/app.ts:12` keeps its line in the chip's label (the chip opens the file).
function lineLabel(path: string, written: string): string | undefined {
  const line = /:(\d+)(?::\d+)?$/.exec(written)?.[1];
  return line ? `${pathName(path)}:${line}` : undefined;
}

const NO_REPOSITORY = "-/-";

function linkedGithubText(
  text: string,
  key: string,
  repository?: string,
  enabled = true,
  quietCommits = false,
): ReactNode[] {
  if (!enabled) return linkedText(text, key);
  // A pull request address, so the chip opens the pull request card (an issue redirects there);
  // a commit (`abc1234`, `owner/repo@abc1234`) opens its GitHub page. In reading order; a commit
  // inside a reference, a URL or a path (`https://x.test/app.js?v=3a7bd3e2`) is part of it.
  // With no repository, a bare `#N` still goes to BareReferenceChip, which links it only when the
  // transcript names its repository.
  const issues = githubReferences(text, repository ?? NO_REPOSITORY, "pull", true);
  const commits = quietCommits ? quietCommitReferences(text, issues, repository) : commitReferences(text, repository);
  // A commit or a bare `#N` inside a URL or a path (`https://x.test/?q=#12`) is part of it.
  const spans = commits.length || issues.some((issue) => issue.bare) ? textLinks(text) : [];
  const outside = (ref: { start: number; end: number }) =>
    !spans.some((span) => ref.start < span.end && span.start < ref.end);
  const refs = [...issues.filter((issue) => !issue.bare || outside(issue)), ...commits.filter(outside)]
    .sort((a, b) => a.start - b.start)
    .filter((ref, index, all) => index === 0 || ref.start >= all[index - 1]!.end);
  if (!refs.length) return linkedText(text, key);
  const out: ReactNode[] = [];
  let at = 0;
  refs.forEach((reference, index) => {
    if (reference.start > at) out.push(...linkedText(text.slice(at, reference.start), `${key}-${index}-before`));
    const sha = quietCommits && "sha" in reference;
    out.push(
      sha ? (
        reference.href ? (
          <a key={`${key}-${index}`} className="cv-sha" href={reference.href} rel="noreferrer">
            {reference.text}
          </a>
        ) : (
          <span key={`${key}-${index}`} className="cv-sha">
            {reference.text}
          </span>
        )
      ) : (
        <UrlChip
          key={`${key}-${index}`}
          href={reference.href}
          icon={<GitHubMark size={13} className="cv-link__icon cv-link__icon--gh" />}
        >
          {reference.text}
        </UrlChip>
      ),
    );
    // A bare `#N` names the repository the transcript's evidence says, not only `repository`.
    if ("bare" in reference && reference.bare)
      out[out.length - 1] = (
        <BareReferenceChip
          key={`${key}-${index}`}
          number={reference.bare}
          href={repository ? reference.href : undefined}
          text={reference.text}
        />
      );
    at = reference.end;
  });
  if (at < text.length) out.push(...linkedText(text.slice(at), `${key}-after`));
  return out;
}

/// Every commit SHA in `text` (an agent's message): each links to its commit in the repository it
/// names (`owner/repo@sha`), else that of the nearest reference before it in the same text
/// (`hq#2563 (db0677c6)` is a cmuxterm-hq commit), else `repository`; with none it is text.
function quietCommitReferences(text: string, issues: GithubReference[], repository?: string): CommitReference[] {
  return commitReferences(text, undefined, true).map((commit) => {
    if (commit.href) return commit;
    const before = issues.filter((issue) => issue.end <= commit.start).at(-1);
    const repo = before ? /^https:\/\/github\.com\/([^/]+\/[^/]+)\//.exec(before.href)?.[1] : repository;
    const text = commit.sha.length > 10 ? commit.sha.slice(0, 8) : commit.text;
    return repo ? { ...commit, text, href: `https://github.com/${repo}/commit/${commit.sha}` } : { ...commit, text };
  });
}

/// Plain prose: a started chat's name is its chip; the rest links GitHub references and URLs.
function proseText(text: string, key: string, opts: InlineOptions): ReactNode[] {
  const out: ReactNode[] = [];
  let index = 0;
  for (const part of splitTimeTokens(text)) {
    if (typeof part !== "string") {
      out.push(<TimeHover key={`${key}-${index++}`} token={part} />);
      continue;
    }
    const pieces = opts.started?.mentions.length ? splitMentions(part, opts.started.mentions) : [part];
    out.push(
      ...pieces.flatMap((piece): ReactNode[] => {
        const current = `${key}-${index++}`;
        return typeof piece === "string"
          ? linkedGithubText(
              piece,
              current,
              opts.githubRepository,
              opts.linkGithubReferences !== false,
              opts.commits === "quiet",
            )
          : [
              <StartedSessionChip
                key={current}
                mention={piece.mention}
                text={piece.text}
                onOpen={opts.started!.open}
              />,
            ];
      }),
    );
  }
  return out;
}

// Groups: code, bold, strikethrough, italic, image or link, line break, `$$…$$` inside a
// paragraph (not prose, words and punctuation, beside a space, so the shell's "echo $$ and $$"
// and "echo $$ prints the shell's PID, and echo $$" stay text while
// "$$ E = mc^2 $$" typesets), `$…$` (Pandoc's rule: no space, `(` or `{` after the opener, no
// space before or letter/digit after the closer, so "$PATH and $HOME" and
// `$(cmd)` stay text; no backtick inside, so "$5 or `$PATH`" does too), explicit `\(…\)`, a backslash escape (`\$`, `\*`) that
// draws its character, and a footnote reference (`[^id]`).
const INLINE_RE =
  /(`[^`]+`)|(\*\*[^*]+\*\*)|(~~[^~]+~~)|((?<![\w*])\*[^*\s][^*]*\*(?![\w*])|(?<![\w_])_[^_\s][^_]*_(?![\w_]))|(!\[[^\]]*\]\((?:[^()\s]|\([^()\s]*\))+\)|\[[^\]]+\]\((?:[^()\s]|\([^()\s]*\))+\))|(\n)|(\$\$(?!\s[A-Za-z\s'’,.;:!?"()-]*\$\$|[A-Za-z\s'’,.;:!?"()-]*\s\$\$)[^$\n]+?\$\$)|(?<![\\$])(\$(?![({])(?=[^\s$])(?:\\.|[^$\\\n`])*?[^\s\\`$]\$(?![A-Za-z0-9])|\\\(.+?\\\))|(\\[\\`*_{}[\]()#+\-.!$|~<>])|(\[\^[\w-]+\](?!:))/g;

/** Render inline Markdown (code, bold, italic, strikethrough, links, line breaks). */
export function renderInline(source: string, outer: InlineOptions = {}): ReactNode[] {
  const refs: string[] = [];
  const text = capDataUrls(source, refs);
  const opts = refs.length ? { ...outer, dataRefs: refs } : outer;
  const out: ReactNode[] = [];
  let last = 0;
  let k = 0;
  for (const m of text.matchAll(INLINE_RE)) {
    if (m.index! > last) out.push(...proseText(text.slice(last, m.index), `t${k++}`, opts));
    const t = m[0];
    const named = m[1] ? opts.started?.mentions.find((mention) => mention.text === t.slice(1, -1)) : undefined;
    if (named) out.push(<StartedSessionChip key={k++} mention={named} text={named.text} onOpen={opts.started!.open} />);
    else if (m[1]) {
      const path = codePath(t.slice(1, -1));
      out.push(
        path ? (
          <PathChip key={k++} path={path} written={t.slice(1, -1)} label={lineLabel(path, t.slice(1, -1))} />
        ) : (
          <code key={k++} className="cv-code">
            {t.slice(1, -1)}
          </code>
        ),
      );
    } else if (m[2]) out.push(<strong key={k++}>{renderInline(t.slice(2, -2), opts)}</strong>);
    else if (m[3]) out.push(<del key={k++}>{renderInline(t.slice(2, -2), opts)}</del>);
    else if (m[4]) out.push(<em key={k++}>{renderInline(t.slice(1, -1), opts)}</em>);
    else if (m[5]?.startsWith("!")) out.push(<InlineImage key={k++} source={t} opts={opts} />);
    else if (m[5]) {
      const lm = t.match(/^\[([^\]]+)\]\((.+)\)$/)!;
      const href = safeHref(lm[2]);
      // A local path is a path chip; a link the pane will not open draws as its text; a web
      // link is a chip with its site's mark (chips/LinkChips.tsx).
      const path = linkPath(lm[2]);
      const labelOpts = { ...opts, githubRepository: undefined, linkGithubReferences: false, started: undefined };
      // A link to a session (`cmux://session/<id>`) the open chat started opens that chat.
      const linked = /^[a-z][\w+.-]*:\/\/session\/([\w-]+)$/i.exec(lm[2])?.[1];
      const named = linked ? opts.started?.mentions.find((mention) => mention.sessionId === linked) : undefined;
      const app = href ? undefined : appHref(lm[2]);
      // An agent pointing at an open ask (`cmux://needs-you/<permissionId>`, needsYou/links.ts):
      // a chip that opens the header's Needs you list on it, so the ask is never restated. With the
      // list off (not installed from the App Store) it draws as its text, like a link the pane will not open.
      const ask = href ? undefined : needsYouTarget(lm[2]);
      if (ask && needsYouListOff()) out.push(<Fragment key={k++}>{renderInline(lm[1], labelOpts)}</Fragment>);
      else if (ask)
        out.push(
          <button key={k++} type="button" className="cv-link is-needs-you" onClick={() => openNeedsYou(ask)}>
            <span className="acpmux-needs-you-dot" aria-hidden="true" />
            {renderInline(lm[1], labelOpts)}
          </button>,
        );
      else if (named)
        out.push(<StartedSessionChip key={k++} mention={named} text={lm[1]} onOpen={opts.started!.open} />);
      else if (path) out.push(<PathChip key={k++} path={path} label={renderInline(lm[1], labelOpts)} />);
      else if (app)
        // A cmux app link: a plain anchor, so the click takes the host's link path (opened in the app).
        out.push(
          <a key={k++} className="cv-link is-app" href={app}>
            {renderInline(lm[1], labelOpts)}
          </a>,
        );
      else if (linkKind(lm[2]) === "file")
        out.push(
          <span key={k++} className="cv-link is-file">
            {(opts.linkIcon ?? linkIcon)(lm[2])}
            {renderInline(lm[1], labelOpts)}
          </span>,
        );
      else if (!href) out.push(<Fragment key={k++}>{renderInline(lm[1], labelOpts)}</Fragment>);
      else
        out.push(
          <UrlChip
            key={k++}
            href={href}
            icon={linkKind(href) === "web" ? undefined : (opts.linkIcon ?? linkIcon)(href)}
          >
            {renderInline(lm[1], labelOpts)}
          </UrlChip>,
        );
    } else if (m[6]) out.push(<br key={k++} />);
    else if (m[7]) out.push(<MathInline key={k++} tex={t.slice(2, -2).trim()} display />);
    else if (m[8])
      out.push(<MathInline key={k++} tex={t.startsWith("\\(") ? t.slice(2, -2).trim() : t.slice(1, -1)} />);
    else if (m[9]) out.push(t.slice(1));
    else if (m[10]) {
      const id = t.slice(2, -1);
      const number = opts.notes?.numbers.get(id);
      if (!number || !opts.notes) out.push(t);
      else {
        const anchor = opts.notes.anchor(id);
        out.push(
          <sup key={k++} className="cv-fnref">
            <button
              type="button"
              aria-describedby={anchor}
              onClick={() =>
                document.getElementById(anchor)?.scrollIntoView({ block: "nearest", behavior: noteScroll() })
              }
            >
              {number}
            </button>
          </sup>,
        );
      }
    }
    last = m.index! + t.length;
  }
  if (last < text.length) out.push(...proseText(text.slice(last), `t${k++}`, opts));
  return out;
}

/// How a footnote reference scrolls to its note: a glide, or with cmux's animations off
/// (ui.animations) or the system's Reduce Motion, in one frame, as Jump to latest does (hq#3581).
function noteScroll(): ScrollBehavior {
  const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  return reduce ? "auto" : "smooth";
}

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

/// `![alt](src)`: a data URL image draws inline, and a click opens it in the image viewer; a web
/// image the pane cannot load draws as a link to it, named by its alt text or file name.
function InlineImage({ source, opts }: { source: string; opts: InlineOptions }) {
  const [, alt = "", written = ""] = source.match(/^!\[([^\]]*)\]\((.+)\)$/) ?? [];
  const src = written.startsWith(DATA_REF) ? (opts.dataRefs?.[Number(written.slice(DATA_REF.length))] ?? "") : written;
  if (opts.overBudget?.has(src)) return <OversizedImage alt={alt} opts={opts} />;
  if (src === OVERSIZED_DATA_URL || (INLINE_IMAGE.test(src) && src.length > MAX_DATA_URL_LENGTH))
    return <OversizedImage alt={alt} opts={opts} />;
  if (INLINE_IMAGE.test(src)) return <OpenableImage src={src} alt={alt} thumb />;
  const name = alt || src.split(/[?#]/)[0]!.split("/").filter(Boolean).at(-1) || src;
  const labelOpts = { ...opts, githubRepository: undefined, linkGithubReferences: false, started: undefined };
  const href = safeHref(src);
  const fallback = !href ? (
    <span className="cv-link is-image">
      <ImageIcon size={16} className="cv-link__icon" />
      {renderInline(name, labelOpts)}
    </span>
  ) : (
    <a className="cv-link is-image" href={href} rel="noreferrer">
      <ImageIcon size={16} className="cv-link__icon" />
      {renderInline(name, labelOpts)}
    </a>
  );
  // A file inside the session's folders, or a web image, loads through the host (D5).
  return <ReplyImage src={src} alt={alt} fallback={fallback} thumb />;
}

/// Thumbnails of `items` (inlineMedia.ts): one alone, or a row where each has the same share of
/// the width, so a before/after pair sits side by side, captioned by its label or alt text.
/// A written label (`Before:`) is always its caption; an alt text is one only in a row.
function Thumbs({ items, opts }: { items: ThumbItem[]; opts: InlineOptions }) {
  const row = items.length > 1;
  return (
    <span className={`cv-thumbs${row ? " is-row" : ""}`} data-count={items.length}>
      {items.map((item, index) => {
        const caption = item.label ?? (row ? item.alt : "");
        return (
          <span key={index} className="cv-thumbs__item">
            <InlineImage source={`![${item.alt}](${item.src})`} opts={opts} />
            {caption && <span className="cv-thumbs__caption">{caption}</span>}
          </span>
        );
      })}
    </span>
  );
}

/// A data URL image over MAX_DATA_URL_LENGTH: its alt text (or "Image too large to show") with the
/// image mark, never the URL itself.
function OversizedImage({ alt, opts }: { alt: string; opts: InlineOptions }) {
  const t = useT();
  return (
    <span
      className="cv-link is-image"
      /* tooltip-allow: why the image does not show */ title={t("markdown.imageTooLarge")}
    >
      <ImageIcon size={16} className="cv-link__icon" />
      {alt
        ? renderInline(alt, { ...opts, githubRepository: undefined, linkGithubReferences: false })
        : t("markdown.imageTooLarge")}
    </span>
  );
}

/* ---------------- Blocks ---------------- */

function Block({
  block,
  opts,
  depth,
  enter = false,
  code = "final",
  tail,
  artifactIdentity,
  artifactRevision,
}: {
  block: MdBlock;
  opts: InlineOptions;
  depth: number;
  /** The block appeared while the reply streams: it enters with the shared motion (`.cv-enter`). */
  enter?: boolean;
  /** A code block's stage: still open (plain lines), closed while streaming (highlighted once,
   * faded in), or drawn finished (highlighted). */
  code?: "open" | "handoff" | "final" | "plain";
  /** The reply's newest characters, which fade in at the end of this, its last block. */
  tail?: FreshTail;
  artifactIdentity?: string;
  artifactRevision?: number;
}): ReactNode {
  const motion = enter ? " cv-enter" : "";
  const inline = (text: string) => (tail ? renderFresh(text, tail, opts) : renderInline(text, opts));
  switch (block.type) {
    case "heading": {
      // h5 and h6 draw as h4, the smallest heading the column has.
      const H = `h${block.level}` as "h1";
      return <H className={`cv-h cv-h${Math.min(block.level, 4)}${motion}`}>{inline(block.text)}</H>;
    }
    case "paragraph": {
      // A web video link alone on its line plays in place (ReplyMedia); in a sentence it stays a link.
      const link = block.text.trim();
      if (!tail && !/\s/.test(link) && isRemoteMedia(link))
        return (
          <p className={`cv-p${motion}`}>
            <RemoteMedia url={link} alt="" fallback={inline(block.text)} />
          </p>
        );
      // Only images (a before/after pair, a screenshot alone on its line): a row of thumbnails, once
      // the paragraph has finished arriving (a half-written line may still turn into prose).
      const images = tail || opts.thumbnails === false ? undefined : imageOnlyItems(block.text);
      if (images)
        return (
          <p className={`cv-p cv-p--images${motion}`}>
            <Thumbs items={images} opts={opts} />
          </p>
        );
      // An image path in a sentence stays its chip there; its thumbnail draws under the paragraph,
      // once the paragraph has finished arriving.
      const named = tail || opts.thumbnails === false ? [] : proseImages(block.text);
      return (
        <>
          <p className={`cv-p${motion}`}>{inline(block.text)}</p>
          {named.length > 0 && (
            <p className={`cv-p cv-p--images${motion}`}>
              <Thumbs items={named} opts={opts} />
            </p>
          )}
        </>
      );
    }
    case "hr":
      return <hr className={`cv-hr${motion}`} />;
    case "blockquote":
      return (
        <blockquote className={`cv-quote${motion}`}>
          <Blocks
            blocks={block.children}
            opts={opts}
            depth={depth}
            plain={code === "plain"}
            artifactIdentity={artifactIdentity ? `${artifactIdentity}.q` : undefined}
            artifactRevision={artifactRevision}
          />
        </blockquote>
      );
    case "list": {
      const L = block.ordered ? "ol" : "ul";
      const tasks = block.items.every((it) => it.task);
      return (
        <L
          className={`cv-list ${block.ordered ? "cv-ol" : "cv-ul"}${tasks ? " cv-tasks" : ""}${motion}`}
          data-depth={depth}
          start={block.ordered && block.start !== 1 ? block.start : undefined}
        >
          {block.items.map((it, i) => (
            <li key={i} className={it.task ? "cv-task" : undefined}>
              {block.ordered && <span className="cv-li__num">{block.start + i}.</span>}
              {!block.ordered && !it.task && <span className={`cv-li__bullet cv-li__bullet--${depth % 3}`} />}
              {it.task && <TaskCheckbox checked={Boolean(it.checked)} className="cv-checkbox" />}
              <span className="cv-li__text">
                {i === block.items.length - 1 && !it.children.length ? inline(it.text) : renderInline(it.text, opts)}
              </span>
              <ItemThumbs text={it.text} opts={opts} streaming={Boolean(tail) && i === block.items.length - 1} />
              {it.children.length > 0 && (
                <Blocks
                  blocks={it.children}
                  opts={opts}
                  depth={depth + 1}
                  plain={code === "plain"}
                  artifactIdentity={artifactIdentity ? `${artifactIdentity}.i${i}` : undefined}
                  artifactRevision={artifactRevision}
                />
              )}
            </li>
          ))}
        </L>
      );
    }
    case "table":
      return <TableBlock table={block} cell={(text) => renderInline(text, opts)} className={motion} />;
    case "code": {
      if (code === "open")
        return (
          <PlainCode
            code={block.code}
            lang={block.lang}
            artifactIdentity={artifactIdentity}
            artifactRevision={artifactRevision}
            open
          />
        );
      if (code === "plain")
        return (
          <PlainCode
            code={block.code}
            lang={block.lang}
            artifactIdentity={artifactIdentity}
            artifactRevision={artifactRevision}
          />
        );
      // A diagram draws once its fence closes; a Mermaid source still streaming stays code.
      if (isChart(block.lang, block.code) && !(block.open && block.lang.toLowerCase() === "mermaid"))
        return <DiagramBlock lang={block.lang} code={block.code} />;
      // A page in a closed ```cmux-render fence runs in the render frame; the dev server has none.
      const render = canRender() && !block.open ? renderFence(block.lang, block.code) : undefined;
      if (render) return <RenderCard call={render} />;
      if (code === "handoff")
        return (
          <CodeHandoff
            code={block.code}
            lang={block.lang}
            artifactIdentity={artifactIdentity}
            artifactRevision={artifactRevision}
          />
        );
      return (
        <CodeBlock
          code={block.code}
          lang={block.lang}
          artifactIdentity={artifactIdentity}
          artifactRevision={artifactRevision}
        />
      );
    }
    case "math":
      return <MathDisplay tex={block.tex} />;
    case "footnote": {
      const number = opts.notes?.numbers.get(block.id);
      return (
        <li id={opts.notes?.anchor(block.id)} className="cv-footnote" value={number}>
          {inline(block.text)}
        </li>
      );
    }
  }
}

/// A list item's image paths, as thumbnails under its text (a last item still arriving has none yet).
function ItemThumbs({ text, opts, streaming }: { text: string; opts: InlineOptions; streaming: boolean }) {
  const named = streaming || opts.thumbnails === false ? [] : proseImages(text);
  return named.length ? (
    <span className="cv-li__images">
      <Thumbs items={named} opts={opts} />
    </span>
  ) : null;
}

/// Nested blocks (a quote's, a list item's). `plain` keeps the outer Markdown's plain fences
/// (`plainCode`) inside them too: no diagram or render card at any depth.
function Blocks({
  blocks,
  opts,
  depth,
  plain = false,
  artifactIdentity,
  artifactRevision,
}: {
  blocks: MdBlock[];
  opts: InlineOptions;
  depth: number;
  plain?: boolean;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  return (
    <>
      {blocks.map((b, i) => (
        <Fragment key={i}>
          <Block
            block={b}
            opts={opts}
            depth={depth}
            code={plain ? "plain" : undefined}
            artifactIdentity={artifactIdentity ? `${artifactIdentity}.${i}` : undefined}
            artifactRevision={artifactRevision}
          />
        </Fragment>
      ))}
    </>
  );
}

/// The newest revealed text of a streaming reply: its steps and the source suffix they cover.
export type FreshTail = { steps: Reveal[]; text: string; now: number };

/// `text` with its newest characters in spans that fade in (`.cv-fresh`). Each span keeps its key
/// and a negative animation delay, so a re-render never restarts its fade. Only plain trailing
/// text fades by step; a suffix with Markdown syntax or a line break draws as usual.
function renderFresh(text: string, tail: FreshTail, opts: InlineOptions): ReactNode[] {
  const fresh = tail.text.trimEnd();
  if (!fresh || !text.endsWith(fresh) || /[*`_~[\]()$\\\n]/.test(fresh)) return renderInline(text, opts);
  const out = renderInline(text.slice(0, text.length - fresh.length), opts);
  let end = fresh.length;
  const spans: ReactNode[] = [];
  for (let index = tail.steps.length - 1; index >= 0 && end > 0; index -= 1) {
    const step = tail.steps[index]!;
    const start = Math.max(0, end - step.count);
    spans.unshift(
      <span key={`f${step.id}`} className="cv-fresh" style={{ animationDelay: `${-(tail.now - step.born)}ms` }}>
        {fresh.slice(start, end)}
      </span>,
    );
    end = start;
  }
  if (end > 0) out.push(fresh.slice(0, end));
  return [...out, ...spans];
}

/// A top-level block that renders again only when its parsed block changes: a streaming reply's
/// finished blocks keep their objects (IncrementalMarkdown), so each delta renders only the tail.
const BlockView = memo(Block);

export type MarkdownProps = InlineOptions & {
  /** Markdown source. */
  children: string;
  className?: string;
  /** The reply is streaming: blocks that appear from now on enter with the shared motion. */
  streaming?: boolean;
  /** The newest revealed steps (RevealedMarkdown), which fade in at the end of the last block. */
  fresh?: Reveal[];
  now?: number;
  /** Fences draw as plain lines, never a highlighted diff card (review comments inside a diff). */
  plainCode?: boolean;
  artifactIdentity?: string;
  artifactRevision?: number;
  /** Epoch timestamp of the message, used to date bare UTC clock times. */
  messageAt?: number;
};

function noteRank(block: MdBlock, opts: InlineOptions): number {
  return block.type === "footnote" ? (opts.notes?.numbers.get(block.id) ?? Number.MAX_SAFE_INTEGER) : 0;
}

/** Assistant-message Markdown. A growing source (a streaming reply) is parsed incrementally. */
export function Markdown({
  children,
  className = "",
  linkIcon,
  streaming = false,
  fresh,
  now = 0,
  githubRepository,
  plainCode = false,
  artifactIdentity,
  artifactRevision,
  commits,
  thumbnails,
  messageAt,
}: MarkdownProps) {
  const parser = useRef<IncrementalMarkdown | null>(null);
  parser.current ??= new IncrementalMarkdown();
  const blocks = acpmuxPerf.timed("markdown.parse", () => parser.current!.update(children, { streaming, messageAt }));
  // Blocks there at the first render (history, a row scrolled into view) never animate.
  const atMount = useRef<Set<string> | null>(null);
  atMount.current ??= new Set(blocks.map((entry) => entry.key));
  // Blocks first drawn while entrances wait (the page hidden or just shown again).
  const awayBlocks = useRef(new Set<string>());
  // Notes are numbered by first reference; the key keeps `opts` (and every memoized block) the
  // same object until a new reference arrives.
  // The reveal clock can re-render a streaming reply while its source is unchanged. Keep the
  // full footnote scan on source changes instead of repeating it for each animation frame.
  const noteIds = useMemo(() => footnoteOrder(children).join(" "), [children]);
  // The reply's data URL budget; only a reply longer than the budget can pass it.
  const budgetSource = children.length > MAX_REPLY_DATA_URLS ? children : "";
  const overBudget = useMemo(() => dataUrlsOverBudget(budgetSource), [budgetSource]);
  const notePrefix = useId();
  const startedContext = useStartedMentions();
  const started = startedContext.mentions.length ? startedContext : undefined;
  const opts = useMemo<InlineOptions>(() => {
    const ids = noteIds ? noteIds.split(" ") : [];
    const numbers = new Map(ids.map((id, index) => [id, index + 1]));
    return {
      linkIcon,
      githubRepository,
      notes: { numbers, anchor: (id) => `${notePrefix}fn-${id}` },
      overBudget,
      ...(started ? { started } : {}),
      ...(commits ? { commits } : {}),
      ...(thumbnails === false ? { thumbnails } : {}),
    };
  }, [commits, githubRepository, linkIcon, noteIds, notePrefix, overBudget, started, thumbnails]);
  // Fences this reply drew open: they hand over to the highlighted card once, when they close.
  const streamedFences = useRef(new Set<string>());
  // A later token must not invalidate every completed code block's memoized props.
  const artifactRevisions = useRef(new WeakMap<MdBlock, number | undefined>());
  const freshChars = fresh?.reduce((sum, step) => sum + step.count, 0) ?? 0;
  // Only a revealed reply (RevealedMarkdown passes `fresh`) fades its newest text in.
  const freshTail: FreshTail | undefined =
    streaming && fresh
      ? { steps: fresh, text: freshChars ? children.slice(children.length - freshChars) : "", now }
      : undefined;
  // A block that streamed in while the chat was hidden, or that lands before its first frame back,
  // came while the user was away: it never enters (WebKit would play its suspended entrance on
  // return, shared/pageReveal.ts). It still hands its code over like any live block.
  const away = streaming && !entranceAllowed();
  const draw = (entry: KeyedBlock, index: number) => {
    if (!artifactRevisions.current.has(entry.block)) artifactRevisions.current.set(entry.block, artifactRevision);
    const live = !atMount.current!.has(entry.key);
    if (live && away) awayBlocks.current.add(entry.key);
    // The last block is a fence still arriving. Read from the parsed (safe) tail, not the raw
    // fence count: a closer still being typed is held back (safeTail.ts), so the card stays open
    // until the closed one draws the same lines, and an opener held back after a closed fence does
    // not turn that fence back into an open one.
    const open = streaming && index === blocks.length - 1 && entry.block.type === "code" && entry.block.open === true;
    if (open) streamedFences.current.add(entry.key);
    return (
      <BlockView
        key={entry.key}
        block={entry.block}
        opts={opts}
        depth={0}
        enter={streaming && live && !awayBlocks.current.has(entry.key)}
        code={open ? "open" : plainCode ? "plain" : live || streamedFences.current.has(entry.key) ? "handoff" : "final"}
        tail={index === blocks.length - 1 ? freshTail : undefined}
        artifactIdentity={artifactIdentity ? `${artifactIdentity}\u0000${entry.key}` : undefined}
        artifactRevision={artifactRevisions.current.get(entry.block)}
      />
    );
  };
  // Footnote definitions draw as the reply's notes, under a rule, in reference order (an
  // unreferenced note last).
  const notes = blocks
    .map((entry, index) => ({ entry, index }))
    .filter(({ entry }) => entry.block.type === "footnote")
    .sort((a, b) => noteRank(a.entry.block, opts) - noteRank(b.entry.block, opts));
  return (
    <div className={`cv-md selectable ${className}`}>
      {blocks.map((entry, index) => (entry.block.type === "footnote" ? null : draw(entry, index)))}
      {notes.length > 0 && (
        <section className="cv-footnotes" role="doc-endnotes">
          <ol>{notes.map(({ entry, index }) => draw(entry, index))}</ol>
        </section>
      )}
    </div>
  );
}
