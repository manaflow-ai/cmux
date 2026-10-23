"""Rule modules for the pre-push arch ratchet (scripts/cmux-next/arch-ratchet.py).

arch-ratchet.py loads every `scripts/cmux-next/arch_rules/*.py` whose name does not start with `_`, in
name order, and calls its `check`. It works with no modules (the built-in count rule always runs); the
layer-gate and app-size slices add theirs here. A module exports:

    def check(base: str, head: str, changes) -> tuple[list, list]:
        '''(refusals, notes) for the pushed range BASE..HEAD.'''

`base` and `head` are full commit shas (base is the range start after the ratchet's own upstream
handling: a rebase onto origin/feat-cmux-next starts at the merge base). When the push merges
origin/feat-cmux-next in, `check` runs once per range (the pushed range and the one from where HEAD meets
origin/feat-cmux-next) and the ratchet keeps only the refusals found in every range, so a change that came
in through the merge is not refused. Refusals are matched by key (see below), and the pushed range's text
is printed. `changes` carries:

    changes.repo         Path of the repository (a worktree when the hook runs in one)
    changes.files        [(status, path)] that BASE..HEAD changes (`git diff --name-status --no-renames`)
    changes.delta        arch_counts.Delta of the range: .total(row), .by_package(row), .new_sites(row)
    changes.counts       the arch_counts module (ROWS, ROW_IDS, strip(), analyze(), ...)
    changes.read(items)  {(rev, path): text or None} for [(rev, path)] in one `git cat-file --batch`
    changes.record(rev)  plans/cmux-next/arch-ratchet.json at REV as a dict, or None (read once per push)
    changes.records()    (record(base), record(head)) through one `git cat-file --batch`

A refusal is `(row_id, text)` or `(row_id, text, key)`: ROW_ID names it in
ARCH_RATCHET_SKIP_REASON="<row>[,<row>]: <why>" (use a row id of arch_counts.ROWS, or the module's own id),
TEXT is printed as is and should name the rule, the file:line, the right pattern and that escape. KEY (a
string or a tuple of strings) identifies what is refused independent of the range, for example
("edge", source, dependency): give one whenever TEXT names something that depends on the base (a layer, a
moved note), so a merge push matches the same refusal over both ranges. Without a key the text is the key.
A note is a string, printed, never refusing.

Keep a rule fast (the whole hook stays under 1 s): read only `changes.files`, never run swift or a build.
A rule that raises is reported as a warning and skipped (fail open). The ratchet never runs under
GitHub Actions: these rules add no CI gate.
"""
