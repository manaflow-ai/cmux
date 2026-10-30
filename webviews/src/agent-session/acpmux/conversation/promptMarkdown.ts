// Whether a sent prompt's typed text is written in Markdown (PromptText.tsx PromptTyped). Only real
// Markdown goes through the transcript renderer: block syntax at the start of a line, or inline
// syntax that is paired. A lone character never does, so `snake_case`, "$5", "#123", "a<b", "x|y"
// and a bare address stay the literal text the person typed, line breaks and all (Leo 2026-10-29:
// "how do you want to detect if it's Markdown?"). Copy and Edit keep the source either way.

/// Block syntax at a line start, after at most three spaces of indent: a quote (`> `), a list item
/// (`- `, `* `, `+ `, `1. `, `1) `), a fence (```` ``` ```` or `~~~`) or an ATX heading (`#` to
/// `######` and a space). `#123` and `#tag` have no space, so they are text.
const BLOCK = /(?:^|\n) {0,3}(?:>(?:[ \t]|$)|[-*+][ \t]+\S|\d{1,9}[.)][ \t]+\S|```|~~~|#{1,6}[ \t]+\S)/m;

/// A pipe table: a row holding a `|`, then its separator row (`---|---`, `| :-- | --: |`).
const TABLE = /(?:^|\n)[^\n]*\|[^\n]*\n {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*(?:\n|$)/;

/// Paired inline syntax on one line: a code span (`` `x` ``), strong text (`**x**`, not touching
/// spaces inside its markers) or a link (`[t](url)`, an image's `![t](url)` included).
const INLINE = /`[^`\n]+`|\*\*(?=[^\s*])[^\n]*?[^\s*]\*\*|\*\*[^\s*]\*\*|\[[^\]\n]+\]\([^)\s]+(?:[ \t]+"[^"\n]*")?\)/;

/// True when `text` holds Markdown the bubble should render rather than draw literally.
export function isPromptMarkdown(text: string): boolean {
  return BLOCK.test(text) || TABLE.test(text) || INLINE.test(text);
}
