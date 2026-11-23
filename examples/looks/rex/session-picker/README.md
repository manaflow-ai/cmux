# Session picker

An opt-in New Tab session list. Installing selects `tabs.newTabApp: local/customize`;
open a normal New Tab to use it. Search title, session id, host, folder or harness;
press Return to open the first visible match. Activity narrows the same list.
Rows carry program identity, a static status cue and unread indicator. The native
sidebar and its existing navigation remain available.

| Reference behavior | cmux mapping | Limit |
| --- | --- | --- |
| Change Session / Go to Session (`session.switch`, `session.select`) | `agent_chat.list`, then `agent.openSessionTab` with `{session, host?}` | Agent chats only, not terminal sessions, panes or blocks; no Cmd-K override |
| View Activity / Toggle Activity (`pane.view_activity`, `client.sidebar.activity.toggle`) | In-view activity filter: working, input, failed, lost or unread | No terminal-process/OSC activity inventory or global sidebar mode |
| Working / Blocked / Error cues | `working` → Working; `input` → Needs input; `failed` → Failed; `lost` → Lost | Agent state only; lost is not labeled a program failure |
| Done / Idle cues | idle+unread → Unread; idle+read → Idle | Unread does not prove completion; no fabricated Done state |
| New Session | `palette.newAgentChat` with `{host: "local"}` | Starts a local agent chat, not a shell |

Recency orders the list using supplied timestamps. Both host and session id form
the row key, so equal ids on different hosts remain distinct. Opening resolves
the actual chat instead of merely focusing a workspace containing many chats.
There is no claim that a workspace's focused flag identifies its active chat.

## Install or preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/session-picker@feat-cmux-next
```

To remove the installed layer, run `cmux setup remove manaflow-ai/rex-session-picker`.
To preview from the repository root, run the following commands, then choose
`cmux customize apply` or `cmux customize discard`.

```sh
cmux customize use examples/looks/rex/session-picker/profile.json
cmux customize check
```

Enable **Run actions** in Settings → Apps for the view’s buttons. This pack
uses the local customize app slot. Use [the whole setup](../whole) to combine
the host section and session picker in one app.

[Source actions](https://www.superlogical.com/rex/docs/reference/mac-actions) · [Source settings](https://www.superlogical.com/rex/docs/reference/mac-settings)

![Source window, with three terminal panes below the tab strip](../new-tab/screenshots/source-window.webp)
