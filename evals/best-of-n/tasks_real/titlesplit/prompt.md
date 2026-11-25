Fix `titlesplit.py`. Terminal programs set the tab title, and agent CLIs put a status glyph in front of it (a braille
spinner while working, `✳` when idle, `✔` when done). cmux shows the text and the activity apart.

Bug report (from cmux commit f5ae561db9e, "split agent activity glyphs out of terminal titles"): the daemon stored and
announced the raw title. Every spinner frame (`⠐ Fix it`, then `⠂ Fix it`, ...) was a new title, so the tree was
re-announced many times a second, and the sidebar showed the spinner glyph as part of the name.

Implement these three functions (the module has stubs or the old behavior):

`split_title(raw: str) -> tuple[str, str | None]` returns `(text, activity)` for a terminal title:
- Activity glyphs, by code point:
  - `"working"`: U+2801 to U+28FF (braille, not U+2800), U+25D0 to U+25D3, U+25F4 to U+25F7, U+2596 to U+259F.
  - `"idle"`: U+2733, U+2736, U+273B, U+273D, U+2722, U+00B7, U+25CF, U+25CB, U+25C9, U+23FA.
  - `"done"`: U+2713, U+2714, U+2705.
  - `"failed"`: U+2717, U+2718, U+274C.
- Leading whitespace is skipped first. Then, while the next character is an activity glyph: take it (the activity is
  that glyph's; a later glyph replaces an earlier one), skip any variation selectors right after it (U+180B to U+180D,
  U+180F, U+FE00 to U+FE0F, U+E0100 to U+E01EF), then skip whitespace.
- `text` is what remains, trimmed of whitespace at both ends. If that is empty, `text` is the whole raw title trimmed
  (a title that is only a glyph keeps the glyph as its text, with its activity). A glyph that is not leading is plain
  text. A title with no leading glyph has activity None. `""` gives `("", None)`.

`store(stored: str | None, title: str) -> tuple[str, tuple[str, str | None] | None]` handles a title the terminal
just set, given the raw title stored before (None at first). It returns the raw title to store now and what to
announce: if `title` equals `stored`, nothing changes, return `(stored, None)`. Otherwise the new raw title is stored,
and it is announced as `split_title(title)` only when that pair differs from `split_title(stored)` (with
`split_title` of None being `("", None)`); else the announcement is None. So spinner frames of one text are stored
but not re-announced.

`shown_title(tab: dict) -> tuple[str, str | None]` is what the sidebar shows for a tab dict with `kind`, `title`, and
maybe `title_text` and `title_activity` (from a newer daemon):
- If `title_text` is a str, show it, with `title_activity` as the activity when that is one of `"working"`, `"idle"`,
  `"done"`, `"failed"`, else None.
- Otherwise, for a terminal tab (`kind` is `"pty"` or `"remote-pty"`) show `split_title(title)`; any other kind (a
  browser page, ...) shows `(title, None)`, as is: a page title like `● Slack | general` keeps its dot. A missing
  `title` is `""`.
