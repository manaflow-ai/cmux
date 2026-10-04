# Interaction lifecycle

This document defines the lifecycle states a client sees for an object that a
request creates before the object is ready, and the rule for input sent to it.
It applies to terminals today (R81 stage A); `new-tab` is the first create that
uses it.

## Terminal lifecycle states

| State | Meaning | Input |
| --- | --- | --- |
| `launching` | The create committed its accept. The tab is in the tree and attachable; the host is not adopted yet. | Queued, at most 64 KiB, whole writes only |
| `running` | The host runs the shell. | Written to the PTY |
| `exited` | The shell ended, or the launch failed after the accept (cause `launch-failed: <reason>`). | Dropped |

A terminal leaves `launching` once, and one `terminal-lifecycle` event reports
the transition with its elapsed time (see [events](events.md)). A relaunch, by
`terminal.relaunch` or after a daemon restart, enters `launching` again under
the same terminal id with a new incarnation.

## Input rule

Queue input when the receiver is known not to have started; drop it when its
state is unknown. A launching terminal's shell is known not to have started,
so its input is queued and reaches the PTY before any later input. The queue is
not durable. A reply that says `delivery:"queued"` (or a `terminal.input.write`
receipt) confirms the queue only; a daemon crash loses the bytes, and they never
reached a shell.

A write that does not fit the queue is refused whole with
`terminal.launch_input_budget`, so a paste is never cut in half. Nothing is
dropped silently.

A launch that fails keeps its queued input with the tab. It is never replayed
on its own: `terminal.relaunch` starts a clean shell, and
`terminal.input.send_kept` sends the kept input once through the normal input
path, when the user chooses.

## Incarnations while launching

The host picks the incarnation at bootstrap, so a launching terminal has none.
The create's reply carries `terminal_incarnation:null`. An operation that names
an incarnation is refused while the terminal is launching; an operation that
names none (closing its tab, for example) is accepted. The resource API keeps
the incarnation private; the `terminal-lifecycle` event and `resolve-terminal`
carry it.
