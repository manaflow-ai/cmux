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
2. **Main column**, what a person reads: the description as rendered Markdown,
   the files changed, then the conversation (comments and reviews with their
   review comments, oldest first).
3. **Rail**, what a person checks: checks, reviewers, linked issues.

A pane 900px wide or more shows main and rail side by side; a narrower one is a
single column in the same DOM order. The page's width follows What's New: the
whole pane up to 920px, then 84% of it up to 1560px.

The files go in the main column, not the rail, because an opened file shows its
diff inline and needs the width. The gallery keeps the other layouts as
`layout-rail` (files in the rail) and `layout-single` (one column at every
width).

## Checks

Condensed by default. A thin bar shows each outcome's share (red, yellow,
green). Failing checks are listed first, then running ones. Passed checks fold
into one "Passed N" line that expands. A failing check that also fails on the
base branch says so.

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
(`pr.details`). The host keeps that read until the pull request's `updatedAt`
moves and runs it at most once a minute, so a page that refreshes every minute
doesn't read every minute. An inline file's patch is cut from the diff the page
already reads for View all changes, so expanding files makes no GitHub call.

## Not yet

- Issues use the same frame minus checks and files. Issue links still open on
  github.com: `GitHubLink` only takes pull requests.
- Writing a comment or a review from the page.
