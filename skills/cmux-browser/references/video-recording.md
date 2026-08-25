# Video Recording

`cmux browser` exposes no built-in video recording command: automation runs on WKWebView, and the agent-browser recording pipeline is Chrome/CDP-specific. Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

Capture evidence for flaky-automation debugging, CI logs, and release-to-release flow diffs with step screenshots and a snapshot timeline instead:

```bash
cmux browser surface:7 screenshot > /tmp/step1.b64
cmux browser surface:7 snapshot --interactive > /tmp/snap-1.txt
cmux --json browser surface:7 click e3 --snapshot-after > /tmp/action-1.json
cmux browser surface:7 screenshot > /tmp/step2.b64
cmux browser surface:7 snapshot --interactive > /tmp/snap-2.txt
```

Capture before and after each mutating action, add `--snapshot-after` on state-changing clicks/fills/types, and group artifacts by timestamp or run id. Use an external screen recorder when full-motion capture is genuinely required.
