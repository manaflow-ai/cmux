# The GitHub page

The native page a pull request link opens in (`cmux-page://cmux.github/`,
`webviews/src/pages/github`, `CmuxNextGitHubViewer`). It shows one pull request
from the app's shared cache and never loads github.com. Open on GitHub stays one
click away.

## Hierarchy

The page answers three questions in order: what this is, whether it can land,
and what changed and what people said about it.

1. **Header.** Repository and number, with the head commit's short id. The
   title, with the actions on the same line: Merge, View all changes, Open on
   GitHub. Then the state badge, author, branches and age. Then the chips the
   hover card shows: diff totals and file count, a checks tally (a dot and count
   for failing, running and passed), the review decision, conflicts, and labels
   in their GitHub colours.
2. **Merge readiness**, under the header: Ready (with the SHIP that counts) or
   Blocked, then each gate that refuses the merge (see below).
3. **Main column**, what a person reads: the description as rendered Markdown,
   the files changed, then the conversation (comments and reviews with their
   review comments, newest first; filters All, Unresolved and Mine).
4. **Rail**, what a person checks: checks, reviewers, linked issues.

A pane 900px wide or more shows main and rail side by side; a narrower one is a
single column in the same DOM order. The page takes the whole pane less a gutter
of 3% (16 to 24px a side), so a wide pane goes to the description, its tables
and the checks (Leo, 2026-11-07: "it's just giving up way too much space"). The
gallery keeps `width-wide` (94% up to 2200px) and `width-column` (What's New's
84% up to 1560px, the earlier width) as candidates. A table cell breaks a word
only when the word alone is wider than the table can be, so a short column such
as a check table's Status never stacks a letter a line.

The files go in the main column, not the rail, because an opened file shows its
diff inline and needs the width. The gallery keeps the other layouts as
`layout-rail` (files in the rail) and `layout-single` (one column at every
width).

## Merge readiness

The page leads with whether the land would go through, read from the gates our
merge path enforces (`merge_hold.py`, `review_model.py`), mirrored in
`readiness.ts`:

- a SHIP receipt (`Review (<reviewer>): SHIP at <full head>`) at the exact head
  from a model family other than the author's (the body's "Generated with"
  footer), or from a person; a subagent or an unnamed reviewer does not count;
- no BLOCK, FIX, NOT SHIP or HOLD receipt at the head (a later SHIP does not
  clear one);
- no hold label and no `HOLD:` body line;
- no red of its own (a check that also fails at the base's tip is not one);
- nothing still running or queued;
- into `main`, a by-name approval of the head, which the page cannot read, so it
  says it is needed;
- and GitHub's own: not a draft, no conflict.

Each gate is one line; the ones with a detail open in place: a receipt's
findings and a link to it, the failing job's step, log end and link, the hold's
label or line, the review gate's last SHIP and its commit. Merged and closed
pull requests show nothing here. The gallery keeps `ready-blocked-chips` (the
gates as chips) and `ready-blocked-line` (one line) as candidates; the list won
because a drill-down opens under its own gate.

## Checks: the CI dashboard

The checks sit in a band across the page's whole width under the header, so a
person can keep the page open and follow CI as it runs. A long matrix and a log
excerpt need that width. The rail placement is kept in the gallery as `ci-rail`.

- **Summary:** counts of failing, running, queued and passed jobs; "N of M
  done"; an ETA ("about 4 min left") from how long each running or queued job
  took at the base branch's tip; one bar of each state's share.
- **Rows** go failing, running, queued, then passed folded into one line. A
  wide band lays them in two columns. A matrix's shards (`health (0)` …
  `health (7)`) are one row with a pip per shard. A re-run's earlier attempt is
  dropped, so the latest one stands.
- A **failing** row shows the step that failed and the end of its log, up to
  the last error line (24 lines, 4,000 characters at most). A **running** row
  shows how long it has run and how long it usually takes.
- **Re-run failed** reruns the failed jobs of the runs shown failing, with
  `gh run rerun <run> --failed`, on a click the host counts.

Live updates: no push feed of check events reaches the app, so the app keeps
one checks entry per pull request (`GitHubChecksCache`) shared by every page.
It is read again after 20 seconds while a job runs or waits and after 5
minutes once all are done. A shown page asks the app every 10 seconds while a
job runs; that is a call to the app, not to GitHub. A hidden page asks nothing,
and a settled one asks only with its minute refresh. A failed job's step and
log are read once per job id, at most four per checks read.

## Files changed

Each row shows a chevron, the path (folder dimmed), `+N` and `−N` in
right-aligned tabular columns of one width for the whole list, and five cells
(green for added, red for removed, grey when the change is smaller than five
lines). A row is collapsed by default. Clicking it opens that file's diff under
it on the diff viewer's renderer (`@pierre/diffs`), with "Open in diff viewer"
below. The lines are drawn without syntax colours because the page ships no
highlight worker. View all changes opens every file in the diff viewer in one
scroll.

## Merge

Merge goes through GitHub's normal path, never an override. The first click
turns the button into the repository's default method ("Squash and merge") with
Cancel beside it. The second click merges with `gh pr merge <url> --<method>
--match-head-commit <head>`, where the head is the commit the page shows. A push
since then makes GitHub refuse the merge. The button is disabled when GitHub
says the pull request is blocked, behind, conflicting or a draft. The host
spends the person's click, so a script can't merge.

## Reads

The cache's batched read (one GraphQL call for many pull requests) gives the
header, checks and files. The body, conversation, reviewers, linked issues,
label colours, head commit and merge state come from a second GraphQL read
(`pr.details`), with the signed-in login (for Mine) and whether each review
comment's thread is resolved (for Unresolved). The host keeps that read until the pull request's `updatedAt`
moves and runs it at most once a minute, so a page that refreshes every minute
doesn't read every minute. An inline file's patch is cut from the diff the page
already reads for View all changes, so expanding files makes no GitHub call.

## Not yet

- Issues use the same frame minus checks and files. Issue links still open on
  github.com: `GitHubLink` only takes pull requests.
- Writing a comment or a review from the page.
