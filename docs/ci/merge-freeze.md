# Merge freezes

A merge freeze stops pull requests that touch some paths from merging for a few hours. Use it for
a release cut, or while one lane reworks an area that other merges would collide with. For a
pull request's own risk, use [risk tiers](risk-tiers.md) on feat-cmux-next instead.

## Freeze an area

Open an issue in manaflow-ai/cmux, then have an admin or maintainer add the `merge-freeze`
label. A label from anyone else doesn't turn the freeze on. The title is the reason. The body
says what is frozen and until when:

```
paths: cmux-tui/crates/acpmux/ cmux-tui/spec/
expires: 2026-10-20T18:00Z
owner: @lawrencecchen      (optional; the issue's author by default)
branch: feat-cmux-next     (optional; every branch by default)
```

- `paths:` are path prefixes. `cmux-tui/spec/` freezes everything under it, and
  `docs/app.md` freezes that one file. `docs/app` doesn't match `docs/app.md.orig`.
- A freeze lasts at most 72 hours from when the issue was opened, whatever `expires:` says. Open a
  new issue to keep freezing.
- Editing the body after the label went on (to widen `paths:`, say) turns the freeze off until a
  maintainer adds the label again.
- If `paths:` or `expires:` is missing or doesn't parse, the freeze blocks nothing, and the
  checker prints a warning naming the issue. A typo never freezes the repository.

To lift a freeze early, close the issue.

## Let a pull request through

The freeze's owner adds the `freeze-ok` label to the pull request. The timeline records who added
it, and a label added by anyone else doesn't count. `gh-merge-green --override` never lifts a
freeze.

## Where it's enforced

- `scripts/ci/merge_freeze.py check` reads the open freezes and the pull request's label events
  through the GitHub API, so every host sees the same freezes. Exit 1 means frozen, 2 means
  GitHub couldn't be read, and 3 means GitHub's rate limit stopped the read. Both 2 and 3 count
  as frozen wherever a merge happens. `--rate-limit-retry SECONDS` waits and reads once more
  before it gives 3.
- `.github/workflows/merge-freeze.yml` shows a `merge freeze` check on each pull request into
  `main` and `feat-cmux-next`. A read the rate limit refused twice (two minutes apart) shows a
  "merge freeze not checked" warning instead of a red: the rate limit says nothing about the pull
  request, and the merge paths below read the freezes again. Every hour it also closes lapsed
  freeze issues with a comment.
- At merge time, `scripts/gh-merge-green` runs the same check on every base branch and refuses
  on exit 1 (frozen) or any other failure (freeze state unknown). `--override` doesn't lift a
  freeze. The old `--freeze-token` and `--window-token` flags print a warning and are ignored.

`python3 scripts/ci/merge_freeze.py list --repo manaflow-ai/cmux` prints every open freeze and
whether it's active, lapsed or malformed.

## What this replaces

Freezes used to be `FREEZE:` lines in `~/agent-mailbox/WINDOW` on cmux-lawrence, which
gh-merge-green read over ssh. Every token there had lapsed by 2026-10-10, but the tools kept
refusing on them. A host that couldn't ssh to cmux-lawrence, such as Huge Blue, couldn't merge at
all, and nobody else could see the file.
