# Reference threads

The reference app's Activity, Priority and Archive views for your agent chats, as one sidebar
section. It maps the reference's "Priority" filter (chats that need input, or that
you have not read), the day headings, the two list actions, and the Archive view with search.

Screenshots come from CI and the NIGHTLY build (see `screenshots/README.md`).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/codex/threads@feat-cmux-next
cmux setup remove manaflow-ai/codex-threads
```

## What it maps

| Reference behavior | Where here |
| --- | --- |
| Activity list, Priority section first | Section `Activity`: a Priority heading over chats that wait on you or are unread |
| Today, Yesterday headings, older days by date | Chats below Priority, grouped by their last change |
| Mark all as read, Mark as read | Options menu, a link on the Priority heading and a row's menu; they call the host's `chat.mark_read` |
| Clear read chats | Options menu, and a link on the Today heading; a cleared chat returns on its next turn; this one is kept in this app's storage, as the host has no op for it |
| Empty state "Nothing needs attention", "Checking unread chats…" | Activity |
| Archive, Unarchive | A row's menu and Options > Archive, through the host's `chat.archive` |
| Archive view: "Back to sidebar", "Search archived chats" | Options > Archive; archived chats come from `chat.list` |
| "No archived chats", "No matching archived chats", "Loading archived chats…", "Untitled chat" | Archive view |
| A row's detail line "Codex · project" | Second line of each row |
| cmux's own bell and Settled fold | `sidebar.priorityView.enabled`, `sidebar.priorityView.shown`, `sidebar.settleFinished` |

Archive needs a build with the chat archive operation (`chat.archive`, with `archived` rows from
`chat.list`), as [Session Recents](../../claude-code/session-recents) does. On a build without it,
Archive shows a warning toast and nothing is hidden. Mark read works on today's builds.

## Gaps

| Reference behavior | What is missing |
| --- | --- |
| Mark as unread | No host op; the menu item is left out |
| Clear read chats | No host op; it is an app-local mark that drops when the chat changes again |
| Activity view options (Chat, Work, Pinned, Priority as its own section, Scheduled) and Restore defaults | No setting for them; Priority is always its own section |
| Archive filters (Type, Project, Reset filters), "Show more to keep searching" | Search only; the list is filtered locally |
| Bulk "Archive chats" for Priority chats | Not built; archive is per row |
| Distinct "needs approval" state | The host reports `input` only; a chat that waits on approval shows as `input` |
| A failed or lost chat | Shown with a warning mark; it is not in Priority |

One customize app has one sidebar section: installing `sidebar/` as well replaces this one (see
the note in `sidebar/README.md`).
