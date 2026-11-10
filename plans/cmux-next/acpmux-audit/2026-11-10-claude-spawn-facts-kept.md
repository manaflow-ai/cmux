# Notice to PL-acpmux: a Claude chat's sign-in facts are kept on disk for the adopting daemon (2026-11-10)

Bench round 5, row 10 (owner W5-S). `claude_auth::remember` kept a Claude agent's sign-in facts
only in the memory of the daemon that spawned it, so after `daemon restart` the adopting daemon
(which spawns no agent) showed no `authSource` or `route` for the chat.

`remember` now also writes the same record to `<home>/run/claude-spawn/<session>.json`
(owner-only folder, atomic write). The record holds only what was already kept in memory:
`CLAUDE_CONFIG_DIR`, `HOME`, `ANTHROPIC_BASE_URL`, `SHELL`, the autocompact window, the cloud
provider switches, and for each token key only the word `set` (never its value); plus whether a
route supplied the env and the route's name. `spawned` reads it when this daemon has no record.
`forget` (another harness, and now a purge) removes it. Unit tests write no file (`cfg!(test)`).
Risk to note: an `ANTHROPIC_BASE_URL` with userinfo in it would now also be on disk, owner-only,
as it already was in the daemon's memory and spawn env.
Test: `tests/claude_auth_env.rs` `w5s_an_adopted_claude_chat_keeps_its_auth_source` (also checks
that no kept file holds the token's value).
