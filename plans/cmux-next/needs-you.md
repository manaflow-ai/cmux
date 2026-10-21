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
  - Ask about this, which sends a side question (`_acpmux/ask`) to a read-only copy of the asking
    chat, seeded with "What is going on here?".
- **Needs your input pill.** While any ask is open, the floating Jump to latest button becomes a
  pill: the blue dot, "Needs your input" (or "Needs your input · N"), and a chevron.
  - A press goes to this chat's ask first, then cycles through the asks open in other chats.
  - With nothing open, it is the plain button again.
- **One mark.** The blue dot is the one "needs you" mark: the sidebar's input mark, the Chief
  dock's waiting card, the badge and the pill. Its color is the window sidebar's unread dot,
  `Palette.notificationBlue`.
- **Debug Settings toggles**, both on by default; new agent tabs read them:
  - `agentPane.debug.needsYou`: pinned, compact or off;
  - `agentPane.debug.needsYouPill`.

## The data model

The list has no store of its own. Every item comes from what acpmux already reports, so an ask
leaves as soon as acpmux says it was answered, wherever it was answered: its card, the Feed,
`acpmux session allow`, another pane or a phone.

The sources, all in `webviews/src/agent-session/acpmux/needsYou/`:

- **Pending permission requests** (`asks.ts`) in every chat the pane watches:
  - each new request arrives as `_acpmux/permission_pending` (`via: watch` for chats the pane has
    not attached);
  - a change to a chat's `pendingPermissions`, or an answer (`permission_decision`,
    `permission_resolved`), rereads `_acpmux/info` `pending`;
  - a count of zero clears the chat at once;
  - a read that predates a newer ask or read is dropped.

  `acpmux pending` and the Feed bridge (`AcpmuxPermissionFeedBridge`) read the same source.
- **Session indicators.** A chat whose `indicator` is `input`, or whose `pendingPermissions` is
  above zero, but whose ask the page cannot read (a chat on another computer) still shows as one
  `input` item.
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
