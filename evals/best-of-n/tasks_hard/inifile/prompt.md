Implement `parse(text: str) -> dict[str, dict[str, str]]` in `inifile.py` (no `configparser`).

- Lines are split on `\n` (strip a trailing `\r`). Blank lines and lines whose first non-blank character is `;` or
  `#` are ignored.
- `[name]` (surrounding blanks allowed, name stripped, non-empty) starts a section. Section and key names are
  case-insensitive: store them lower-cased. A repeated section header continues the same section.
- `key = value` or `key: value`, split at the FIRST `=` or `:`, whichever comes first; key and value are stripped;
  an empty key is an error; an empty value is allowed. A later duplicate key in the same section overwrites.
- Keys before any section go into section `"default"`. Every key of `"default"` is visible in every other section
  when that section lacks it (the result dict for each section includes the inherited keys; `"default"` itself is in
  the result only if it has keys).
- Inline comments: ` ;` or ` #` (a blank followed by `;` or `#`) ends the value; `a=x;y` keeps `x;y`.
- Continuation: a line that starts with a blank (space or tab) and follows a key line is appended to that value with
  a single `\n` between (the continuation line stripped, inline comments removed). A blank line ends a value (it is
  not part of it). An indented line with no preceding key in its section is an error.
- Interpolation: `${key}` refers to a key in the same section (including inherited defaults), `${sec:key}` to another
  section. Interpolate recursively after parsing everything. `$$` is a literal `$`. A missing reference, a reference
  cycle, or a lone `$` not followed by `$` or `{` is an error.
- Any other line (no `=`/`:`, not a header) is an error. All errors raise ValueError.
