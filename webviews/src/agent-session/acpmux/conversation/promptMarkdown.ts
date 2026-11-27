// Whether a sent prompt's typed text is written in Markdown (PromptText.tsx PromptTyped). Only real
// Markdown goes through the transcript renderer: block syntax at the start of a line, or inline
// syntax that is paired. A lone character never does, so `snake_case`, "$5", "#123", "a<b", "x|y"
// and a bare address stay the literal text the person typed, line breaks and all (Leo 2026-10-29:
// "how do you want to detect if it's Markdown?"). Copy and Edit keep the source either way.
//
// Each pattern is a subset of what Markdown.tsx parses, so a prompt sent there renders as Markdown,
// and each runs in linear time: a prompt can be a 64k paste of `|` or `[`, tested while drawing.

/// Block syntax at a line start, as Markdown.tsx parses it: after any indent, a quote (`> `), a list
/// item (`- `, `* `, `+ `, `1. `, `1) `, with a number of any length as LIST_RE takes it) or a
/// ```` ``` ```` fence; at the line's very start, a heading (`#` to `######` and a space). `#123`
/// and `#tag` have no space, so they are text.
const BLOCK = /(?:^|\n)(?:[ \t]*(?:>(?:[ \t]|$)|[-*+][ \t]+\S|\d+[.)][ \t]+\S|```)|#{1,6}[ \t]+\S)/;

/// Paired inline syntax, as Markdown.tsx's INLINE_RE reads it: a code span (`` `x` ``), strong
/// text (`**x**`, no `*` inside and no space just inside its markers) or a link (`[t](url)`, an
/// image's `![t](url)` included). No class can run past the next opener, so no match backtracks
/// over the text after it.
const INLINE =
  /`[^`\n]+`|\*\*[^*\s](?:[^*\n]*[^*\s])?\*\*|!?\[[^[\]\n]+\]\((?:[^()\s]|\([^()\s]*\))+\)|!\[\]\((?:[^()\s]|\([^()\s]*\))+\)/;

/// A table's separator row (`---|---`, `| :-- | --: |`, `|---|`), as Markdown.tsx reads it.
const SEPARATOR = /^[ \t]*(?:\|[ \t]*)?:?-{2,}:?[ \t]*(?:\|[ \t]*:?-{2,}:?[ \t]*)*(?:\|[ \t]*)?$/;

/// A pipe table: a row holding a `|`, then a separator row holding one.
function hasTable(text: string): boolean {
  if (!text.includes("|") || !text.includes("--")) return false;
  const lines = text.split("\n");
  for (let i = 1; i < lines.length; i++)
    if (lines[i]!.includes("|") && lines[i - 1]!.includes("|") && SEPARATOR.test(lines[i]!)) return true;
  return false;
}

/// True when `text` holds Markdown the bubble should render rather than draw literally.
/// Line endings are read as Markdown.tsx reads them (`src.replace(/\r\n?/g, "\n")`), so a `\r\n` or
/// lone `\r` paste gates the same as its `\n` form.
export function isPromptMarkdown(text: string): boolean {
  const src = text.includes("\r") ? text.replace(/\r\n?/g, "\n") : text;
  return BLOCK.test(src) || INLINE.test(src) || hasTable(src);
}
