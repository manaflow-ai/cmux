# Group chats with Chief (2026-10-20)

Ask (Lawrence): "for imessage ui i need to be able to make group chats with chief somehow". In
Home, a person starts a group that holds Chief, other Chiefs (Unii, Cloud Chief, Team Pulse) and
teammates, adds a Chief to a group later, and decides when the Chiefs answer.

Builds on a132's groups (`plans/cmux-next/home-dm-group-chats/DESIGN.md`, grpui-land 14d5972e79b:
`HomeGroupActions`, the group info sheet) and the owner's wake rules (`home.md` section 5,
home-core `fanout.ts wakesFor`). It adds no new conversation kind and no new backend op.

## 1. What already worked

- `conversation.create` and `participants.add` take Chiefs (`agent_…`, class `mux`): a group is
  "humans and chiefs, 2 to 64" (home-messaging.md 2).
- New Message is a page with a To: field; several recipients make a group; its + button lists
  every contact, Chiefs tagged "Chief"; typing a Chief's name suggests it.
- The cloud brain is one ChiefBrainDO per conversation (`<agent>/<conversation>`): when woken it
  reads the conversation's new messages, every member's, so the group transcript is its context
  and never another conversation's.
- The owner decides who wakes. `settings.wake_policy` has `auto` (default), `mentions`, `all`.

## 2. What was missing, and what this adds

| Gap | Added |
|---|---|
| Starting a group with Chiefs took typing names or the + list | The **Chiefs list** under To: before anything is typed (one row per Chief not chosen yet: avatar, full name, "Chief · Main · Cloud"); a click or Down then Return adds it. |
| No way to say when Chiefs answer | **Chiefs Reply** in group info: "Automatically", "Only When @Mentioned", "Every Message". It is `conversation.settings.set {wake_policy}` (owner of the group only). Hidden in a group with no Chief and in a local group (the local owner has no settings). |
| The daemon refused `conversation.settings.set` | Added to `CLOUD_OP_KINDS` (default deny list) so the Mac can send it. |
| The app did not read `settings` | `ConversationSummary.chiefReplies` (from `settings.wake_policy`). |
| No CLI or MCP to start a group | `home.createGroup` = `cmux chat create --members "Chief, Unii, aziz@manaflow.com" [--title T] [--replies auto|mentions|all]`; `home.setChiefReplies` = `cmux chat replies --replies all [--conversation ID]`. Both in Cmd+Shift+P and MCP (catalog). |
| The mock's first Chief answered every message | The mock follows the owner's rule (`ChiefReplyPolicy.responders`), so tests and the gallery see the real behavior. |

Adding a Chief to an existing group was already in group info's Add People list (Chiefs are
contacts); it stays the one path (`HomeGroupActions.add`).

## 3. When a Chief replies (defaults)

`ChiefReplyPolicy` mirrors home-core `wakesFor`. For every Chief in the group except the author:

1. It is @mentioned: it replies.
2. The message replies to its own message: it replies.
3. A person wrote it and the policy is `all`: every Chief replies.
4. A person wrote it, the policy is `auto`, and the group is one person and one Chief: it replies.

Default `auto`. Chosen over "reply when it is the only agent" in a group of several people: two
founders talking should not get a Chief answer to every line unless they ask for it (`all`). The
turn budget (6 agent turns per person message, 2 s gap) still stops two Chiefs from looping.

## 4. Identity and hosts

- Each Chief keeps its own name and avatar in a group: the transcript draws each author from its
  participant record (a260 owns per-Chief avatars; nothing here shares one avatar).
- Cloud and server Chiefs: the group is a Cloud conversation; a Chief whose brain runs on a Mac
  mini or a paired server gets its wakes from its MuxDO queue as in a DM, so it answers from there.
- This Mac's Chief (`agent_mux`, Unii): a group of only this Mac's Chiefs and me is a local group
  (HomeSourceRouter). Mixing this Mac's Chief with cloud people is not possible yet: its agent id
  has no cloud record (gap 6.1).

## 5. UI designs (gallery: `plans/cmux-next/chief-group-chats-gallery.html`)

- A. Chiefs strip under To: (shipped first, replaced 2026-10-20). A row of capsule buttons
  "+ Chief" under the field. Two Chiefs named "Chief" (the Hosted Chief and this Mac's) showed as
  two identical "+ Ch…" pills squeezed by the "Chiefs" label; Leo: "this is bad".
- **D. Chiefs list under To: (shipped).** Before anyone is chosen or typed, the suggestion list
  under To: lists the Chiefs, main first: avatar, full name, and under it "Chief · Main · Cloud"
  or "Chief · This Mac" (the Home list's tags). Nothing is highlighted until Down; Return picks
  the highlighted one. Typing narrows to everyone; + lists everyone. Archived Chiefs are left out.
  Group info gets the Chiefs Reply picker.
- B. Chiefs section in the + list: Chiefs grouped first with a header. Needs a click on + first.
- C. Chief toggle in the composer ("Ask Chief" pill): adds the main Chief only; hides the others.

## 5a. Whose word a Chief acts on (2026-10-26)

In a group each Chief acts for its own owner (CHIEF-DONE B3). The Cloud Chief's message header marks
its owner's lines "(your owner)" and the Mac Chief's side label says `from your owner`; both prompts
say the owner's requests run without asking, anyone else's actions need the owner's word, and
another person's Chief is never the owner's word. Enforcement does not rest on the model: a turn
whose batch holds a message that asks this Chief from anyone but its owner runs with effects refused
(`messageEffectAuthorized`, the Mac's `requires_approval`). A message to someone else in the same
batch is context and leaves the owner's request free. A ready reply that meets the loop guard's 2 s
gap (agent_rate) is retried for 2 minutes, never dropped after a fixed count.

## 6. Gaps

1. This Mac's Chief in a cloud group (needs a cloud agent record for local Chiefs, or a relay).
2. Subagents (acpmux sessions) are not Home participants; a group cannot hold one.
3. No per-Chief override (one Chief on `all`, another on mentions): the owner has one policy.
4. Team Pulse and other Chiefs show only once they have a conversation row or a `chief.list` entry.
