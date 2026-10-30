// The inline Markdown an agent writes in a question, its options' labels and their descriptions:
// `code`, **bold**, *italic* or _italic_, ~~struck~~, and a backslash escape. Claude Code's own card
// draws these as marks; drawn as plain text they showed their backticks and asterisks. Only marks:
// an option row is a button, so a link draws as its label (a link or chip inside the row would
// take the click that answers it), and nothing here loads, runs or opens anything.
import { Fragment, type ReactNode } from "react";

// Groups: code, bold, strikethrough, italic, link (its label), backslash escape. The same shapes
// the transcript's renderInline reads (conversation/Markdown.tsx), so an agent's text reads alike,
// and a little stricter where a question's short text needs it:
// - a mark's body may hold an escaped character and, in bold, a single `*` (`**a *b* c**`);
// - emphasis needs text on both sides of it (`*.ts or *.js` stays text) and never starts or ends
//   against a letter, digit, `/` or `\` (`snake_case_name`, `src/_gen_/x.ts`, a URL stay text);
// - a link's destination may hold one level of parentheses, its label no bracket.
// Every body is a run of disjoint alternatives, so a match is linear in the text it reads.
const MARKS = new RegExp(
  [
    /(`[^`\n]+`)/.source,
    /(\*\*(?=[^\s*])(?:\\.|[^*\\\n]|\*(?!\*))+(?<!\s)\*\*)/.source,
    /(~~(?=\S)(?:\\.|[^~\\\n])+(?<!\s)~~)/.source,
    "(" +
      /(?<![\p{L}\p{N}_*/\\])\*(?=[^\s*])(?:\\.|[^*\\\n])+(?<!\s)\*(?![\p{L}\p{N}_*/])/u.source +
      "|" +
      /(?<![\p{L}\p{N}_/\\])_(?=[^\s_])(?:\\.|[^_\\\n])+(?<!\s)_(?![\p{L}\p{N}_/])/u.source +
      ")",
    /(\[[^[\]\n]+\]\((?:[^()\s]|\([^()\s]*\))+\))/.source,
    /(\\[\\`*_{}[\]()#+\-.!$|~<>])/.source,
  ].join("|"),
  "gu",
);

/// True when `text` holds a mark this reads (so plain text keeps its exact string).
export const hasMarks = (text: string): boolean => new RegExp(MARKS.source, "u").test(text);

/// `text` with its inline marks drawn; plain text comes back as the same string.
export function inlineText(text: string): ReactNode {
  if (!hasMarks(text)) return text;
  return marks(text, "m");
}

/// `text` as it reads with its marks drawn, as a string: for a caption or a name built from it.
export function plainText(text: string): string {
  if (!hasMarks(text)) return text;
  let out = "";
  let last = 0;
  for (const match of text.matchAll(MARKS)) {
    out += text.slice(last, match.index);
    const whole = match[0];
    if (match[1]) out += whole.slice(1, -1);
    else if (match[2] || match[3]) out += plainText(whole.slice(2, -2));
    else if (match[4]) out += plainText(whole.slice(1, -1));
    else if (match[5]) out += plainText(whole.slice(1, whole.indexOf("](")));
    else out += whole.slice(1);
    last = match.index! + whole.length;
  }
  return out + text.slice(last);
}

function marks(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let index = 0;
  for (const match of text.matchAll(MARKS)) {
    const at = match.index!;
    if (at > last) out.push(text.slice(last, at));
    const whole = match[0];
    const k = `${key}.${index++}`;
    if (match[1])
      out.push(
        <code key={k} className="acpmux-question-code">
          {whole.slice(1, -1)}
        </code>,
      );
    else if (match[2]) out.push(<strong key={k}>{marks(whole.slice(2, -2), k)}</strong>);
    else if (match[3]) out.push(<del key={k}>{marks(whole.slice(2, -2), k)}</del>);
    else if (match[4]) out.push(<em key={k}>{marks(whole.slice(1, -1), k)}</em>);
    else if (match[5]) out.push(<Fragment key={k}>{marks(whole.slice(1, whole.indexOf("](")), k)}</Fragment>);
    else out.push(whole.slice(1));
    last = at + whole.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}
