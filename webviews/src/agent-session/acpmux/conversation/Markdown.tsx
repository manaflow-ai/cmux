import { BlockTail, InlineTail } from "./InlineTail";
// Ported from the agent-pane reference prototype (src/conversation/Markdown.tsx).
// A small GFM-subset Markdown renderer for assistant messages. It produces the same
// DOM shape for every transcript: headings, paragraphs (single newlines are line
// breaks), nested ordered/bullet/task lists, blockquotes, rules, aligned tables, fenced
// code blocks rendered by @pierre/diffs (see CodeBlock.tsx), vega-lite charts (DiagramBlock.tsx), live
// ```cmux-render pages (RenderCard.tsx), and `$…$`, `$$…$$`, `\(…\)`
// and `\[…\]` math typeset by KaTeX (see Math.tsx).
import { Fragment, memo, useId, useMemo, useRef, type CSSProperties, type ReactNode } from "react";

import { CodeBlock } from "./CodeBlock";
import { InlinePreview } from "./InlinePreview";
import { inlinePreviewKind } from "./previewDocument";
import { TableBlock } from "./TableBlock";
import { DiagramBlock } from "./DiagramBlock";
import { RenderCard } from "./RenderCard";
import { isChart } from "./diagramBlockModel";
import { canRender } from "./renderCardModel";
import { renderFence } from "./renderCall";
import { TourBlock, isTourFence } from "../repoTour/TourBlock";
import { RemoteMedia } from "../chips/ReplyMedia";
import { isRemoteMedia } from "../chips/replyMediaModel";
import { CodeHandoff, PlainCode } from "./StreamingCode";
import { MathDisplay } from "./Math";
import type { Reveal } from "./revealedMarkdownModel";
import { installSelectionCopy } from "./selectionCopy";

import { IncrementalMarkdown, type KeyedBlock } from "./incrementalMarkdown";
import { ReplyFoldersContext, replyFolders } from "../chips/replyFolders";

import "../../../markdown-task-checkbox.css";
import { TaskCheckbox } from "../../../ui/TaskCheckbox";
import { imageOnlyItems, proseImages, type ThumbItem } from "./inlineMedia";
import { acpmuxPerf } from "../perf";
import { useStartedMentions } from "../started/startedSessionCardModel";
import { entranceAllowed } from "../../shared/pageReveal";

import { type MdBlock, parseMarkdown, footnoteOrder, MAX_REPLY_DATA_URLS, dataUrlsOverBudget } from "./markdownModel";
import { type InlineOptions, renderInline, InlineImage } from "./inlineMarkdown";

