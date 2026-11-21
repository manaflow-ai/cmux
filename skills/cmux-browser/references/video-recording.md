# Video Recording

The per-command `cmux browser` CLI has no recording command: automation runs on WKWebView, and the agent-browser recording pipeline is Chrome/CDP-specific. Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

To record a run, use `cmux browser repl` ([Browser REPL](../SKILL.md#browser-repl)): `session.record()` returns a recorder, and its `stop()` writes `trace.jsonl`, a PNG per action and `run.png`, an animated PNG of the run. Neither path records video.

With the per-command CLI, capture evidence for flaky-automation debugging, CI logs, and release-to-release flow diffs with step screenshots and a snapshot timeline instead:

```bash
cmux browser --surface "$SURFACE" screenshot > /tmp/step1.b64
cmux browser --surface "$SURFACE" snapshot --interactive > /tmp/snap-1.txt
cmux --json browser --surface "$SURFACE" click e3 --snapshot-after > /tmp/action-1.json
cmux browser --surface "$SURFACE" screenshot > /tmp/step2.b64
cmux browser --surface "$SURFACE" snapshot --interactive > /tmp/snap-2.txt
```

Capture before and after each mutating action, add `--snapshot-after` on state-changing clicks/fills/types, and group artifacts by timestamp or run id. Use an external screen recorder when full-motion capture is genuinely required.
