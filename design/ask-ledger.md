# Your asks: local Labs experiment

Specification: private `manaflow-ai/cmuxterm-hq/docs/rfd/0010-ask-ledger.md`.

Settings > Advanced > Labs > Your Asks is off by default. The daemon reads
`labs.askLedger` at startup; the Settings help says a restart is required.
Agents cannot enable this recording setting. A fresh disabled installation creates
no ledger or writer and records no asks or PRs. Previously recorded data stays
hidden; deleting its chat still removes its asks while the experiment is off.

History probes the local daemon once on mount. Only an explicit `enabled: true`
reply reveals Your asks; an older daemon, error, or disabled reply leaves History
unchanged. The view uses History's existing title and tabs, compact rows, session
and PR chips, and no entry animation. Loaded, empty, error and older-daemon gallery
states are in `agent-pane.your-asks`, at 380, 720 and 960 pixels.

Capture accepts only daemon-marked human messages, masks credentials before
truncation to 1,000 characters, and persists owner-only local JSONL. Remote and
peer RPC origins cannot read or attach links. The local `_acpmux/asks_link_pr`
endpoint accepts a PR URL/body/state. Observed successful `gh pr create` calls
can link literal inline bodies; body files and substitutions require an explicit
link call. No network polling, matching, routing, historical import or cloud sync
is part of this slice. The view shows the newest 200 asks; the API also supplies
`next` and `nextId`, sent back as `before` and `beforeId` for lossless pagination.

Regression classes and detectors: same-millisecond pagination
(`equal_time_pages_keep_every_ask`), removed trace attribution
(`an_explicit_empty_body_unlinks_but_a_state_only_note_preserves_links`),
command-wide false attribution (`ask_traces_are_only_from_the_literal_inline_body`),
and mixed PR outcomes (`a_mixed_merge_and_close_keeps_each_targets_state`).
The opt-in and deletion tests prevent an off experiment from recording new data
or retaining a deleted chat after it is re-enabled.

Capture fixtures must opt in explicitly without machine settings, and secret
fixtures must satisfy the shared scanner's entropy rules. The detectors are
`the_hubs_append_path_records_the_persons_prompts_only` and
`capture_masks_credentials_before_truncating`; the latter also crosses the
1,000-character boundary with multibyte text to detect truncation before masking.

Recovery publishes state and starts persistence only after the whole file was read
and any torn EOF tail was successfully cut. I/O errors preserve the original file;
no writer may compact an incomplete replay. The detectors are
`a_read_error_preserves_the_unread_suffix_and_discards_partial_state` and
`an_unreadable_store_never_starts_a_writer`; the restart test retains torn-tail coverage.

Chat deletion waits up to five seconds for the Ask writer to sync a replacement file
and its directory, or a fallback purge tombstone. Recovery and write failures reject
deletion. Memory-only and fresh disabled ledgers need no writer. After a queued purge
fails or times out, its asks stay hidden and capture stays fenced until retry or a
new chat explicitly reopens that id: late disk completion cannot resurrect data.
An append error rolls back to the previous file length and stops the writer; if the
rollback also fails, restart recovery repairs the tail before accepting more writes.
The detectors are `failed_ask_recovery_rejects_chat_deletion_before_stopping_it`,
`failed_recovery_rejects_purge_even_when_the_experiment_is_off`,
`a_disk_error_stops_the_writer_and_rejects_later_purges`,
`a_timed_out_purge_keeps_its_fence_when_the_writer_finishes_late`, and
`a_partial_append_rolls_back_before_another_writer_can_append`.
