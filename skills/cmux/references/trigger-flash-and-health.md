# Flash

Flash the focused pane for visual confirmation (app action, same as Cmd-Shift-H):

```bash
cmux pane flash-focused
```

It flashes the focused pane only. Per-surface and per-workspace flash targets and `cmux surface-health` were removed; there is no replacement for checking hidden or detached surfaces. `cmux tab list --json` and `cmux terminal list --json` show what the daemon holds.
