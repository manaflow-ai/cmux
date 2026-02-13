# Panes and Surfaces

Split layout, surface creation, focus, move, and reorder.

## Inspect

```bash
cmuxterm list-panes
cmuxterm list-pane-surfaces --pane pane:1
```

## Create Splits/Surfaces

```bash
cmuxterm new-split right --panel pane:1
cmuxterm new-surface --type terminal --pane pane:1
cmuxterm new-surface --type browser --pane pane:1 --url https://example.com
```

## Focus and Close

```bash
cmuxterm focus-pane --pane pane:2
cmuxterm focus-panel --panel surface:7
cmuxterm close-surface --surface surface:7
```

## Move/Reorder Surfaces

```bash
cmuxterm move-surface --surface surface:7 --pane pane:2 --focus true
cmuxterm move-surface --surface surface:7 --workspace workspace:2 --window window:1 --after surface:4
cmuxterm reorder-surface --surface surface:7 --before surface:3
```

Surface identity is stable across move/reorder operations.
