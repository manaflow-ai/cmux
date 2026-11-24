Fix code handling in `mdlinks.py`, the markdown link helpers used by the chat pane and the README renderer.

Bug report: "We render READMEs with `rewrite_links` to turn relative links into GitHub URLs. It also rewrote an
example inside a fenced code block: the README shows a shell snippet
`curl -o out.md [docs](https://github.com/acme/app/blob/main/docs/guide.md)` that originally said `[docs](docs/guide.md)`."

Contract: every function treats code exactly as the module docstring defines it (CommonMark code spans and fenced
code blocks), and nothing inside code is ever reported, counted or rewritten as a link, an image or an autolink,
while everything outside code is handled as it is today. `code_ranges` returns exactly the code in a document
under that definition, each span or block once, from its opening backticks or fence line through its closing
backticks or fence line (or the end of the document).
