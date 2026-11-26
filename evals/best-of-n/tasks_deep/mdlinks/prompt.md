Fix code handling in `mdlinks.py`, the markdown link helpers used by the chat pane and the README renderer.

Bug report: "We render READMEs with `rewrite_links` to turn relative links into GitHub URLs. It also rewrote an
example inside a fenced code block: the README shows a shell snippet
`curl -o out.md [docs](https://github.com/acme/app/blob/main/docs/guide.md)` that originally said `[docs](docs/guide.md)`."

Contract: every function treats code exactly as the module docstring defines it (CommonMark code spans and fenced
code blocks), and nothing inside code is ever reported, counted or rewritten as a link, an image or an autolink,
while everything outside code is handled as it is today. `code_ranges` returns exactly the code in a document
under that definition, each span or block once, from its opening backticks or fence line through its closing
backticks or fence line (or the end of the document).

A second report: "Opening a long agent transcript freezes the chat pane." Each function must run in about
O(n log n) for a document of n characters: on a 400 KB document with 10,000 code spans and 10,000 links,
`find_links`, `all_urls`, `rewrite_links` and `code_ranges` together take well under 2 s. Fence indentation is
exactly as the docstring says: an opening or closing fence line may be indented at most 3 spaces, and a line
indented 4 or more is never a fence (its backticks are then ordinary text or code-span runs).
