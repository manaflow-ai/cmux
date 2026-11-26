# Trigger Flash and Surface Health

Flash a surface or workspace for visual confirmation in the UI:

```bash
cmux trigger-flash --surface surface:7
cmux trigger-flash --workspace workspace:2
```

Detect hidden, detached, or non-windowed surfaces before routing focused input when UI state may be stale:

```bash
cmux surface-health
cmux surface-health --workspace workspace:2
```
