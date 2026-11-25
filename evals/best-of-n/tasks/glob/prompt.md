Implement `match(pattern: str, name: str) -> bool` in `glob.py` (no fnmatch, re or glob modules). `*` matches any run
of characters except `/`; `**` matches any run including `/`; `?` matches one character except `/`; `[abc]`, `[a-z]`
and negated `[!a-z]` match one character (never `/`); `\` escapes the next character so `\*` matches a literal `*`.
A `[` with no closing `]` is a literal `[`. The whole name must match. It must run in polynomial time: `match("a*" * 30
+ "b", "a" * 60)` returns False within a second.
