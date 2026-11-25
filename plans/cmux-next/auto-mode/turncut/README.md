# Turn cut probe

`cut.py OUT MODE -- CMD...` starts a headless agent turn and SIGKILLs its process group at a chosen moment
(`text:N` once the streamed reply holds "line N", `after:SECS` after the turn starts, `tool:SECS` after the
first tool call starts). Resume the session by id afterwards and compare the transcript and the side effects.
Results from 2026-11-23 are in [../DESIGN.md](../DESIGN.md#measured-can-a-turn-cut-off-mid-reply-be-retried-2026-11-23).

Run it against a scratch config directory and folder, never a person's sessions.
