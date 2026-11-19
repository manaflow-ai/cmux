# Session carry preserves two Git snapshots

`session move --carry-changes` must preserve HEAD, the index and the working tree
independently. A HEAD-to-worktree diff cannot prove staging survived: staging can
be partially undone, or completely canceled, in the working tree.

The carry reader copies the source index and emits two base-relative binary
patches: HEAD to index, and HEAD to final working tree. Apply checks both patches
before writing, applies the first only to the index and the second only to the
working tree, and reverses the index patch if the working-tree write fails.
File counts are the union of both patches' raw paths; byte counts include both.
Secrets, ignored files and nested repositories retain their existing exclusions.

Detector: `session_move_carry::tests::index_and_worktree_snapshots_match_independently_for_every_change_kind`
compares Git index entries, staged and unstaged diffs, filesystem bytes and source
refs independently. It covers canceling edits, staged binary edits, renames,
additions followed by deletion, and unusual untracked paths. The companion
failure tests cover preflight refusal, rollback after index apply, retry, and
changed target HEAD. Run through `cmux-ci test --setup rust -- bash -c
'cd cmux-tui && cargo test -p acpmux --lib session_move_carry'`.

All explicit session carry routes (local to peer, peer to peer through `--from`,
and peer to local) use this reader and apply script. Automatic resume moves keep
carry disabled. GUI Cloud Move and Bring Back instead use the cloud move core's
`link seed push`, `link seed pull --or-copy`, and `link agent move` calls; those
separate seed/sync paths are not changed or runtime-verified here.

A passing script regression does not prove a real session moved. Runtime
acceptance separately needs a built driver at the reviewed SHA, an owned source
session and target, a successful move and reply, and index/worktree readback.
