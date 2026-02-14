# Panes and Surfaces

Split layout, surface creation, focus, move, and reorder.

## Inspect

```bash
cmux list-panes
cmux list-pane-surfaces --pane pane:1
```

## Create Splits/Surfaces

```bash
cmux new-split right --panel pane:1
cmux new-surface --type terminal --pane pane:1
cmux new-surface --type browser --pane pane:1 --url https://example.com
```

## Focus and Close

```bash
cmux focus-pane --pane pane:2
cmux focus-panel --panel surface:7
cmux close-surface --surface surface:7
```

## Move/Reorder Surfaces

```bash
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux move-surface --surface surface:7 --workspace workspace:2 --window window:1 --after surface:4
cmux reorder-surface --surface surface:7 --before surface:3
```

Surface identity is stable across move/reorder operations.
