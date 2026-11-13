# Worktree setup: a new worktree chat's setup line, and the recipe in Settings

When New Worktree makes a worktree for a chat, the session host runs the project's worktree recipe
after its reply: it copies the `.worktreeinclude` files from the main checkout, then runs the setup
script in the worktree with `CMUX_ROOT_PATH`, `CMUX_WORKSPACE_PATH`, `CMUX_WORKSPACE_NAME` and
`CMUX_PORT`. The recipe comes from the repository (`.worktreeinclude`, `.cmux/worktree.toml`) and
from the project's saved recipe (`project.update` field `worktree`). Two surfaces show it:

- The agent pane's setup line, above the composer (`webviews/src/agent-session/acpmux/worktreeSetup.tsx`,
  its stylesheet `worktreeSetup.css`, gallery `agent-pane.worktree-setup`).
- Settings > Agents > Worktree Setup (`webviews/src/pages/settings/components/WorktreeSetupCard.tsx`,
  gallery `pages.settings` variants `worktree-setup` and `worktree-setup-edited`).

Shared types and wire readers: `webviews/src/worktreeRecipe.ts` (`WorktreeRecipe`,
`ResolvedWorktreeRecipe`, `WorktreeSetupRun`).

## References

- `claude/live/status-cloud-session-setup-steps` and `cmux/live/cloud-session-initializing-steps`:
  the setup as a short checklist, one icon column, a step's time after its name.
- `cmux/live/cloud-startup-progress-labels-overlap`: the bug to avoid. State words for screen
  readers live inside the mark, clipped to nothing; they never draw over a step's name.
- `codex/web/worktree-created-running`: a worktree's progress as one quiet line in the chat, not a modal.
- `claude/live/settings-setup-script-subpage` and `claude/web/web-environment-settings`: a script is
  a code box with one sentence under it that says when it runs.
- `codex/live/cloud-environment-setup-scripts-and-access`: what not to do. Every field explains
  itself in plain words; no unexplained environment concept.

## Setup line (agent pane)

- One notice row above the composer (`acpmux-switch-notice`: its inset, muted ink, 16 px line). It is
  the row "Creating worktree…" already draws in: the setup states replace its words in place, so
  the composer does not move when the worktree lands and the setup starts.
- Row: the mark (16 px column: spinner, check, or the failure glyph), the state's words in primary
  ink (danger ink on failure), then the facts in muted ink: the time (Cloud start's format: `<1s`,
  `4.1s`, `1m 12s`), `exit N` on a failure, `Port N`. Then Output, and Dismiss once the setup ended.
- Output opens a drawer under the row: the Cloud start's checklist rows (Copy files with how many
  were copied; Run setup script with its time) and the output in a mono box, at most 160 px tall,
  pinned to its end while the person has not scrolled up. The drawer opens from no height to its
  own (grid rows 0fr to 1fr, `--cmux-motion-standard`), so the composer moves with it in one motion;
  reduced motion keeps only the crossfade.
- A failure (failed, timed out, stopped) opens the drawer once by itself, like a failed Cloud start.
- Reading: `git.worktree.setup` at once, then every second (page clock: none while the page is
  hidden) with `since` = the last `output_end`. Stops at a final state, at the first failed read
  (the line keeps what it knew), and after 31 minutes (the host ends every setup at 30). Output kept
  is capped at the host's 64 KiB.
- The line belongs to the chat whose folder is the worktree. Dismiss forgets it; leaving a chat whose
  setup ended forgets it too. Setup never blocks the chat: it opens and sends as soon as the worktree
  exists.

| State | Start | End |
| --- | --- | --- |
| Creating | spinner, `Creating worktree…` | the same row says the setup's first state |
| copying | spinner, `Copying files into the worktree…` | running, or the recipe's end when it has no script |
| running | spinner, `Running setup script…`, time ticking, port | check or failure glyph, time stops |
| succeeded | check, `Setup script finished` (or `Worktree files copied`), time, port, Output, Dismiss | gone on Dismiss |
| failed / timed_out / interrupted | failure glyph and words in danger ink, `exit N`, drawer open | gone on Dismiss |
| Output | drawer at 0 height | drawer at its height; the composer below moves with it |

## Variants

Built in `worktreeSetup.gallery.tsx` over the same states:

1. `line` (ships): the notice row with the Cloud start's rows under Output. It keeps the row the
   person already saw for Creating, costs one line above the composer, and shows the detail only
   when asked or on failure.
2. `look-card`: the Cloud start's bordered card with its rows always open. Clear, but three rows of
   chrome over the composer for something that usually succeeds.
3. `look-tail`: the line plus the output's last line always shown. Busy while the script prints,
   and a wrapping line moves the composer.

## Worktree Setup card (Settings > Agents)

- Card title, then one help sentence that names the four variables.
- A Project row (the session host's projects; the path under the name in mono).
- Setup script, Run script, Teardown script: each a 2-row mono code box with its purpose above
  and what the repository says under it (`Repository: <first line>` or `The repository sets none.`).
  An empty box uses the repository's; text replaces it (`Replaces the repository's.`); an emptied
  box turns it off (`Off: the repository's does not run.`). Use Repository's (small button in the
  same 24 px line, so nothing moves) returns to the repository's.
- Files to copy: one pattern per line, added after the repository's lines, which show under it.
- Footer, right-aligned: the repository files read, Clear Saved (when a saved recipe exists),
  Revert, Save (solid). Save and Revert are off until something changed.
- Switching projects changes only values, never which fields show.
- Settings reaches the session host through the native `cmux.settings.worktree.` route (`list`, `read`, and `save` on your click), on the app's own connection: the session host refuses project and git operations from a page. A build without that route says so in one line instead of the form.
