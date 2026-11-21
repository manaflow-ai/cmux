# Chief channels (2026-11-05)

Ask (Lawrence): "for chief let's have ability to make channels and be able to invite people into
channels. channels will by default contain a chief that is scoped to that channel. chiefs must be
able to create channels, customize chiefs in the channel, and invite people to channels etc"

Builds on group chats with Chief (`chief-group-chats-DESIGN.md`), the Invite People sheet
(`AgentShareInviteSheet`, invite.create / participants.add) and the `chiefs` tool
(`schemas/chief-profile/chiefs-tool.json`, `brain-chiefs.ts`).

## 1. Model: a channel is a group conversation with its own Chief

- A **channel** is a cloud `group` conversation whose head carries `channel_chief: agent_…`.
  No new conversation kind: Home, inbox, unread cursors, search, invites, roles, wake policy and
  the iOS app already handle groups, so a channel lists in Home like any chat, with unread state.
- The **channel Chief** is an ordinary Chief record in the creator's UserDO with
  `channel: {conversation, title}`. Its `main_conversation` is the channel. Because a Chief's
  settings (role, personality, instructions, model/engine, avatar) and memory are keyed by the
  agent id, a new agent per channel gives the channel its own memory, instructions, personality
  and avatar with no new storage.
- **Scope.** The channel Chief's MuxDO is bound with `channel: <conversation>`; `mux.wake` from any
  other conversation is dropped in the pure mux domain. So even if someone adds the channel Chief
  to another chat, it never reads or answers there: it sees only its channel's messages and
  attachments (the brain reads only the conversation it was woken for).
- One op, `channel.create {title, display_name?, members?}` (UserDO): makes the record, binds its
  MuxDO with the scope, and (outbox, system actor) creates the channel with the creator as owner
  and the Chief as member. The channel id is the Chief's main conversation id
  (`chiefMainConversation(agent)`), so every route keyed on a Chief's main conversation (memory,
  sign-ins, Slack) works for a channel Chief unchanged. Members are then added by the creator's own session with the existing
  reach-checked ops (participants.add for teammates, invite.create for an email); the system
  create never adds a human, so channel.create is no spam path around reach rules.

## 2. Defaults (picked; the user can override)

| Question | Default | Why |
|---|---|---|
| Who creates a channel | any signed-in user; a Chief with the `chiefs` grant for its owner | the ask |
| Who invites / removes | channel owner and admins (existing roles.ts: owner-level for invites) | reuses invite rules |
| Who customizes the channel Chief | the channel creator and the creator's Chiefs (`chiefs` tool update) | the record lives in the creator's UserDO; other admins ask the creator |
| When the channel Chief replies | wake policy `auto` (same as groups); `mentions` / `all` via Chiefs Reply | two people talking should not get a reply to every line |
| Whose word it acts on | its owner's (CHIEF-DONE B3, 5a of group chats); others' messages are context | it holds the owner's tools |
| Tools of a channel Chief | a Cloud Chief's tools only (the `chiefs` grant on, so it can invite to its own channel on its owner's word); no Mac tools (`spawn`, `workspaces`, `cloud_vms`, `browser` are this Mac's daemon's, and a channel Chief is never a local Chief: gap 2) | a Chief seen by many people should not drive its owner's machines. Enforced: `chief-brain/channel-scope.ts` keeps memory and `chiefs` only (hands, `agent`, `spawn`, `teleport` are left out and refuse if they run), the scope is read from the owner's Chief record when the Chief is turned on, and `chiefs` takes only `invite` into its own channel (`chief_channel_scope`) |
| Archive the channel Chief | archives the record; the channel stays (a group without a Chief) | no data loss |
| Channel limit | the 20-Chief cap counts channel Chiefs | bounded per user |

## 3. Surfaces (one shared path each)

- Server: `channel.create` (UserDO, protocol catalog, MCP group `home`), `chief.list` shows
  `channel`; conversation summary shows `channel_chief`.
- Chief tools: `chiefs` gains `create_channel` and `invite` (channel owner's Chief only).
- Mac: Home New Message gets "New Channel" (title + members, reusing the To: field); a Channels
  filter in the Home list; Cmd+Shift+P "New Channel…" and "Invite to Channel…"; `cmux chat
  channel create --title T [--members …]` and `cmux chat channel invite`.

## 4. Slices

1. Server core: `channel.create`, scoped MuxDO, `channel_chief` on the head and summary. Tests
   first (red), then the fix. Lands on feat-cmux-next (deploys staging), then promote to prod.
2. Chief tools: `create_channel` / `invite` on the cloud `chiefs` tool and the daemon's chief_manage.
3. Mac app: New Channel, Channels filter, palette and CLI verbs, Before|After shots.

## 5. Gaps

1. Channel admins other than the creator cannot edit the channel Chief's profile (record ownership).
2. This Mac's local Chief cannot be a channel Chief yet (same as group chats gap 6.1). It makes channels: its `chiefs` create_channel runs the app's `home.createChannel` on the control socket (optchat-chief `chief_channel.rs`; the daemon holds no cloud session, so the daemon's chief_manage is not the path), under its `chiefs` grant. Its `chiefs` has no `invite` yet.
3. The `invite` action runs as the inviting Chief (its own principal, `invited_by` its id), not as the owner: participants.add and invite.create check that Chief's own participation and role, so a Chief outside the channel is refused (`forbidden`), and the channel's own Chief invites to its channel. create_channel's first invites run as the new channel Chief. The Chief still acts only on its owner's word (effect-policy). The Mac's New Channel invites through the person's own session.
