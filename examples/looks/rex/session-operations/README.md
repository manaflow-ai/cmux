# Session operations

Use these five shortcuts to manage cmux workspaces from a focused terminal. Press **Ctrl+Option+Command+J**, release the keys, then press the letter. The palette must be closed. These are shortcuts chosen for this pack. The source action reference lists no default keys for these five operations.

| Then press | Source action | cmux action | Result |
| --- | --- | --- | --- |
| N | `session.next` | `nextSidebarTabInGroup` | Select the next workspace in the current workspace group. |
| P | `session.previous` | `prevSidebarTabInGroup` | Select the previous workspace in that group. |
| L | `session.recent` | `workspace.selectLastUsed` | Return to the last used workspace in this window. Repeat to switch back. |
| R | `session.rename` | `renameWorkspace` | Edit the current workspace’s display name. |
| W | `session.close` | `closeWorkspace` | Run the native workspace close action, which can end its terminals. The usual close confirmation settings apply. |

N and P need a group with at least two workspaces. L needs another previously visited workspace still listed in the window. W follows native selection behavior, including closing multiple selected workspace rows when applicable.

## Session semantics

The bindings target cmux workspaces. A Rex session has its own server identity, windows and blocks. Renaming or closing that server session, or doing so to an agent chat by its session ID, requires a different operation. The [session picker](../session-picker/) opens agent chats by host and session ID. The [new-tab pack](../new-tab/) offers workspace creation locally or on another machine.

These Rex operations still need native session support:

- `session.back` walks session visit history repeatedly. L alternates between the two most recently used workspaces.
- `session.refresh` refreshes a server’s session inventory. cmux configuration reload and workspace reconnect have different effects.
- `session.collapse`, `session.expand` and `session.collapse_others` change the visibility of tabs beneath session rows. In cmux, folding a workspace group changes the visibility of its member workspaces.

[Official session action reference](https://www.superlogical.com/rex/docs/reference/mac-actions#session) · [Official source screenshot showing the session name, host and tabs](../new-tab/screenshots/source-window.webp)

## Preview and install

From the checkout root, preview the bindings and check the draft.

```sh
cmux customize use examples/looks/rex/session-operations/profile.json
cmux customize check
```

Choose `cmux customize apply` to keep the bindings or `cmux customize discard` to restore the previous configuration. To try the navigation, open terminals in two workspaces in one group and use N, P and L. R opens the rename UI. Use a disposable workspace to try W.

Install the standalone setup from the published branch:

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/session-operations@lane/rex-feature-looks
```

Remove it with `cmux setup remove manaflow-ai/rex-session-operations`.
