// Prototype: streaming-safe, incremental Markdown with a soft reveal, for bench/stream only.
//
// 1. Incremental parse. StableSplitter scans each complete line once and marks block boundaries
//    that later text cannot change (after a closed fence, a heading, a rule, or a blank line that
//    the next line confirms is not a list or table continuation). Text before the last boundary
//    is split into closed segments, each parsed once by the production parser and memoized by its
//    source; only the tail segment re-parses per frame. Closed code fences reach Pierre once.
// 2. Streaming-safe tail. The tail holds back what would draw wrongly half-written: a fence
//    opener line until its newline, a table until its separator row and each row until its
//    newline, a `[link](` until its `)`; an odd `**` or backtick is closed virtually so text
//    is bold or code from its first character instead of flipping when the closer arrives.
//    An open fence draws as a plain monospace card (same chrome, 20px lines) until it closes.
// 3. Soft reveal. Characters revealed in the last FADE_MS draw inside spans that animate
//    opacity 0 -> 1 (compositor only); each span keeps its key and a negative animation-delay,
//    so a re-render never restarts a fade. Older text merges back into plain text nodes.
//
// The production renderer (conversation/Markdown.tsx) does not export its block renderer, so
// this file carries a copy of it; the real slice adds these hooks to Markdown.tsx instead.
import { Fragment, memo, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { parseMarkdown, renderInline, type MdBlock } from "../../src/agent-session/acpmux/conversation/Markdown";
import { CodeBlock, languageLabel } from "../../src/agent-session/acpmux/conversation/CodeBlock";
import { MathDisplay } from "../../src/agent-session/acpmux/conversation/Math";
import { Check, CodeBrackets } from "../../src/agent-session/acpmux/conversation/icons";

export const FADE_MS = 160;

const LIST_START = /^(\s*)([-*+]|\d+[.)])\s+/;
const FENCE = /^\s*```/;

/** Block boundaries of a growing message, found by scanning each complete line once. */
export class StableSplitter {
  /** Offsets where a closed segment ends and the next begins; always starts with 0. */
  readonly boundaries: number[] = [0];
  private scanned = 0;
  private inFence = false;
  private pendingBlank: number | undefined;
  private source = "";

  /** Scans the complete lines `source` added since the last call. `source` only grows. */
  update(source: string): void {
    if (!source.startsWith(this.source)) this.reset();
    this.source = source;
    let lineStart = this.scanned;
    while (true) {
      const newline = source.indexOf("\n", lineStart);
      if (newline < 0) break;
      const line = source.slice(lineStart, newline);
      const next = newline + 1;
      if (this.pendingBlank !== undefined && line.trim()) {
        // A blank line ends a block unless this line continues a list (marker or indent) or a quote.
        if (!LIST_START.test(line) && !/^\s/.test(line) && !/^\s*>/.test(line)) this.mark(lineStart);
        this.pendingBlank = undefined;
      }
      if (FENCE.test(line)) {
        if (this.inFence) this.mark(next);
        else if (lineStart > 0 && this.boundaries.at(-1) !== lineStart) this.mark(lineStart);
        this.inFence = !this.inFence;
      } else if (!this.inFence) {
        if (!line.trim()) this.pendingBlank = lineStart;
        else if (/^#{1,4}\s/.test(line) || /^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) this.mark(next);
      }
      lineStart = next;
    }
    this.scanned = lineStart;
  }

  private mark(offset: number): void {
    if (offset > (this.boundaries.at(-1) ?? 0)) this.boundaries.push(offset);
  }

  private reset(): void {
    this.boundaries.length = 1;
    this.scanned = 0;
    this.inFence = false;
    this.pendingBlank = undefined;
  }
}

/** What of the tail may draw now, and whether its last block is an open fence. */
export function safeTail(tail: string): { text: string; openFence: boolean } {
  const lines = tail.split("\n");
  let fence = false;
  for (let index = 0; index < lines.length - 1; index += 1) if (FENCE.test(lines[index])) fence = !fence;
  let last = lines.at(-1) ?? "";
  // A fence opener (or closer) still on its first line: hold it until its newline.
  if (/^\s*`{1,3}[^`]*$/.test(last) && /^\s*`/.test(last)) last = "";
  else if (!fence) {
    // A table row draws once complete; a header waits for its separator row.
    if (/^\s*\|/.test(last)) last = "";
    const complete = lines.slice(0, -1);
    const header = complete.length - 1;
    if (header >= 0 && /^\s*\|/.test(complete[header]) && !(header > 0 && /^\s*\|/.test(complete[header - 1])))
      lines[header] = "";
    else if (header >= 0 && /^\s*\|?\s*:?-/.test(complete[header]) && /^\s*\|/.test(complete[header - 1] ?? "")) {
      // A separator line still being typed (no cells closed yet) holds its header back too.
      if (!/-\s*\|/.test(complete[header])) lines[header] = lines[header - 1] = "";
    }
    // A link waits for its closing parenthesis.
    const open = last.lastIndexOf("[");
    if (open >= 0 && !/\]\([^)]*\)/.test(last.slice(open))) last = last.slice(0, open);
  }
  lines[lines.length - 1] = last;
  let text = lines.join("\n");
  if (!fence) {
    // A marker still being typed at the very end is held back; an open one is closed virtually.
    const paragraph = () => text.slice(text.lastIndexOf("\n\n") + 1);
    const odd = (re: RegExp, value: string) => (value.match(re)?.length ?? 0) % 2 === 1;
    if (odd(/\*\*/g, paragraph())) {
      const stripped = text.replace(/\*{1,2}\s*$/, "");
      text = odd(/\*\*/g, stripped.slice(stripped.lastIndexOf("\n\n") + 1)) ? `${stripped}**` : stripped;
    }
    if (odd(/`/g, paragraph().replace(/\*\*/g, ""))) {
      const stripped = text.replace(/`\s*$/, "");
      text = odd(/`/g, stripped.slice(stripped.lastIndexOf("\n\n") + 1)) ? `${stripped}\`` : stripped;
    }
  }
  const opened = text.split("\n").filter((line) => FENCE.test(line)).length % 2 === 1;
  return { text, openFence: opened };
}

