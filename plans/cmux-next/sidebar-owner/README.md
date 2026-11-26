# Sidebar owner log: one file per entry

A visual sidebar change (a commit whose `Sidebar-Look:` trailer is not `no visual change`) adds its entry here as a
new file, in the same commit. The pre-push gate's "Sidebar look owner" check
(`scripts/cmux-next/prepush-gate.py`, `SIDEBAR_ENTRIES`) accepts a file added or edited here.

Why a directory: the single note, [`../sidebar-owner.md`](../sidebar-owner.md), took every entry at its top, so
any two open sidebar PRs conflicted on GitHub (47 of the 96 PRs that edited it in the 14 days to 2026-11-25,
`scripts/ci/conflict_hotspots.py`). Two new files never conflict. That note is frozen: its target look, design
sections and older entries stay there and can be corrected in place, but a PR that grows it fails the fast
gates' "entry logs" check (`scripts/ci/entry_logs.py`).

- Name: `YYYY-MM-DD-<short-slug>.md`, for example `2026-11-25-trailing-cloud-ink.md`. The slug is your lane or
  the look; a name that is taken means pick another, never append to someone else's file.
- Content: the entry as it was written in the note, one paragraph:
  `- 2026-11-25 (lane/NAME, ask-ID): Sidebar-Look: <who>, <date>: "<their words>". <what changed and where>`.
- Logging a commit that reached the branch without the record (the CI sweep names it): put its 11-character sha
  in a new entry file here; the sweep reads every file in this directory.
- To read the log newest first: `ls -r plans/cmux-next/sidebar-owner/`, or `cat plans/cmux-next/sidebar-owner/2*.md`.
