# Video Recording

Removed. The new CLI has no browser recording, trace, screencast or scripted
screenshot command. Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

To keep evidence of a run, save snapshots and page state around each action:

```bash
cmux browser "$TAB" snapshot --interactive > snap-1.txt
cmux browser "$TAB" click e3
cmux --json browser "$TAB" state > state-2.json
cmux browser "$TAB" snapshot --interactive > snap-2.txt
```

The UI action `cmux browser screenshot-page` captures the focused browser
through the app's own screenshot flow; it does not write to a path you choose.
Use an external screen recorder for full-motion capture.