/// A long list number (`1000.`) widens its items' indent so it never draws over their text; a
/// number of one or two digits keeps the list's usual indent.
function listNumberStyle(block: { ordered: boolean; start: number; items: unknown[] }): CSSProperties | undefined {
  if (!block.ordered) return undefined;
  const digits = String(block.start + block.items.length - 1).length;
  return digits > 2 ? ({ "--cv-ol-digits": digits } as CSSProperties) : undefined;
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

/* ---------------- Blocks ---------------- */

function Block({
  block,
  opts,
  depth,
  enter = false,
  code = "final",
  tail,
  trailing,
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
  trailing?: ReactNode;
  artifactIdentity?: string;
  artifactRevision?: number;
}): ReactNode {
  const motion = enter ? " cv-enter" : "";
  const inline = (text: string) => (
    <InlineTail trailing={trailing}>{tail ? renderFresh(text, tail, opts) : renderInline(text, opts)}</InlineTail>
  );
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
            <InlineTail trailing={trailing}>
              <RemoteMedia url={link} alt="" fallback={renderInline(block.text, opts)} />
            </InlineTail>
          </p>
        );
      // Only images (a before/after pair, a screenshot alone on its line): a row of thumbnails, once
      // the paragraph has finished arriving (a half-written line may still turn into prose).
      const images = tail || opts.thumbnails === false ? undefined : imageOnlyItems(block.text);
      if (images)
        return (
          <p className={`cv-p cv-p--images${motion}`}>
            <InlineTail trailing={trailing}>
              <Thumbs items={images} opts={opts} />
            </InlineTail>
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
      return (
        <BlockTail trailing={trailing}>
          <hr className={`cv-hr${motion}`} />
        </BlockTail>
      );
    case "blockquote":
      return (
        <blockquote className={`cv-quote${motion}`}>
          <Blocks
            blocks={block.children}
            opts={quoted(opts)}
            depth={depth}
            plain={code === "plain"}
            trailing={trailing}
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
          style={listNumberStyle(block)}
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
                  trailing={i === block.items.length - 1 ? trailing : undefined}
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
      return (
        <BlockTail trailing={trailing}>
          <TableBlock table={block} cell={(text) => renderInline(text, opts)} className={motion} />
        </BlockTail>
      );
    case "code": {
      // A repo tour (repoTour/): a ```cmux-tour fence is its card, a pending line while it streams,
      // never the streaming code it would otherwise draw as.
      if (code !== "plain" && isTourFence(block.lang, block.code, block.open === true))
        return (
          <BlockTail trailing={trailing}>
            <TourBlock lang={block.lang} code={block.code} open={block.open === true} />
          </BlockTail>
        );
      if (code === "open")
        return (
          <PlainCode
            code={block.code}
            lang={block.lang}
            actions={trailing}
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
            actions={trailing}
            artifactIdentity={artifactIdentity}
            artifactRevision={artifactRevision}
          />
        );
      // A diagram draws once its fence closes; a Mermaid source still streaming stays code.
      if (isChart(block.lang, block.code) && !(block.open && block.lang.toLowerCase() === "mermaid"))
        return <DiagramBlock lang={block.lang} code={block.code} actions={trailing} />;
      // A page in a closed ```cmux-render fence runs in the render frame; the dev server has none.
      const render = canRender() && !block.open ? renderFence(block.lang, block.code) : undefined;
      if (render) return <RenderCard call={render} actions={trailing} />;
      // A closed ```html or ```svg fence draws as its document in a sandboxed frame (InlinePreview.tsx);
      // an open one stayed plain code above, so nothing renders mid-stream.
      const preview = block.open ? undefined : inlinePreviewKind(block.lang, block.code);
      if (preview)
        return (
          <InlinePreview
            key={block.code}
            kind={preview}
            code={block.code}
            lang={block.lang}
            actions={trailing}
            artifactIdentity={artifactIdentity}
            artifactRevision={artifactRevision}
          />
        );
      if (code === "handoff")
        return (
          <CodeHandoff
            code={block.code}
            lang={block.lang}
            actions={trailing}
            artifactIdentity={artifactIdentity}
            artifactRevision={artifactRevision}
          />
        );
      return (
        <CodeBlock
          code={block.code}
          lang={block.lang}
          actions={trailing}
          artifactIdentity={artifactIdentity}
          artifactRevision={artifactRevision}
        />
      );
    }
    case "math":
      return (
        <BlockTail trailing={trailing}>
          <MathDisplay tex={block.tex} />
        </BlockTail>
      );
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
/// A quote's options: the same object for the same `opts`, so its memoized blocks stay drawn.
const quotedOptions = new WeakMap<InlineOptions, InlineOptions>();
function quoted(opts: InlineOptions): InlineOptions {
  if (opts.linkBareReferences === false) return opts;
  let kept = quotedOptions.get(opts);
  if (!kept) quotedOptions.set(opts, (kept = { ...opts, linkBareReferences: false }));
  return kept;
}

function Blocks({
  blocks,
  opts,
  depth,
  plain = false,
  trailing,
  artifactIdentity,
  artifactRevision,
}: {
  blocks: MdBlock[];
  opts: InlineOptions;
  depth: number;
  plain?: boolean;
  trailing?: ReactNode;
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
            trailing={i === blocks.length - 1 ? trailing : undefined}
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

/// The characters that can open or close inline Markdown (or break the line) in a fresh suffix.
const FRESH_SYNTAX = /[*`_~[\]()$\\\n]/;

/// Whether plain text appended to `prefix` draws as `prefix`'s own drawing followed by that text:
/// nothing in `prefix` is left open for the text to join (an unpaired `**`, `` ` ``, `$` or `[`, a
/// link's `](` with no `)` yet, or a trailing backslash). A plain `(` opens nothing, so text inside
/// parentheses still fades. Conservative: an odd `_` inside a word also says no.
function closedInline(prefix: string): boolean {
  if (prefix.endsWith("\\")) return false;
  const count = (char: string) => prefix.split(char).length - 1;
  const link = prefix.lastIndexOf("](");
  return (
    ["*", "`", "_", "~", "$"].every((char) => count(char) % 2 === 0) &&
    count("[") === count("]") &&
    (link < 0 || prefix.indexOf(")", link) >= 0)
  );
}

/// `text` with its newest characters in spans that fade in (`.cv-fresh`). Each span keeps its key
/// and a negative animation delay, so a re-render never restarts its fade. Only plain trailing
/// text fades by step: when the newest text has Markdown syntax or a line break in it, the plain
/// words after the last of those still fade, as long as nothing before them is left open; else
/// it draws as usual. Skipping the whole fade on any `(`, `` ` `` or line break left most replies
/// with none (Leo, 2026-11-03: "hey even u have that text fading in! i want that...").
function renderFresh(text: string, tail: FreshTail, opts: InlineOptions): ReactNode[] {
  let fresh = tail.text.trimEnd();
  if (!fresh || !text.endsWith(fresh)) return renderInline(text, opts);
  if (FRESH_SYNTAX.test(fresh)) {
    let last = fresh.length - 1;
    while (last >= 0 && !FRESH_SYNTAX.test(fresh[last]!)) last -= 1;
    fresh = fresh.slice(last + 1);
    const prefix = text.slice(0, text.length - fresh.length);
    if (!fresh.trim() || !closedInline(prefix)) return renderInline(text, opts);
    // A closer at the prefix's end that a following word character (or `:`) would cancel (italic
    // `_x_`/`*x*`, inline math `$x$`, a footnote `[^1]`) would draw for the fade and then flip.
    if (/[*_$\]]$/.test(prefix) && /^[\w:]/.test(fresh)) return renderInline(text, opts);
  }
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
  trailing?: ReactNode;
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
  trailing,
  skills,
  commonmark = false,
  claims,
}: MarkdownProps) {
  // A selection copied out of a message keeps its formatting (selectionCopy.ts); once per page.
  installSelectionCopy();
  const parser = useRef<IncrementalMarkdown | null>(null);
  parser.current ??= new IncrementalMarkdown();
  // A sent prompt (`commonmark`) is whole, never streamed: it parses at once, its code read as send
  // reads it (parseMarkdown `commonmark`), which the streaming boundaries do not follow.
  const whole = useMemo(
    () =>
      commonmark
        ? parseMarkdown(children, { messageAt, commonmark: true }).map((block, index) => ({
            key: String(index),
            block,
          }))
        : undefined,
    [commonmark, children, messageAt],
  );
  const blocks =
    whole ?? acpmuxPerf.timed("markdown.parse", () => parser.current!.update(children, { streaming, messageAt }));
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
  // The folders this reply's paths are in, joined so a streaming reply keeps the same value (and
  // its memoized blocks) until a new folder arrives; its bare file names may be files there.
  const folderKey = useMemo(() => replyFolders(children).join("\n"), [children]);
  const folders = useMemo(() => (folderKey ? folderKey.split("\n") : []), [folderKey]);
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
      ...(skills?.size ? { skills } : {}),
      ...(commonmark ? { commonmark } : {}),
      ...(claims?.length ? { claims } : {}),
    };
  }, [commits, githubRepository, linkIcon, noteIds, notePrefix, overBudget, started, thumbnails, skills, commonmark, claims]);
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
        trailing={index === trailingIndex ? trailing : undefined}
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
  // Notes are displayed in reference order, which may differ from their source order.
  const trailingIndex = notes.at(-1)?.index ?? blocks.length - 1;
  return (
    <ReplyFoldersContext.Provider value={folders}>
      <div className={`cv-md selectable ${className}`}>
        {blocks.map((entry, index) => (entry.block.type === "footnote" ? null : draw(entry, index)))}
        {notes.length > 0 && (
          <section className="cv-footnotes" role="doc-endnotes">
            <ol>{notes.map(({ entry, index }) => draw(entry, index))}</ol>
          </section>
        )}
      </div>
    </ReplyFoldersContext.Provider>
  );
}
