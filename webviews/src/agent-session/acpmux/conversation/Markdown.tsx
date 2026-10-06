// Ported from the agent-pane reference prototype (src/conversation/Markdown.tsx).
// A small GFM-subset Markdown renderer for assistant messages. It produces the same
// DOM shape for every transcript: headings, paragraphs (single newlines are line
// breaks), nested ordered/bullet/task lists, blockquotes, rules, aligned tables, fenced
// code blocks rendered by @pierre/diffs (see CodeBlock.tsx), and `$…$`, `$$…$$`, `\(…\)`
// and `\[…\]` math typeset by KaTeX (see Math.tsx).
import { Fragment, memo, useMemo, useRef, type ReactNode } from "react";
import { safeHref } from "../model";
import { CodeBlock } from "./CodeBlock";
import { CodeHandoff, PlainCode } from "./StreamingCode";
import type { Reveal } from "./RevealedMarkdown";
import { ArxivMark, Check, FileDoc, GitHubMark, Globe } from "./icons";
import { MathDisplay, MathInline } from "./Math";
import { normalizeMath } from "./mathDelimiters";
import { IncrementalMarkdown } from "./incrementalMarkdown";

export type Align = "left" | "center" | "right" | null;

export type MdBlock =
  | { type: "heading"; level: 1 | 2 | 3 | 4; text: string }
  | { type: "paragraph"; text: string }
  | { type: "hr" }
  | { type: "blockquote"; children: MdBlock[] }
  | { type: "list"; ordered: boolean; start: number; items: MdListItem[] }
  | { type: "table"; align: Align[]; header: string[]; rows: string[][] }
  | { type: "code"; lang: string; code: string }
  | { type: "math"; tex: string };

export type MdListItem = { text: string; task?: boolean; checked?: boolean; children: MdBlock[] };

const LIST_RE = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;

/** Parse the supported Markdown subset into blocks. */
export function parseMarkdown(src: string): MdBlock[] {
  const lines = normalizeMath(src.replace(/\r\n?/g, "\n").split("\n"));
  return parseLines(lines);
}

