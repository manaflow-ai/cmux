# Panes and Tabs

```bash
# inspect
cmux pane list --json
cmux tab list --json
cmux terminal list --json

# create
cmux pane pane_… split --right
cmux pane pane_… split --down --ratio 0.3 --cwd "$PWD"
cmux pane pane_… run --name dev -- npm run dev
cmux pane pane_… run shell 'tail -f logs/dev.log'
cmux tab create terminal --pane pane_… --cwd "$PWD" --name shell
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

Terminal and tab ids stay the same across moves. Split, create, run and move do not change focus; only the `focus` verbs do.

## Sound

```bash
cmux tab mute --target tab_…          # mute a browser tab's page
cmux tab unmute --target tab_…
cmux tab mute-unmute --target tab_…   # the tab speaker's click
cmux tab mute-others --target tab_…   # mute every other tab that plays sound
cmux workspace mute-unmute --target ws_…  # the sidebar row speaker's click
```

Only a loaded browser tab can be muted. MCP offers the same verbs as tools.

## Running a command

`pane <sel> run -- <argv…>` opens a tab running the exact argv, with no shell in between. `run shell '<script>'` runs a shell script. `--on-exit close|keep` decides whether the tab stays after the process exits. To type into an existing shell instead, use `cmux terminal term_… write --text $'npm test\n'`; the text is literal, so include the newline.

The old `--command` flag on `new-split`, `new-pane` and `new-surface`, and `split-off`/`reorder-surface`, are gone. The app action `cmux workspace new --command "…"` still types a first command into a new workspace.
