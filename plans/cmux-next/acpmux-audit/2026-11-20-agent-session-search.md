# Session commands under `cmux agent`

`cmux agent` dispatches session verbs through the engine CLI. Existing terminal agent
commands and the app actions for opening workspaces and tabs keep their handlers.

`cmux agent search QUERY` uses the host-wide form of `_acpmux/session_search`. Each
connected peer searches its own prompts and replies, including closed sessions.
The calling daemon merges the newest matches and reports any incomplete hosts.
The existing `session search SESSION QUERY` form still searches a single session.
