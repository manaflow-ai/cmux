"""Rule modules for the pre-push arch ratchet (scripts/cmux-next/arch-ratchet.py, run by guardrails.py).

arch-ratchet.py loads every `scripts/cmux-next/arch_rules/*.py` whose name does not start with `_`, in
name order, and calls its `check`. It works with no modules (the built-in count and record rules always
run); the layer-gate and app-size slices add theirs here. scripts/install-git-hooks.sh installs this folder
next to the hook's trusted arch-ratchet.py, and prepush-gate's stale-copy warning compares it with
origin/feat-cmux-next's; a missing folder is a warning in the push. A module exports:

    def check(base: str, head: str, changes) -> tuple[list, list]:
        '''(refusals, notes) for the pushed range BASE..HEAD.'''

`base` and `head` are full commit shas: the one range the ratchet counts (arch-ratchet.py's
range_to_count). A push rebased onto origin/feat-cmux-next or merging it in starts where HEAD meets it, so a
change that came in through the merge is in the base and is never the push's own. `changes` carries:

    changes.repo         Path of the repository (a worktree when the hook runs in one)
    changes.files        [(status, path)] that BASE..HEAD changes (`git diff --name-status --no-renames`)
    changes.delta        arch_counts.Delta of the range: .total(row), .by_package(row), .new_sites(row)
    changes.counts       the arch_counts module (ROWS, ROW_IDS, strip(), analyze(), ...)
    changes.allow        {row or rule id: n} from the valid dated exceptions this push adds to
                         plans/cmux-next/arch-ratchet.json (a module's own id is accepted there)
    changes.read(items)  {(rev, path): text or None} for [(rev, path)] in one `git cat-file --batch`
    changes.record(rev)  plans/cmux-next/arch-ratchet.json at REV as a dict, or None (read once per push)
    changes.records()    (record(base), record(head)) through one `git cat-file --batch`

A refusal is `(id, text)` or `(id, text, row)` (a bare text is named by the module's id). ID is the module's
`ID` (layer_gate.py's "layer-gate"), else its file stem. TEXT is printed as is and names the rule, the
file:line, the right pattern and the escape. ROW, when given, is the arch_counts row whose rise the refused change makes (the layer gate's new
edge: its class's row): the count rule then does not refuse that unit of the row again, so one change has
one refusal and one escape. The one escape is the same as the built-in rows': a dated exception for ID in
arch-ratchet.json's `exceptions` ({"date": "YYYY-MM-DD", "row": "<id>", "allow": <n>, "why": "..."}) that
the push adds lets it carry up to n of the module's refusals (the loader applies it; `changes.allow` shows
it to the module). There is no environment-variable skip. A note is a string, printed, never refusing.

Keep a rule fast (it runs in every push): read only `changes.files` and the blobs it needs through
`changes.read`, never run swift or a build.
A rule that raises is reported as a warning and skipped (fail open). The ratchet never runs under
GitHub Actions: these rules add no CI gate.
"""
