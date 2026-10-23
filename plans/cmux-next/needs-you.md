# Needs you

One list of every open ask, so no agent has to say "still waiting on you" again. It holds
approvals, decisions, verify-this asks and held agent-pair messages. They come from the Chief,
its subagents and every other agent chat.

## What ships

- **Header badge.** It sits in the agent chat header and counts the open asks.
- **Pinned list.** A press on the badge opens the list. Each ask shows:
  - the ask on one line;
  - who asked, with the agent's mark or the Chief's orb, and the chat that started a subagent;
  - its kind and age;
  - one-click answers (Allow / Deny, or one of up to four choices);
  - Go to source, which opens the asking chat at the ask's turn;
  - Ask about this, which opens a read-only side session about the asking chat beside it
    (`_acpmux/btw`, then `chat.sideChat`), seeded with "What is going on here?". The relay sends
    `_acpmux/btw` only for a chat in the pane's scope, so an ask of another chat opens that chat
    first, as a one-click answer does.
- **Needs your input pill.** While this chat, or a chat it started, has an open ask, the floating
  Jump to latest button becomes a pill: the blue dot, "Needs your input" (or "Needs your input ·
  N"), and a chevron.
  - It speaks for this chat only: its own asks and those of the chats it started (acpmux
    `startedBy` or `spawnedBy`, at any depth: the agents its tray lists). Every other chat's ask
    is in the header's list and on its sidebar row, never on this chat's button. It used to count
    every ask acpmux reports, and show at the latest message for them, so a chat where nothing
    waited read "Needs your input" for a Codex audit on another computer that no chat on screen
    had started and this pane could not answer (Leo 2026-10-22, "it doesn't work rn").
  - A press goes to this chat's ask first, then cycles through the asks of the chats it started.
  - With nothing open, it is the plain button again.
- **One mark.** The blue dot is the one "needs you" mark: the sidebar's input mark, the Chief
  dock's waiting card, the badge and the pill. Its color is the window sidebar's unread dot,
  `Palette.notificationBlue`.
- **Debug Settings toggles**; new agent tabs read them:
  - `agentPane.debug.needsYou`: pinned (default), compact or off;
  - `agentPane.debug.needsYouPill`: off by default (Leo 2026-10-23: "default off for needs your
    input.. bc it doenstr work rn... we need to fix it").

## The data model

The list has no store of its own. Every item comes from what acpmux already reports, so an ask
leaves as soon as acpmux says it was answered, wherever it was answered: its card, the Feed,
`acpmux session allow`, another pane or a phone.

The sources, all in `webviews/src/agent-session/acpmux/needsYou/`:

- **Pending permission requests** (`asks.ts`) in every chat the pane watches:
  - each new request arrives as `_acpmux/permission_pending` (`via: watch` for chats the pane has
    not attached);
  - a change to a chat's `pendingPermissions`, or an answer (`permission_decision`,
    `permission_resolved`), rereads `_acpmux/info` `pending`. The pane's relay never sends
    `_acpmux/info`: the page asks the host (`chat.asks.pending {sessionId}`,
    `AgentPanePendingAsks`), which reads it on one plain connection to the pane's own acpmux socket
    (no person proof: acpmux answers `_acpmux/info` on any local connection, and the read answers
    nothing), names the chat `local/<id>` so acpmux resolves it on its own sessions and never
    forwards the read to a peer, and hands back only each entry's `permissionId`, `request`,
    `turnId` and `groupId`;
  - a count of zero clears the chat at once;
  - a read that predates a newer ask or read is dropped;
  - after a lag (`_acpmux/lagged`) every chat with open requests is read again, and a chat acpmux
    no longer lists is dropped.

  `acpmux pending` and the Feed bridge (`AcpmuxPermissionFeedBridge`) read the same source.
- **Session indicators.** A chat whose `indicator` is `input`, or whose `pendingPermissions` is
  above zero, but whose ask the page cannot read still shows as one `input` item. A chat on
  another computer (its summary names its `peer`) is always one: the page never reads it and
  holds no ask of it, and the host's `local/<id>` read could not reach it either, so its asks are
  answered on that computer only.
- **Agent-pair holds** in the open chat's rows (#21975), answered with Resume.

The item shape (`model.ts`, `NeedsYouItem`) is the contract for every consumer:

| Field | Meaning |
| --- | --- |
| `id` | `acpmux:<permissionId>`: the Feed's dedupe key for the same prompt. Otherwise `held:<sessionId>:<peer>` or `chat:<sessionId>`. |
| `kind` | `approval`, `decision`, `verify`, `held` or `input`. |
| `sessionId`, `turnId` | The asking chat and turn. Go to source opens `cmux://session/<id>#turn-<turnId>`. |
| `ask`, `detail`, `command` | The ask on one line; more about it; whether that is a command. |
| `who` | `{name, harness, chief, via}`: the asking chat, whether it is the Chief, and its parent chat. |
| `at` | When it was asked, as near as acpmux tells. |
| `answers` | One-click answers. Each is sent through `_acpmux/permission_respond` in the harness's shape, the path the ask's card uses. |

## Agents

`acpmux pending --json` gives each request a `needsYou` link, `cmux://needs-you/<permissionId>`.
An agent puts it in a reply instead of restating the ask. The pane draws the link as a chip with
the blue dot, and the chip opens the list on that ask. Any build's scheme works
(`cmux-<tag>://`).

## Not yet

- **The Feed and the pet notices.** They post the same prompts under the same `acpmux:<id>` key,
  but they don't yet read this list's order, kinds or `via`. A follow-up can move the native
  consumers onto one shared model: `AcpmuxPermissionFeedBridge` and the pet's notice queue.
- **The Chief's Home page** (`pages/home-channels` and the native Home transcript) has no Jump to
  latest button, so it has no pill yet. The Chief's chats in the agent pane have both the pill and
  the badge.
- **Held messages in other chats.** They show only for the open chat. A hold elsewhere still shows
  as that chat's `input` item when acpmux marks the chat waiting.