function parseLines(lines: string[]): MdBlock[] {
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
      i++;
      out.push({ type: "code", lang: fence[1] || "text", code: body.join("\n") });
      continue;
    }
    const display = displayMath(lines, i);
    if (display) {
      out.push({ type: "math", tex: display.tex });
      i = display.next;
      continue;
    }
    const h = line.match(/^(#{1,4})\s+(.*)$/);
    if (h) {
      out.push({ type: "heading", level: h[1].length as 1 | 2 | 3 | 4, text: h[2] });
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
      out.push({ type: "blockquote", children: parseLines(body) });
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
      const [block, next] = parseList(lines, i);
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
      !/^(#{1,4})\s/.test(lines[i]) &&
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

function parseList(lines: string[], start: number): [MdBlock, number] {
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
      const nested: string[] = [];
      while (i < lines.length && lines[i].trim() && indentOf(lines[i]) > base) nested.push(lines[i++]);
      if (nested.length) {
        const strip = Math.min(...nested.map(indentOf));
        item.children = parseLines(nested.map((n) => n.slice(strip)));
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
};

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

// Groups: code, bold, strikethrough, italic, link, line break, `$$…$$` inside a paragraph,
// `$…$` (Pandoc's rule: no space inside either dollar and no digit after the closer, so
// "$5 and $10" stays text; no backtick inside, so "$5 or `$PATH`" does too), and a backslash
// escape (`\$`, `\*`) that draws its character.
const INLINE_RE =
  /(`[^`]+`)|(\*\*[^*]+\*\*)|(~~[^~]+~~)|((?<![\w*])\*[^*\s][^*]*\*(?![\w*])|(?<![\w_])_[^_\s][^_]*_(?![\w_]))|(\[[^\]]+\]\((?:[^()\s]|\([^()\s]*\))+\))|(\n)|(\$\$[^$\n]+?\$\$)|(?<![\\$])(\$(?=[^\s$])(?:\\.|[^$\\\n`])*?[^\s\\`]\$(?!\d))|(\\[\\`*_{}[\]()#+\-.!$|~<>])/g;

/** Render inline Markdown (code, bold, italic, strikethrough, links, line breaks). */
export function renderInline(text: string, opts: InlineOptions = {}): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let k = 0;
  for (const m of text.matchAll(INLINE_RE)) {
    if (m.index! > last) out.push(text.slice(last, m.index));
    const t = m[0];
    if (m[1])
      out.push(
        <code key={k++} className="cv-code">
          {t.slice(1, -1)}
        </code>,
      );
    else if (m[2]) out.push(<strong key={k++}>{renderInline(t.slice(2, -2), opts)}</strong>);
    else if (m[3]) out.push(<del key={k++}>{renderInline(t.slice(2, -2), opts)}</del>);
    else if (m[4]) out.push(<em key={k++}>{renderInline(t.slice(1, -1), opts)}</em>);
    else if (m[5]) {
      const lm = t.match(/^\[([^\]]+)\]\((.+)\)$/)!;
      const href = safeHref(lm[2]);
      // A link the pane will not open draws as its text; a local path keeps its file mark.
      if (linkKind(lm[2]) === "file")
        out.push(
          <span key={k++} className="cv-link is-file" title={lm[2]}>
            {(opts.linkIcon ?? linkIcon)(lm[2])}
            {renderInline(lm[1], opts)}
          </span>,
        );
      else if (!href) out.push(<Fragment key={k++}>{renderInline(lm[1], opts)}</Fragment>);
      else
        out.push(
          <a key={k++} className={`cv-link is-${linkKind(href)}`} href={href} rel="noreferrer">
            {(opts.linkIcon ?? linkIcon)(href)}
            {renderInline(lm[1], opts)}
          </a>,
        );
    } else if (m[6]) out.push(<br key={k++} />);
    else if (m[7]) out.push(<MathInline key={k++} tex={t.slice(2, -2).trim()} display />);
    else if (m[8]) out.push(<MathInline key={k++} tex={t.slice(1, -1)} />);
    else if (m[9]) out.push(t.slice(1));
    last = m.index! + t.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/* ---------------- Blocks ---------------- */

function Block({
  block,
  opts,
  depth,
  enter = false,
  code = "final",
  tail,
}: {
  block: MdBlock;
  opts: InlineOptions;
  depth: number;
  /** The block appeared while the reply streams: it enters with the shared motion (`.cv-enter`). */
  enter?: boolean;
  /** A code block's stage: still open (plain lines), closed while streaming (highlighted once,
   * faded in), or drawn finished (highlighted). */
  code?: "open" | "handoff" | "final";
  /** The reply's newest characters, which fade in at the end of this, its last block. */
  tail?: FreshTail;
}): ReactNode {
  const motion = enter ? " cv-enter" : "";
  const inline = (text: string) => (tail ? renderFresh(text, tail, opts) : renderInline(text, opts));
  switch (block.type) {
    case "heading": {
      const H = `h${block.level}` as "h1";
      return <H className={`cv-h cv-h${block.level}${motion}`}>{inline(block.text)}</H>;
    }
    case "paragraph":
      return <p className={`cv-p${motion}`}>{inline(block.text)}</p>;
    case "hr":
      return <hr className={`cv-hr${motion}`} />;
    case "blockquote":
      return (
        <blockquote className={`cv-quote${motion}`}>
          <Blocks blocks={block.children} opts={opts} depth={depth} />
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
              {it.task && (
                <span className={`cv-checkbox${it.checked ? " is-checked" : ""}`}>
                  {it.checked && <Check size={12} strokeWidth={1.4} />}
                </span>
              )}
              <span className="cv-li__text">
                {i === block.items.length - 1 && !it.children.length ? inline(it.text) : renderInline(it.text, opts)}
              </span>
              {it.children.length > 0 && <Blocks blocks={it.children} opts={opts} depth={depth + 1} />}
            </li>
          ))}
        </L>
      );
    }
    case "table": {
      // Long-text columns get a 256px minimum and the rest 128px.
      const plain = (t: string) => t.replace(/[`*_~]|\[|\]\([^)]*\)/g, "");
      const wide = block.header.map((_, i) => block.rows.some((r) => plain(r[i] ?? "").length > 40));
      return (
        <div className={`cv-table-wrap${motion}`}>
          <table className="cv-table">
            <thead>
              <tr>
                {block.header.map((c, i) => (
                  <th key={i} style={{ textAlign: block.align[i] ?? "left", width: wide[i] ? 256 : 128 }}>
                    {renderInline(c, opts)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((r, ri) => (
                <tr key={ri}>
                  {r.map((c, i) => (
                    <td key={i} style={{ textAlign: block.align[i] ?? "left" }}>
                      {renderInline(c, opts)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    }
    case "code":
      if (code === "open") return <PlainCode code={block.code} lang={block.lang} open />;
      if (code === "handoff") return <CodeHandoff code={block.code} lang={block.lang} />;
      return <CodeBlock code={block.code} lang={block.lang} />;
    case "math":
      return <MathDisplay tex={block.tex} />;
  }
}

function Blocks({ blocks, opts, depth }: { blocks: MdBlock[]; opts: InlineOptions; depth: number }) {
  return (
    <>
      {blocks.map((b, i) => (
        <Fragment key={i}>
          <Block block={b} opts={opts} depth={depth} />
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
  // The live edge: a soft bar after the newest character, out of the text's layout (no reflow
  // when it leaves); it pulses only while the reveal waits for more (`.cv-md.is-waiting`).
  const caret = <span key="caret" className="cv-caret" aria-hidden="true" />;
  const fresh = tail.text.trimEnd();
  if (!fresh || !text.endsWith(fresh) || /[*`_~[\]()$\\\n]/.test(fresh)) return [...renderInline(text, opts), caret];
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
  return [...out, ...spans, caret];
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
  /** The reveal has shown everything so far and waits for more: the live edge pulses. */
  waiting?: boolean;
};

/** Assistant-message Markdown. A growing source (a streaming reply) is parsed incrementally. */
export function Markdown({
  children,
  className = "",
  linkIcon,
  streaming = false,
  fresh,
  now = 0,
  waiting = false,
}: MarkdownProps) {
  const parser = useRef<IncrementalMarkdown | null>(null);
  parser.current ??= new IncrementalMarkdown();
  const blocks = parser.current.update(children, { streaming });
  // Blocks there at the first render (history, a row scrolled into view) never animate.
  const atMount = useRef<Set<string> | null>(null);
  atMount.current ??= new Set(blocks.map((entry) => entry.key));
  const opts = useMemo(() => ({ linkIcon }), [linkIcon]);
  // Fences this reply drew open: they hand over to the highlighted card once, when they close.
  const streamedFences = useRef(new Set<string>());
  const freshChars = fresh?.reduce((sum, step) => sum + step.count, 0) ?? 0;
  // Only a revealed reply (RevealedMarkdown passes `fresh`) draws the live edge.
  const freshTail: FreshTail | undefined =
    streaming && fresh
      ? { steps: fresh, text: freshChars ? children.slice(children.length - freshChars) : "", now }
      : undefined;
  // An odd number of fence lines: the last block is a fence still arriving.
  const openFence = streaming && (children.match(/^\s*```/gm)?.length ?? 0) % 2 === 1;
  return (
    <div className={`cv-md selectable ${className}${streaming && waiting ? " is-waiting" : ""}`}>
      {blocks.map((entry, index) => {
        const live = !atMount.current!.has(entry.key);
        const open = openFence && index === blocks.length - 1;
        if (open) streamedFences.current.add(entry.key);
        return (
          <BlockView
            key={entry.key}
            block={entry.block}
            opts={opts}
            depth={0}
            enter={streaming && live}
            code={open ? "open" : live || streamedFences.current.has(entry.key) ? "handoff" : "final"}
            tail={index === blocks.length - 1 ? freshTail : undefined}
          />
        );
      })}
    </div>
  );
}
