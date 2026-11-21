# Reference threads

The reference app's Activity, Priority and Archive views for your agent chats, as one sidebar
section. It maps the reference's "Priority" filter (chats that need input or approval, or that
you have not read), the day headings, the two list actions, and the Archive view with search.

Screenshots come from CI and the NIGHTLY build (see `screenshots/README.md`).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/chatgpt/threads
cmux setup remove manaflow-ai/chatgpt-threads
```

## What it maps

| Reference behavior | Where here |
| --- | --- |
| Activity list, Priority section first | Section `Activity`: a Priority heading over chats that wait on you or are unread |
| Today, Yesterday headings, older days by date | Chats below Priority, grouped by their last change |
| Mark all as read | Options menu, and a link on the Priority heading |
| Clear read chats | Options menu, and a link on the Today heading; a cleared chat returns on its next turn |
| Empty state "Nothing needs attention", "Checking unread chats…" | Activity |
| Archive view: "Back to sidebar", "Search archived chats", Unarchive | Options > Archive |
| "No archived chats", "No matching archived chats", "Loading archived chats…", "Untitled chat" | Archive view |
| A row's detail line "Codex · project" | Second line of each row |
| cmux's own bell and Settled fold | `sidebar.priorityView.enabled`, `sidebar.priorityView.shown`, `sidebar.settleFinished` |

## Gaps

| Reference behavior | What is missing |
| --- | --- |
| Real archive, unarchive, mark read | No `agent_chat.archive`, `unarchive` or `mark_read` op; marks are kept in this app's storage and drop when the chat changes again |
| Activity view options (Chat, Work, Pinned, Priority as its own section, Scheduled) and Restore defaults | No setting for them; Priority is always its own section |
| Archive filters (Type, Project, Reset filters), "Show more to keep searching" | Search only; the list is filtered locally |
| Bulk "Archive chats" for Priority chats | Not built; archive is per row |
| Distinct "needs approval" state | Treated as the chat state `approval` if the host reports it, else `input` |

One customize app has one sidebar section: installing `sidebar/` as well replaces this one (see
the note in `sidebar/README.md`).
