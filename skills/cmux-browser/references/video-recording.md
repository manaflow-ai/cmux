# Video Recording

Removed. The new CLI has no browser recording, trace or screencast. For a still
image use `cmux browser "$TAB" screenshot --out page.png` ([commands.md](commands.md)). Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

To keep evidence of a run, save snapshots and page state around each action:

```bash
cmux browser "$TAB" snapshot --interactive > snap-1.txt
cmux browser "$TAB" click e3
cmux --json browser "$TAB" state > state-2.json
cmux browser "$TAB" snapshot --interactive > snap-2.txt
```

Use an external screen recorder for full-motion capture.
