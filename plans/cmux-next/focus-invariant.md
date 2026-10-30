# The focus invariant: something always takes the keys

Status: binding (felt 1f, Lawrence 2026-10-29: "at any point in time (with some very minor exceptions?),
something should always be focused, so that keyboard only operation is possible"). Owner: the focus agent of
felt 1f. Checker: `InputInvariantMonitor` (W10, W11, with W1 and W5 of [input-spec.md](input-spec.md)). Fuzz: the
journeys group `ext_focus.py` (`focus-fuzz`, `focus-new-browser-tab`) on branch `cp/journeys-focus-fuzz`, until it lands
in `scripts/journeys/`.

## The rule

After every action and every focus change, once the action's turn and its focus effects are done, this holds:

**I.** While cmux is the active app and shows a window, AppKit's key window is a cmux window, or a window over
it (its Chromium page window, the palette, a sheet, Settings), and that window's first responder takes the keys
the person expects (the table below). No key the person types goes to a window or view that drops it.

Focus is part of the action's own turn (zero-latency.md, the action-effect contract). An action whose target
comes later (the daemon's tab) keeps the keys for it: `CreationInputCoordinator` holds them and replays them on
the target, at most `holdLimit` (2 s); after that the keys go to the target as it is. Waiting for the target is
not "nothing focused"; never reaching it is (W11).

| After | Keys go to |
| --- | --- |
| New terminal tab, split, new column or row | the new terminal |
| New browser tab with no URL (Cmd-Shift-L) | the new tab's address bar, at once (the stand-in's bar; the daemon's tab keeps it) |
| New browser tab with a URL, a link opened in a new tab | the page |
| Close a tab | the pane's next selected tab, as its kind takes keys (terminal, page, address bar of a blank tab) |
| Close the last tab of a pane | the most recently focused surviving pane |
| Zoom, unzoom | what had the keys before |
| Command palette open | the palette's field; closed: what had the keys before |
| Settings open | the Settings window's search field; closed: the window under it, as before |
| New window | its first pane's target (New Tab page: its field; terminal: the terminal) |
| Move a workspace to a new window | the new window, the workspace's focused pane |
| Switch workspace | the workspace's remembered pane and target |
| Home | Home's composer |
| Close a window | the next cmux window in order, its target |
| Relaunch | the restored window's remembered pane and target, never the sidebar |

Where the target is ambiguous, these decide:

1. A new browser tab with no URL focuses its address bar; with a URL, its page.
2. The New Tab page focuses its field.
3. A pane with no tabs left closes; focus moves as for a closed pane. An empty workspace shows its empty
   state, whose first button takes the keys.
4. A script, CLI or agent run without `focus: true` changes no focus; with it, the same rows as the person's.
5. The sidebar takes the keys only when the person moved them there (a click into it, its shortcut, rename).
   A restore or a closed overlay never leaves them there.

## Exceptions (by name)

| Exception | Why |
| --- | --- |
| cmux is not the active app | the system gives the keys to another app; cmux keeps each window's responder for when it comes back |
| No cmux window is open (after Close All Windows) | no window can take keys; the menu bar and the palette (Cmd-Shift-P opens without a window) still work |
| A window drag, live resize or a tab drag is in flight | the pointer owns the input; the check runs when it ends |
| A system sheet or panel is up (open/save panel, print, the color panel, a permission prompt) | AppKit owns the keys; the window under it is checked when it closes |
| A menu is open (main menu, context menu) | the menu tracking loop owns the keys |
| Within `holdLimit` (2 s) of a create whose target comes later | the keys are held for the target (above); W11 reports one that never lands |
| Under `CMUX_NEXT_NO_ACTIVATE=1` (agent and capture runs) with no key window | the app never takes the keyboard by itself, so it is not active (`NSApp.isActive` false) and W10's key-window part does not apply; the journeys type into the front window |

Any other state where a key goes nowhere is a bug.

## The checks

| Id | Rule (world, after settle) |
| --- | --- |
| W1 | AppKit's first responder is what the model targets (input-spec.md) |
| W5 | Only the window AppKit made key has the keys in the model; a page, panel or sheet has them only over its window (input-spec.md) |
| W10 | Keys have a target: cmux active with a visible window has a key window; the key cmux window's model targets something that takes keys (not `none`, not an empty pane while a pane has tabs) |
| W11 | A focus expectation (a target that lands later) lands or is dropped within `holdLimit` plus one settle after its create's key hold ends (a slow reply is not stuck); one still pending after that is stuck: the keys go to the old target. A failed create leaves its expectation until a newer intent, and is reported |

`InputInvariantMonitor` checks these after every action run (`ActionRegistry.willRunObservers`), every focus
reduction (key-window, activation and responder changes included) and every key or mouse press, once input settles
(200 ms), in Debug builds, and in bench builds launched with `CMUX_NEXT_FOCUS_CHECK=1` (a bench build otherwise times
like Release); `debug.desync {check: true}` checks on demand in any build. A violation names the action that ran last, the window, the first responder and the expected target. The
monitor only records: it never moves focus to repair a violation.
