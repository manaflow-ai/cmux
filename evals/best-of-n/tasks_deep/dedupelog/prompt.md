Fix `dedupelog.py`, the settings store's JSON-lines write-ahead log and its compaction.

Bug report: we restored a store from its segments in the object store, compacted, and a setting we had deleted
weeks ago came back. The bucket listed `seg-10` before `seg-9`, and compaction kept the old write from `seg-9` over
the tombstone in `seg-10`.

Contract: segments may arrive in any order, and nothing in this module may depend on that order except as a
tie-break. For each key, the record that decides it is the one with the highest `seq` anywhere in the log; if two
records for the same key share that highest `seq` (old logs from before seq was centralized have these), the one
that comes later in the log (later segment in the list, or later line in the same segment) decides. A key is unset
when its deciding record is a tombstone. Every reader in the module (`compact`, `replay`, `get`, `next_seq`) answers
from that rule, and `next_seq` is one past the highest `seq` in the log. Lines the module docstring says are ignored
stay ignored everywhere. Keep the public API as it is.
