# Panes and Surfaces

```bash
# inspect
cmux list-panes
cmux list-pane-surfaces --pane pane:1

# create
cmux new-split right --panel pane:1
cmux new-split down --command "npm run dev"
cmux new-pane --type terminal --direction right --command "tail -f logs/dev.log"
cmux new-surface --type terminal --pane pane:1
cmux new-surface --type terminal --pane pane:1 --working-directory "$PWD" --command "npm test"
cmux new-surface --type browser --pane pane:1 --url https://example.com

# focus and close
cmux focus-pane --pane pane:2
cmux focus-panel --panel surface:7
cmux close-surface --surface surface:7

# move and reorder
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux move-surface --surface surface:7 --workspace workspace:2 --window window:1 --after surface:4
cmux split-off --surface surface:7 right
cmux reorder-surface --surface surface:7 --before surface:3
```

Surface identity is stable across move, reorder, and split-off. Layout commands are focus-neutral by default; pass `--focus true` only when the moved or created surface should be selected.

## Initial command

`--command <text>` on `new-split`, `new-pane`, `new-surface`, and `new-workspace` starts the new terminal's regular interactive shell and types the text plus one Enter into it at spawn time. Use it instead of create-then-`send`-then-`send-key enter` whenever the first command is known.

- The text is delivered literally; quoting, `&&`, pipes, and `$VARS` are interpreted by the new shell. `--command=<text>` also works, and a value is required.
- The shell stays alive after the command exits. This differs from the socket `initial_command` param, which replaces the shell with a one-shot process.
- Terminal-only: combining it with `--type browser`, `simulator`, or `agent-session` is an error. Blank or whitespace-only text is ignored. `new-workspace --layout` ignores it; layout surfaces define their own commands.
- Remote tmux mirrored workspaces reject it, so the request fails instead of silently dropping the command.
- Socket: the same behavior is the `initial_input` param on `surface.split`, `pane.create`, `surface.create`, and `workspace.create`. It is delivered raw, so append the Enter keystroke (`\r`) yourself.
