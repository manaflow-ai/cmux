# Continue an external chat in cmux (experiment)

In Settings → Advanced → Labs, turn on **Show Preview Features**, then reconnect
the cmux MCP server in the external app. Existing `desktop link` connections and
the `new` tool keep their behavior; nothing is connected or started by enabling Labs.

The guest server now offers `handoff`. Give it `capsule`: a self-contained summary
of the goal, decisions, progress and next step. It accepts the same `harness`,
`machine`, `folder`, `name` and `showInCmux` options as `new`, and returns the same
session receipt and cmux link when available. The target cannot read the external
chat's private history. Only the supplied summary travels with the task.

The capsule uses Continue In's shared limit of 65,536 UTF-8 bytes. An empty or
oversized capsule is refused before starting a session; it is never silently cut.
The session retains the external app's guest attribution and `origin` tag and the
existing asking policy on local, paired and Cloud machines.

Turn **Show Preview Features** off to stop handoffs, including calls from a client
that cached the tool list. Reconnect the server to remove it from that list.
Already-started sessions continue normally. This does not disconnect linked apps.

This is the inbound half of Continue In. Opening a chat in another desktop app and
reading that app's private stores are outside this slice. No performance target is
claimed: this adds bounded validation to the existing `new` path.

Regression detector: the `guest_handoff` Rust tests exercise off/on settings,
cached-tool rejection, exact UTF-8 bounds, destination forwarding and asking policy.
