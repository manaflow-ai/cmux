# Notice to PL-acpmux: a chat record that does not read blocks only the purge of a chat it may name (2026-11-10)

Bench round 5, row 11b (owner W5-S). `store/fork_view.rs` `forks_of` (used by delete, purge,
`release_history` and compaction) refused when any chat record the store could not read was
left: "chat X's metadata does not read, and it may be a fork of Y". One old unreadable record
on the shared daemon blocked the purge of every chat (7 of 7 in the bench).

Now the refusal stays only for a record that may name Y as its chat: its bytes hold Y's id as
text, or it reads as JSON whose `historyFrom` names Y or has no readable `session`, or the store
cannot read its bytes at all (new `Store::may_name`, true by default; `LocalStore` reads the
bytes; `JournalStore` and `ForkView` forward). A record that cannot name Y is no fork of Y: it is
skipped with a warning in the daemon log and kept as it is. The history guard of #37020 is
unchanged for a real fork: a fork's record always holds its chat's id in `historyFrom.session`.
Test: `tests/purge_unreadable_record.rs`.
