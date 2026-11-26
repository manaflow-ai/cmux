Implement `is_ignored(patterns: list[str], path: str, is_dir: bool = False) -> bool` in `gitmatch.py`: decide
whether `path` (relative to the repository root, `/`-separated, no leading `/`) is ignored by the lines of one
root `.gitignore`, following git's rules (do not shell out to git; `fnmatch` alone is not enough).

- Blank lines and lines starting with `#` are ignored; `\#` and `\!` at the start mean a literal `#`/`!`. Trailing
  unescaped spaces are stripped (`\ ` keeps a space).
- `!` negates: a later matching pattern wins, and a negated match re-includes. BUT a file cannot be re-included if
  one of its parent directories is excluded (git never descends into an excluded directory).
- A trailing `/` means the pattern matches only directories (it is removed before matching).
- If the pattern (after removing a trailing `/`) contains a `/` anywhere else (start or middle), it is anchored to
  the root and matched against the whole path (a leading `/` is removed). Otherwise it matches the last component
  of the path at any depth.
- `*` matches anything except `/`, `?` one character except `/`, `[...]` a character class (`[!...]` or `[^...]`
  negates, ranges allowed). `\x` matches `x` literally.
- `**`: a leading `**/` matches in any directory (including the root), a trailing `/**` matches everything inside,
  and `/**/` matches zero or more directories. Any other `**` behaves like `*`.
- A path is ignored if it or any of its parent directories is ignored (each parent is checked as a directory, with
  the patterns applied in order and the last match winning, from the top down).
