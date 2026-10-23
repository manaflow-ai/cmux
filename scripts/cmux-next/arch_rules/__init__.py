"""Rule modules for the pre-push arch ratchet (scripts/cmux-next/arch-ratchet.py).

arch-ratchet.py loads every `scripts/cmux-next/arch_rules/*.py` whose name does not start with `_`, in
name order, and calls its `check`. It works with no modules (the built-in count rule always runs); the
layer-gate and app-size slices add theirs here. A module exports:

    def check(base: str, head: str, changes) -> tuple[list, list]:
        '''(refusals, notes) for the pushed range BASE..HEAD.'''

`base` and `head` are full commit shas (base is the range start after the ratchet's own upstream
handling: a rebase onto origin/feat-cmux-next starts at the merge base). When the push merges
origin/feat-cmux-next in, `check` runs once per range (the pushed range and the one from where HEAD meets
origin/feat-cmux-next) and the ratchet keeps only the refusals (equal tuples) found in every range, so a
change that came in through the merge is not refused. `changes` carries:

    changes.repo         Path of the repository (a worktree when the hook runs in one)
    changes.files        [(status, path)] that BASE..HEAD changes (`git diff --name-status --no-renames`)
    changes.delta        arch_counts.Delta of the range: .total(row), .by_package(row), .new_sites(row)
    changes.counts       the arch_counts module (ROWS, ROW_IDS, strip(), analyze(), ...)
    changes.read(items)  {(rev, path): text or None} for [(rev, path)] in one `git cat-file --batch`
    changes.record(rev)  plans/cmux-next/arch-ratchet.json at REV as a dict, or None

A refusal is `(row_id, text)`: ROW_ID names it in ARCH_RATCHET_SKIP_REASON="<row>[,<row>]: <why>" (use a
row id of arch_counts.ROWS, or the module's own id), TEXT is printed as is and should name the rule, the
file:line, the right pattern and that escape. A note is a string, printed, never refusing.

Keep a rule fast (the whole hook stays under 1 s): read only `changes.files`, never run swift or a build.
A rule that raises is reported as a warning and skipped (fail open). The ratchet never runs under
GitHub Actions: these rules add no CI gate.
"""
