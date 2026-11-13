# V2 connection and cursor delivery (PR #42361)

The v2 socket driver owns its outbound queue and partial-write progress. Sources
own their delivery tasks, offer without awaiting capacity, and retain a cursor
when credit stops delivery. A dropped generation frees its queued data and keeps
one bounded notice until written; a reused sid cannot accept an old task's offer.

The first v1 request may negotiate `_acpmux/v2`; the existing line codec preserves
HTTP rejection, size errors, EOF and read-ahead through the handoff. The default
`acpmux.v2` remains empty. Existing v1 components remain enabled.

Evidence is tracked in PR #42361. The release harness is
`cmux-tui/crates/acpmux/tests/v2_connection.rs`: shared small/god fixtures,
Unix streams, a continuously consuming reference reader, process peak RSS,
sequence/row equality, retained bytes, and 1-versus-256 offer timing. The chat
stopped-reader row remains unmeasured until its source exists. No passing release
measurement is claimed by this notice.
