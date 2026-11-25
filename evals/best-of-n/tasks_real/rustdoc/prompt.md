Fix `doc(text, indent="") -> list[str]` in `rustdoc.py`. A code generator uses it to turn a schema field's
description into a Rust doc comment.

Bug report (from cmux commit 98570c7fbad, "escape rustdoc link brackets in generated docs"): a description that
mentions `[::1]` became `/// ... [::1] ...` in generated Rust, which rustdoc reads as an intra-doc link and warns
about (and `cargo doc -D warnings` fails on). Brackets must be escaped too, and doing that has to keep backslashes
already in the text from combining with the new escapes.

The function:

- Empty or None `text` gives `[]`.
- Otherwise `str(text)` with every run of whitespace (spaces, tabs, newlines) folded to one space and the ends trimmed;
  if nothing is left, `[]`.
- Then escape for Markdown: every `\` becomes `\\`, and each of `` ` ``, `<`, `[` and `]` gets a `\` in front. A
  backslash in the input is escaped once, and a backslash added in front of one of the other characters is never
  escaped again. No other character changes (`>` stays as it is).
- The result is one line, `f"{indent}/// {escaped}"`, in a list.