/** A recent reveal: `count` characters at `born` (performance.now()). */
export type Reveal = { id: number; count: number; born: number };

/** Splits the last `fresh` characters of `text` into fading spans, newest last. */
function withFresh(text: string, reveals: Reveal[], now: number, fade: boolean): ReactNode[] {
  if (!fade || !reveals.length) return [text];
  const out: ReactNode[] = [];
  let end = text.length;
  const spans: ReactNode[] = [];
  for (let index = reveals.length - 1; index >= 0 && end > 0; index -= 1) {
    const reveal = reveals[index];
    const start = Math.max(0, end - reveal.count);
    spans.unshift(
      <span key={reveal.id} className="sv-fresh" style={{ animationDelay: `${-(now - reveal.born)}ms` }}>
        {text.slice(start, end)}
      </span>,
    );
    end = start;
  }
  if (end > 0) out.push(text.slice(0, end));
  return out.concat(spans);
}

/** The last inline text of the tail renders through renderInline except its fresh suffix. */
function TailInline({ text, reveals, now, fade }: { text: string; reveals: Reveal[]; now: number; fade: boolean }) {
  const freshChars = reveals.reduce((sum, reveal) => sum + reveal.count, 0);
  // Fresh text inside an inline construct (bold, code, link) fades with its construct's block;
  // plain trailing text fades per reveal.
  const tailPlain = /[*`_~\][$]/.exec(text.slice(Math.max(0, text.length - freshChars))) === null;
  if (!fade || !tailPlain || freshChars === 0) return <>{renderInline(text)}</>;
  const cut = Math.max(0, text.length - freshChars);
  return (
    <>
      {renderInline(text.slice(0, cut))}
      {withFresh(text.slice(cut), reveals, now, fade)}
    </>
  );
}

type TailProps = { reveals: Reveal[]; now: number; fade: boolean; caret: boolean };

function Block({ block, depth, tail }: { block: MdBlock; depth: number; tail?: TailProps }): ReactNode {
  const inline = (text: string) =>
    tail ? (
      <>
        <TailInline text={text} reveals={tail.reveals} now={tail.now} fade={tail.fade} />
        {tail.caret && <span className="sv-caret" aria-hidden="true" />}
      </>
    ) : (
      renderInline(text)
    );
  switch (block.type) {
    case "heading": {
      const H = `h${block.level}` as "h1";
      return <H className={`cv-h cv-h${block.level}`}>{inline(block.text)}</H>;
    }
    case "paragraph":
      return <p className="cv-p">{inline(block.text)}</p>;
    case "hr":
      return <hr className="cv-hr" />;
    case "blockquote":
      return (
        <blockquote className="cv-quote">
          {block.children.map((child, index) => (
            <Fragment key={index}>
              <Block block={child} depth={depth} tail={index === block.children.length - 1 ? tail : undefined} />
            </Fragment>
          ))}
        </blockquote>
      );
    case "list": {
      const L = block.ordered ? "ol" : "ul";
      const tasks = block.items.every((item) => item.task);
      return (
        <L
          className={`cv-list ${block.ordered ? "cv-ol" : "cv-ul"}${tasks ? " cv-tasks" : ""}`}
          data-depth={depth}
          start={block.ordered && block.start !== 1 ? block.start : undefined}
        >
          {block.items.map((item, index) => {
            const last = index === block.items.length - 1;
            return (
              <li
                key={index}
                className={`${item.task ? "cv-task" : ""}${tail && last ? " sv-enter" : ""}`.trim() || undefined}
              >
                {block.ordered && <span className="cv-li__num">{block.start + index}.</span>}
                {!block.ordered && !item.task && <span className={`cv-li__bullet cv-li__bullet--${depth % 3}`} />}
                {item.task && (
                  <span className={`cv-checkbox${item.checked ? " is-checked" : ""}`}>
                    {item.checked && <Check size={12} strokeWidth={1.4} />}
                  </span>
                )}
                <span className="cv-li__text">
                  {last && tail && !item.children.length ? inline(item.text) : renderInline(item.text)}
                </span>
                {item.children.length > 0 &&
                  item.children.map((child, childIndex) => (
                    <Fragment key={childIndex}>
                      <Block
                        block={child}
                        depth={depth + 1}
                        tail={last && childIndex === item.children.length - 1 ? tail : undefined}
                      />
                    </Fragment>
                  ))}
              </li>
            );
          })}
        </L>
      );
    }
    case "table": {
      const plain = (text: string) => text.replace(/[`*_~]|\[|\]\([^)]*\)/g, "");
      const wide = block.header.map((_, index) => block.rows.some((row) => plain(row[index] ?? "").length > 40));
      return (
        <div className="cv-table-wrap">
          <table className="cv-table">
            <thead>
              <tr className={tail ? "sv-enter" : undefined}>
                {block.header.map((cell, index) => (
                  <th key={index} style={{ textAlign: block.align[index] ?? "left", width: wide[index] ? 256 : 128 }}>
                    {renderInline(cell)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((row, rowIndex) => (
                // Each row is complete when it draws; it fades in whole.
                <tr key={rowIndex} className={tail ? "sv-enter" : undefined}>
                  {row.map((cell, index) => (
                    <td key={index} style={{ textAlign: block.align[index] ?? "left" }}>
                      {renderInline(cell)}
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
      return tail ? (
        <StreamingCode code={block.code} lang={block.lang} tail={tail} />
      ) : (
        <CodeHandoff code={block.code} lang={block.lang} />
      );
    case "math":
      return <MathDisplay tex={block.tex} />;
  }
}

/**
 * A fence that just closed: the plain card stays in flow while Pierre highlights underneath it.
 * Pierre paints its lines a frame or more after mount (an empty, collapsed card in between), so
 * the highlighted card fades in over the plain one only once its lines exist, and the plain one
 * leaves when that fade ends. Same metrics, so nothing moves; only the colors arrive.
 */
function CodeHandoff({ code, lang }: { code: string; lang: string }) {
  const [stage, setStage] = useState<"plain" | "fading" | "done">("plain");
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (stage !== "plain") return;
    let frame = 0;
    const check = () => {
      const host = ref.current?.querySelector("diffs-container");
      if (host?.shadowRoot?.querySelector("[data-line]")) {
        const plain = ref.current?.querySelector(".sv-code-card")?.getBoundingClientRect().height ?? 0;
        const real =
          ref.current?.querySelector(".sv-handoff__real > .cv-codeblock")?.getBoundingClientRect().height ?? 0;
        (window as unknown as { __stream?: { code: { samples: number[][] } } }).__stream?.code.samples.push([
          plain,
          real,
        ]);
        setStage("fading");
      } else frame = requestAnimationFrame(check);
    };
    check();
    return () => cancelAnimationFrame(frame);
  }, [stage]);
  return (
    <div ref={ref} className={`sv-handoff is-${stage}`}>
      {stage !== "done" && <PlainCode code={code} lang={lang} />}
      <div className="sv-handoff__real" onAnimationEnd={() => setStage("done")}>
        <CodeBlock code={code} lang={lang} />
      </div>
    </div>
  );
}

function PlainCode({ code, lang }: { code: string; lang: string }) {
  return (
    <div className="cv-codeblock sv-code-card">
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{languageLabel(lang)}</span>
      </div>
      <div className="cv-codeblock__body">
        <pre className="sv-code">
          {code.split("\n").map((line, index) => (
            <div key={index} className="sv-code-line">
              {line || "\u200b"}
            </div>
          ))}
        </pre>
      </div>
    </div>
  );
}

/** An open fence: Pierre's chrome and metrics over plain lines; highlighting waits for the close. */
function StreamingCode({ code, lang, tail }: { code: string; lang: string; tail: TailProps }) {
  const lines = code.split("\n");
  // A trailing empty line is the newline before a line (or the closing fence) still arriving:
  // drawing it would make the card a line taller than the closed card it becomes.
  if (lines.length > 1 && lines.at(-1) === "") lines.pop();
  return (
    <div className="cv-codeblock sv-code-card">
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{languageLabel(lang)}</span>
      </div>
      <div className="cv-codeblock__body">
        <pre className="sv-code">
          {lines.map((line, index) =>
            index === lines.length - 1 ? (
              <div key={index} className="sv-code-line">
                {withFresh(line, tail.reveals, tail.now, tail.fade)}
                {tail.caret && <span className="sv-caret" aria-hidden="true" />}
              </div>
            ) : (
              <div key={index} className="sv-code-line">
                {line || "​"}
              </div>
            ),
          )}
        </pre>
      </div>
    </div>
  );
}

/** A closed segment: parsed once, rendered once. */
const ClosedSegment = memo(function ClosedSegment({ source }: { source: string }) {
  const blocks = parseMarkdown(source);
  return (
    <>
      {blocks.map((block, index) => (
        <Fragment key={index}>
          <Block block={block} depth={0} />
        </Fragment>
      ))}
    </>
  );
});

export type StreamingMarkdownProps = {
  /** The revealed prefix of the message source. */
  source: string;
  splitter: StableSplitter;
  reveals: Reveal[];
  now: number;
  streaming: boolean;
  fade: boolean;
};

/** Assistant Markdown that grows: closed segments memoized, the tail re-parsed, fresh text fading. */
export function StreamingMarkdown({ source, splitter, reveals, now, streaming, fade }: StreamingMarkdownProps) {
  splitter.update(source);
  const bounds = splitter.boundaries;
  const segments: { start: number; text: string }[] = [];
  for (let index = 0; index < bounds.length - 1; index += 1)
    segments.push({ start: bounds[index], text: source.slice(bounds[index], bounds[index + 1]) });
  const tailStart = bounds.at(-1) ?? 0;
  const tail = streaming ? safeTail(source.slice(tailStart)) : { text: source.slice(tailStart), openFence: false };
  const tailBlocks = parseMarkdown(tail.text);
  const tailProps: TailProps = { reveals, now, fade, caret: streaming };
  return (
    <div className="cv-md">
      {segments.map((segment) => (
        <ClosedSegment key={segment.start} source={segment.text} />
      ))}
      {tailBlocks.map((block, index) => (
        <Fragment key={`t${tailStart}:${index}`}>
          <Block block={block} depth={0} tail={index === tailBlocks.length - 1 && streaming ? tailProps : undefined} />
        </Fragment>
      ))}
    </div>
  );
}
