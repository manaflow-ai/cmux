# Panes and Tabs

```bash
# inspect
cmux pane list --json
cmux tab list --json
cmux terminal list --json

# create
cmux pane pane_… neighbor right --json         # reuse the pane to its right if there is one
cmux pane pane_… split --right -- npm run dev     # new pane runs the command (no empty shell)
cmux pane pane_… split --down --ratio 0.3 --cwd "$PWD"
cmux pane pane_… run --name dev -- npm run dev
cmux pane pane_… run shell 'tail -f logs/dev.log'
cmux tab create terminal --pane pane_… --cwd "$PWD" --name shell
cmux tab create terminal --pane pane_… --name top -- htop   # the new tab runs htop, not a shell
cmux tab create browser --pane pane_… --url https://example.com

# focus and close
cmux pane pane_… focus
cmux pane pane_… focus direction right
cmux tab tab_… focus
cmux tab tab_… close
cmux pane pane_… close

# move
cmux tab tab_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux terminal term_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux pane pane_… swap --other-workspace ws_… --other-screen screen_… --other-pane pane_…
```

Terminal and tab ids stay the same across moves. Split, create, run and move do not change focus; only the `focus` verbs and `pane … split --focus` (MCP `focus: true`) do. To show more output beside a pane that already has a neighbor, add a tab to that neighbor (`tab create terminal --pane …` or `pane … run`) instead of splitting again.

## Sound

```bash
cmux tab mute --target tab_…          # mute a browser tab's page
cmux tab unmute --target tab_…
cmux tab mute-unmute --target tab_…   # the tab speaker's click
cmux tab mute-others --target tab_…   # mute every other tab that plays sound
cmux workspace mute-unmute --target ws_…  # the sidebar row speaker's click
```

Only a loaded browser tab can be muted. MCP offers the same verbs as tools.

An agent chat tab's notifications (not its sound) mute and unmute with `cmux tab toggle-chat-notifications --target tab_…` (MCP `app_tab_toggle_chat_notifications`). Only an agent chat on this Mac can be muted.

## Running a command

`pane <sel> run -- <argv…>` opens a tab running the exact argv, with no shell in between. `run shell '<script>'` runs a shell script. `--on-exit close|keep|shell` decides whether the tab stays after the process exits (`shell` drops it into a new shell). To type into an existing shell instead, use `cmux terminal term_… write --text $'npm test\n'`; the text is literal, so include the newline.

`pane <sel> split -- <argv…>` (or `--shell '<script>'`) makes the new pane run that command instead of a shell. The old `new-split`, `new-pane`, `new-surface`, `list-panels`, `list-pane-surfaces`, `split-off` and `reorder-surface` commands are gone. The app action `cmux workspace new --command "…"` still types a first command into a new workspace.
