# Hosts

An opt-in Hosts sidebar section (`cmux.section/1`, top region). Select This Mac
or a known peer, search its chats, and click a session to open it. New chat on
selected host calls the native creation action with that host's identity.
Add Host opens cmux's native connection/setup dialog.

| Reference behavior | cmux mapping | Limit |
| --- | --- | --- |
| Switch Host (`client.host.switch`) | Select the local or peer group from `agent_chat.list` | Filters this view; does not change the global default host |
| New Session on Host (`session.new.on_host`) | `palette.newAgentChat` with `{host: selectedHost || "local"}` | Creates an agent chat; remote destination must still resolve and be ready |
| Add Remote Host (`client.host.add`) | `server.addServer` | Native cmux machine setup; no direct Rex host URL compatibility |
| Select a remote session (`session.select`) | `agent.openSessionTab` with `{session: id, host: machine}` | Does not execute local shell SSH commands or flatten host identity |
| Activity beside each host's session | Agent state text, theme tone and unread indicator | Not SSH connection health, process activity, or unread completion proof |

The host list is derived from visible agent chats, plus This Mac. A remote host
with no indexed chats is not an inventory entry here; Add Host and the native
new-chat Environment picker remain the routes for discovering/setting up those
hosts. Nothing claims that a host is online because it has chats. Connection
errors, readiness and trust prompts stay in the native flow. Host removal,
reordering, SSH credentials, port forwarding and Tailscale serving are not
implemented by this look. The section uses the normal SDK 50-row viewport.

## Install or preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/hosts@feat-cmux-next
```

To remove the installed layer, run `cmux setup remove manaflow-ai/rex-hosts`.
To preview from the repository root, run the following commands, then choose
`cmux customize apply` or `cmux customize discard`.

```sh
cmux customize use examples/looks/rex/hosts/profile.json
cmux customize check
```

Enable **Run actions** in Settings → Apps for the view’s buttons. This pack
uses the local customize app slot. Use [the whole setup](../whole) to combine
the host section and session picker in one app.

[Source actions](https://www.superlogical.com/rex/docs/reference/mac-actions) · [Source settings](https://www.superlogical.com/rex/docs/reference/mac-settings)

![Source window, with three terminal panes below the tab strip](../new-tab/screenshots/source-window.webp)
