# Session carry preserves two Git snapshots

`session move --carry-changes` must preserve HEAD, the index and the working tree
independently. A HEAD-to-worktree diff cannot prove staging survived: staging can
be partially undone, or completely canceled, in the working tree.

The carry reader copies the source index and emits two base-relative binary
patches: HEAD to index, and HEAD to final working tree. Apply prepares a candidate index under the target index lock, including
intent-to-add flags, and publishes it only after the final working-tree patch
applies. A failed worktree apply leaves the original index byte-for-byte intact.
Unmerged source indexes refuse with recovery guidance instead of losing conflict
stages. Intent flags come from the index flags rather than differences between
name lists: a path can already be in HEAD, with identical empty content. Only paths changed in the visible or invisible intent index views send debug
metadata, so unchanged tracked paths do not grow the transfer. Unknown
index debug formats refuse instead of silently losing flags. Raw path bytes and
symlink modes survive through a scratch placeholder archive. Payloads stream through tar; no patch occupies a shell variable.
File counts are the union of both patches' raw paths; byte counts include both and the intent-to-add path list.
Secrets, ignored files and nested repositories retain their existing exclusions.

Detector: `session_move_carry::tests::index_and_worktree_snapshots_match_independently_for_every_change_kind`
compares Git index entries, staged and unstaged diffs, filesystem bytes and source
refs independently. It covers canceling edits, staged binary edits, renames,
additions followed by deletion, intent-to-add (including tracked replacements, symlinks, deleted and empty files),
and unusual untracked paths. The companion
failure tests cover preflight refusal, failure after candidate index preparation, retry, and
changed target HEAD (including during payload receipt) and existing target index locks.
Intent-only carries explicitly compare the affected target index entries with the
base under the lock before replacing flags; empty patches cannot bypass conflict
detection. `intent_only_changes_never_overwrite_target_staging` guards target-only
staged content and deletions; unrelated target staging remains intact.
`index_flag_transfer_excludes_unchanged_files` bounds the transferred metadata. The ignored
`carry_transport_before_after` test records the old shell-base64 transport and
streamed tar transport timings for the same 16 MiB payload. Run through `cmux-ci test --setup rust -- bash -c
'cd cmux-tui && cargo test -p acpmux --lib session_move_carry'`.

All explicit session carry routes (local to peer, peer to peer through `--from`,
and peer to local) use this reader and apply script. Automatic resume moves keep
carry disabled. GUI Cloud Move and Bring Back instead use the cloud move core's
`link seed push`, `link seed pull --or-copy`, and `link agent move` calls; those
separate seed/sync paths are not changed or runtime-verified here.

A passing script regression does not prove a real session moved. Runtime
acceptance separately needs a built driver at the reviewed SHA, an owned source
session and target, a successful move and reply, and index/worktree readback.
