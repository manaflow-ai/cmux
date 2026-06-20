# Diff viewer: smarter branch targeting (design spec)

## Problem
In the worktree-per-task workflow (a primary repo spawns one worktree + branch per
task), a user wants to diff "this task's branch vs another branch" but today must ask
an agent to run `cmux diff --base <ref>`. The in-app base picker is a native `<select>`
capped at 4 candidates that often does not contain the branch they want.

## Architecture constraint (today)
The diff viewer pre-renders one static HTML+patch file per (source x repo x base)
combination into `/tmp/cmux-diff-viewer-<uid>/`, served by a local HTTP file server
(plus a custom scheme) with a long-poll `/__cmux_diff_viewer_wait/` hook already used
for deferred/streaming generation. Switching source/repo/base is pure URL navigation
between pre-written files. That is why base options are capped at 4: each one is a fully
materialized page. An uncapped searchable picker therefore needs **on-demand
regeneration**, not a bigger pre-rendered set.

## Goals
1. Pick any branch as the diff base, from the app, with no agent.
2. Searchable (type to filter), uncapped.
3. Smart default base: the right branch is pre-selected for worktree tasks.
4. Clear reason for each suggested base ("fork point", "PR base").

## Proposed flow (v1)
- Replace the base `<select>` with a **`Base: <ref> v` button** in the toolbar. Clicking
  opens a command-palette-style searchable popover.
- Popover layout: search input at top; grouped, fuzzy-filtered results:
  - **Suggested** - heuristic bases, each with a one-word reason tag.
  - **Worktrees** - sibling task branches (`git worktree list`).
  - **Branches** - local heads.
  - **Remotes** - `origin/*`, `upstream/*`.
  - **Recent** - recently checked-out (reflog).
- Type filters across all groups. Enter picks the top hit. Esc closes. Arrow keys move.
- On pick: regenerate the branch diff against that base on demand via a new server
  endpoint, show a brief loading state (reuse the status/poll page), then swap the view.
- Persist last-picked base per (repo, branch) so reopening restores it.

## Smart default base (heuristic order)
When opening branch source with no explicit `--base`, default to the first available of:
1. recorded creation base (`git config branch.<name>.cmuxBase`, written by
   `new-cmux-worktree.sh`) -> exact for cmux-created worktrees.
2. PR base (`gh pr view --json baseRefName`) when a PR exists.
3. `git merge-base --fork-point @{upstream} HEAD` (survives rebases).
4. `origin/HEAD` -> origin/main -> master (today's heuristic).
Label the chosen default with its reason in the Suggested group.

## Server endpoints (diff-viewer-server)
- `GET /__cmux_diff_viewer_refs?repo=<root>` -> JSON: grouped refs (suggested/worktrees/
  local/remote/recent), each `{ ref, label, group, reason? }`. Uncapped.
- `GET /__cmux_diff_viewer_branch?repo=<root>&base=<ref>` -> regenerate the branch diff
  page for that base, write into the secure dir, 302 to the new viewer URL.
Both validate `repo` against the allowed repo set and `base` via `git rev-parse --verify`.

## Entry points (shared action path)
- Command palette action "Diff branch..." opens the viewer in branch mode, picker focused.
- Tab-bar button (optional) same action.
- CLI `cmux diff --compare <a>..<b>` for scripting (v2 wires head side).

## Out of scope for v1 (follow-ups)
- Head-side picker for arbitrary A...B compare (v1 keeps head = HEAD).
- Submodule drill-in (`--submodule=diff`, enumerate `.gitmodules`).

## LOCKED DECISIONS (UX round 1 approved)
- Group order: Suggested, Worktrees, Branches, Remotes, Recent. Collapse empty groups
  (render nothing, no empty header).
- Base-only in v1. Head stays HEAD. `--compare a..b` is the v2 escape hatch.
- Default order: recorded `branch.<name>.cmuxBase` -> PR base -> `merge-base --fork-point`
  -> origin/HEAD/main/master. If cmuxBase and PR base disagree, prefer PR base and keep
  cmuxBase as a second Suggested row.
- Toolbar Base button shows ref AND reason AND ahead/behind, e.g.
  `Base: main (fork point) +12 -3`. Low-confidence fallback gets a `~` prefix on the
  reason and muted tint so a guessed default is visibly different from a confident one.
- Loading: inline spinner on the Base button on pick; toolbar stays put. (v1 navigates
  to the regenerate URL; server regenerates synchronously and 302s to the new page.)
- Raw ref/SHA: if the typed query matches no row but passes `rev-parse --verify`, show a
  synthetic top row "Use <query> (raw)" that Enter selects.
- Row anatomy: primary = ref/branch name (never a SHA), secondary muted right-aligned
  (reason for Suggested, worktree dir for Worktrees, last-commit relative time for
  Branches), `current` pill on HEAD's branch, matched substring bolded while filtering.
- Error states inline in the diff body, each recoverable: ref vanished, regen failed
  (show git stderr first line + Retry), detached HEAD note. Empty diff =
  "No differences against <ref>" (a correct answer, not a broken regen).
- Keep source and repo as native selects in v1; only base becomes a button+popover.
  Make the Base button visually heavier (it is the primary toolbar action).

## FROZEN CONTRACT (backend <-> frontend interface)
Payload gains `branchPicker` (present only when source == branch):
```
branchPicker: {
  repoRoot: string,
  currentRef: string,
  currentReason: string,          // "created from" | "PR base" | "fork point" | "default" | "manual"
  confidence: "high" | "low",     // low => fallback tier; UI muffles + "~" prefix
  aheadBehind: { ahead: number, behind: number } | null,
  refsURL: string,                // GET -> grouped refs JSON (uncapped)
  regenerateURLTemplate: string   // contains literal "{ref}" placeholder, URL-encoded on substitution
}
```
`GET <refsURL>` returns:
```
{ groups: [ { id, label, rows: [ { ref, label, secondary?, reason?, confidence?, current?, worktreeDir? } ] } ] }
```
groups in fixed order suggested|worktrees|branches|remotes|recent; empty groups omitted.
`GET <regenerate>?...&base=<ref>` validates repo in allowed set + base via rev-parse,
regenerates the branch page, 302-redirects to the new viewer URL. On bad base -> 404 page.

## Open questions for UX/product review
1. Group order and whether to collapse empty groups.
2. Show both head + base in v1, or base-only (lower risk)?
3. Default heuristic order above - correct priority?
4. Loading affordance: inline spinner in toolbar vs full status page swap.
5. Keyboard model: Enter = top hit; should typing an exact unknown SHA/ref be allowed?
6. Empty/error states (ref vanished, regeneration failed, detached HEAD).
