# Keep chats running when the Mac sleeps

Settings › Agents › Agent Sessions: **Keep Chats Running When This Mac Sleeps** (off by default) and
**Move Chats To** (a machine name, or `auto`). When the Mac is about to sleep, the app passes the
system's will-sleep notice to acpmux (`_acpmux/sleep_handoff`), which moves each chat whose turn is
running to that machine with `acpmux session move --interrupt --carry-changes` and continues the
turn there (`cmux-tui/crates/acpmux/src/cli/run/sleep_handoff.rs`). A chat whose uncommitted work
would not all go (a likely secret such as `.env`, a nested repository) stays, before its turn is
touched, and says why.

## The note

One quiet line in the composer notice slot, in the host line's shape (`design/agent-host-line.md`):
muted caption text, an optional action as quiet underlined text, no fill, no color, no motion. It
claims only what acpmux recorded.

- **This Mac's copy** (`movedTo.why == "sleep"`): "Moved to gcp-mini-3 when this Mac went to sleep",
  with **Open** when the chat list has the moved chat. Status tier.
- **The moved chat, turn running** (tag `sleepHandoff=moved`): "Still running on gcp-mini-3 while
  Leo's MacBook Pro sleeps"; seen on that machine itself, "Still running here while …". Status tier.
- **The moved chat, between turns**: "Ran on gcp-mini-3 while Leo's MacBook Pro slept". Hint tier.
- **A chat that stayed** (tag `sleepHandoff=stayed`, kept a day): "Stayed on this Mac when it went
  to sleep: its uncommitted .env (…) can't go with it". Hint tier.

Each state is one row of the same height, so a running note that becomes a ran note moves nothing.
The note is derived from the chat's own summary once per snapshot and kept while it says the same,
so its cost does not grow with the chat list; Open looks the chat up through the list's shared index.

## References

`claude/live/composer-cloud-continuity-banner` (a framed banner that offers Cloud so a chat keeps
working while the Mac sleeps; Leo asked whether cmux needs that banner at all) and
`cmux/live/status-remote-agent-offline-reconnect` (the quiet "The chat catches up once it connects."
tone). So the note is a line, not a banner, and appears only after something moved.

## Gallery

`agent-pane.sleep-handoff`: `moved-picked` (picked), `moved-not-listed-yet`, `still-running-there`,
`ran-there`, `running-seen-there`, `stayed`, and the alternatives `moved-alt-stacked`,
`stayed-alt-stacked` (the reason on a second muted row) and `moved-alt-boxed` (a framed card like the
reference). The stacked version spends a second row on what the first already says; the boxed one is
the banner Leo questioned. The picked line keeps the reason readable and wraps nothing at 720 px.

## Not yet

- A Cloud machine as the target: Cloud moves go through the app's own Move to Cloud
  (`cmux link agent move`), which acpmux does not drive.
- A phone push when the moved turn finishes: the target machine has no push route for the Mac's
  paired phone.
- The move races the sleep: a move the Mac's sleep cuts short finishes after the wake, or gives the
  chat back here and continues it.
