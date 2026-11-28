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
symlink modes survive through a scratch placeholder archive. Scratch reconstruction
uses explicit filemode/symlink semantics and allows out-of-cone intent paths without
changing target configuration; `intent_modes_survive_target_configuration_and_sparse_cones`
compares index entries and both diffs with target filemode/symlinks disabled. Payloads stream through tar; no patch occupies a shell variable.
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

Target conflicts are checked for every affected index path, including both sides
of renames, before any patch or intent reconstruction. Machine-consumed patches
explicitly disable rename inference and request short submodule diffs with no
ignored submodule changes; user display preferences cannot drop staged pointers.
`rename_to_intent_never_discards_target_only_staged_content` and
`submodule_patch_format_and_paths_ignore_display_preferences` detect these cases.

A successful `git apply --check` does not guarantee all writes will finish. Before
writing, carry archives the affected regular files and symlinks and records absent
paths; it never recurses into nested directories/submodules. Failure restores that
snapshot, leaving the target index untouched. If restoration itself cannot finish,
the private recovery archive and absent-path list remain and the error names them.
`a_real_partial_write_keeps_recovery_data_and_allows_retry` imposes a real file
size limit on the final apply child, proves the first write occurred, and compares
original files and index bytes after recovery before retrying. A partial file that cannot be distinguished from a concurrent save remains in place with the recovery archive; the test saves those bytes before explicitly resolving its fixture and retrying. The archive's
temporary disk cost is the original affected file bytes plus tar headers, and it
is removed on success or successful recovery.

Publication failure also restores file-to-directory and directory-to-file
transitions. The snapshot records affected directories without recursing into
them; recovery removes only replacement files at those paths before unpacking
the original children. `failed_index_publication_restores_the_worktree` checks
both directions, renamed files and symlinks, then retries the carry.

Recovery paths include ancestors as raw NUL-separated names, deduplicated and
ordered deepest first. This records intermediate directories absent before an
apply, so rollback can remove them when empty before restoring a file at their
parent. Index conflict checks still cover only affected paths, preserving
unrelated target staging. Both the real partial-write and publication-failure
regressions include multi-level file-to-directory replacements.

Backup and rollback never traverse symlink ancestors. Descendants of a new
symlink are skipped while its own recorded path is restored or removed; archive
extraction refuses if an original file still has a symlink ancestor.
`failed_apply_never_recovers_through_new_symlink_ancestors` carries a staged
child plus a final symlink into an unrelated directory, forces both a real write
failure and publication failure, and proves the outside target-only file remains
unchanged before retrying.

Directory recovery first removes all replacement files and symlinks, then
recreates original directories and their parents. Combining these passes would
try to recreate descendants beneath a parent still replaced by a file. The
publication and real partial-write tests cover nested directory-to-file as well
as nested file-to-directory transitions.

The target conflict guard checks both visible and invisible intent-to-add index
views, including an intent replacement of a committed empty blob. The intent
conflict matrix compares target index bytes before and after that refusal.
Replaying an applied carry also refuses when intent flags are the only change;
the independent snapshot matrix verifies that retry preserves target index bytes,
refs, both diffs and file contents, including an empty tracked intent replacement.
Recovery archives non-recursive directory headers as well as file contents, so
restoring a directory cannot widen its permissions under the destination umask.
Both real-write and publication-failure regressions restore nested directory
modes 0700, 0710 and 0750 while the apply runs under umask 002.

An absent path is not evidence that carry created whatever appears there later.
Recovery removes a newly appeared file only when it matches the expected final
worktree entry; otherwise it preserves the path, retains the recovery archive,
and reports the conflict. `recovery_preserves_target_files_saved_after_the_backup`
saves target-only bytes before apply and after apply/before failed publication,
and verifies they survive with the original target index. Retry requires explicit
resolution of that conflict. A partial new file whose contents cannot be identified
also requires recovery rather than being silently removed.

Before index publication, a reverse applicability check verifies worktree writes
(including deletions): Git may warn about an unlink failure but return success.
`an_unlink_warning_cannot_publish_a_deletion_that_did_not_happen` exercises a real
read-only parent directory. Unstaged submodule changes refuse with guidance because
a superproject patch cannot reproduce the submodule checkout; the submodule
regression verifies refusal, source preservation, and staged-pointer transport
with display preferences that hide submodule changes.

Before any rollback mutation, every existing affected file or symlink must match
either its raw archived original or the expected carry blob. Filtered Git diffs
are insufficient: a clean filter can hide distinct saved bytes. An ambiguous
tracked file or directory replacement leaves the entire target worktree untouched
and reports the original archive, just like an ambiguous newly appeared file.
`recovery_preserves_target_files_saved_after_the_backup` covers both existing and
new files at both race points. Rollback extraction uses temporary disk for a second
copy of the affected originals, only on failure; inability to extract retains the
archive and reports recovery rather than guessing.

An initialized target submodule must already be at the carried candidate commit.
Carry never changes a nested checkout or reports a staged-pointer carry as success
while leaving that checkout at another commit. The submodule regression covers
refusal with target index/checkout preservation, then explicit checkout and retry.

Rollback preserves extended attributes and ACLs in the recovery archive. It
selects only original files whose bytes, type or executable mode need restoring,
and extracts directory headers without recursively selecting untouched children.
An unchanged staged-only target file retains its inode and annotations.
`rollback_preserves_annotations_and_leaves_untouched_inodes_alone` checks a nested
untouched inode and xattrs on both untouched and restored files, with failures
before writes and after writes/before publication. Unsupported archive metadata
options fail before worktree mutation.

Explicit carry always reads the snapshot after freezing and pushing, even when
Git display status says clean. A hidden-only submodule modification with
`submodule.module.ignore=all` must reach the forced raw-diff refusal, as covered
by `submodule_patch_format_and_paths_ignore_display_preferences`.
