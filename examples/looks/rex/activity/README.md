# Activity

An opt-in sidebar section that lists every chat needing attention, on this Mac and on connected hosts.
Installing adds an **Activity** section to the sidebar; nothing else changes. Group it **By priority**
(Needs input, Failed or lost, Unread, Working) or **By project**, and turn on **Include idle** to see
the rest. Tap a row to open that exact chat. The grouping persists.

| Reference behavior | cmux mapping | Limit |
| --- | --- | --- |
| Toggle Activity (`client.sidebar.activity.toggle`) | A `cmux.section/1` sidebar section; in [the whole setup](../whole) the host section switches between **Show hosts** and **Show activity** | The native sidebar rows stay; the section adds a mode, it does not replace them |
| Show Activity by Priority / by Session | **By priority** groups by agent state; **By project** groups by the chat's project on its host | Agent chats only, not terminal processes or panes |
| Blocked, Error, Done, Working, Idle cues | `input` → Needs input; `failed`/`lost` → Failed or lost; idle+unread → Unread; `working` → Working; idle → Idle | Unread is not proof a program finished, so no Done label |
| Elapsed time | Row badge with the age of the last update, recomputed on each change | No ticking clock: it refreshes on `agent_chat.changed`, never on a timer |

Rows are keyed by host and session id, so equal ids on different hosts stay separate. One
`agent_chat.list` read per change; nothing polls.

## Install or preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/activity@lane/rex-feature-looks
```

Remove it with `cmux setup remove manaflow-ai/rex-activity`. To preview from the repository root, run
the following, then `cmux customize apply` or `cmux customize discard`.

```sh
cmux customize use examples/looks/rex/activity/profile.json
cmux customize check
```

Enable **Run actions** in Settings → Apps so rows can open chats. This pack uses the local customize
app slot; [the whole setup](../whole) combines it with hosts, the session picker and New Tab.
`node examples/looks/rex/activity/verify-view.mjs` (Node 24) checks grouping, the idle toggle,
cross-host keys, opening, refresh on change and subscription cleanup against the app runtime.

[Source actions](https://www.superlogical.com/rex/docs/reference/mac-actions) · [Source settings](https://www.superlogical.com/rex/docs/reference/mac-settings)
