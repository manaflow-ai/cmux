# Panes and Surfaces

```bash
# inspect
cmux list-panes
cmux list-pane-surfaces --pane pane:1

# create
cmux new-split right --panel pane:1
cmux new-surface --type terminal --pane pane:1
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
