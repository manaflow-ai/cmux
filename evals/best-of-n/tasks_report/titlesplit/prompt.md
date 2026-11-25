# Sidebar tab names show the agent's spinner, and the tree is re-announced many times a second

Agent CLIs (Claude Code, Codex) put a status glyph in front of their terminal title: a braille spinner frame while
working (`⠐ Fix the login bug`, then `⠂ Fix the login bug`, ...), `✳` or `●` when idle, `✔` when done, `✘` when it
failed. `titlesplit.py` handles a title a terminal sets (`store`, which returns the raw title to store and what to
announce to subscribers, or None) and what the sidebar shows for a tab (`shown_title`).

Today every spinner frame is stored and announced as a brand-new title, so the tree is re-announced several times a
second while an agent works, and the sidebar shows the spinner glyph as part of the tab's name.

What I'd expect: `split_title(raw)` gives `(text, activity)`, the title without its status glyph and the activity it
stood for (`"working"`, `"idle"`, `"done"`, `"failed"`, or None when there is no glyph; the module already lists the
glyphs). A new raw title is still stored, but it is announced (as its split) only when the text or the activity
changed. The sidebar shows the split for terminal tabs (kind `"pty"` or `"remote-pty"`); a browser tab's title is a web
page's and is shown as it is (`● Slack | general` keeps its dot). A newer daemon sends `title_text` and
`title_activity` with the tab, already split: show those when they are there.
