# Definition of done: Home with Chiefs (Lawrence, 2026-10-03)

Status: definition, 2026-10-03, from Lawrence's answers in the chief lane session. Each line is an
acceptance check on the macOS app, first on staging with real accounts, then on production after
the backend lead's review.

## 1. Acceptance checks

People and teams
1. Two people sign in (real Stack accounts) on two Macs; each sees Home.
2. "Team" is the existing cmux team (TeamDO members). Team members can DM each other and create group
   chats with team members (reach policy G1).
3. Invites are by email, either into a DM or into the team. An address on the team's own email
   domain gets a team invite; public mail domains (gmail.com and the like) never do.
4. DMs and groups show live on both Macs: messages, edits, reactions, read state, typing, push
   when the app is in the background.

Chiefs
5. Each person gets one main Chief automatically and can create more Chiefs (subchiefs), each with
   its own conversation and its own OptChat memory (decision O2).
6. Chiefs run hosted (always on, the laptop can sleep) with OptChat memory hosted by default; the
   user can move a Chief's memory to their MacBook or Mac mini (export, import).
7. Every Chief turn follows OptChat: fresh call, the view, `zoom` and `date`, everything logged,
   background compactor (prompt `taelin` by default, `cmux` and `custom` selectable).
8. Chiefs talk to each other inside the team, in shared conversations: my Chief can DM another
   member's Chief or join a group with it; each Chief acts with its own owner's grants.
9. A Chief has full autonomy for its owner's requests: no approval cards for its owner.
   (Another person's message to my Chief still acts with my grants and is bounded by them.)
10. A Chief sees every cmux workspace on each of its owner's Macs, creates and arranges workspaces,
    and spawns agents through the Rust acpmux on any of the owner's machines (laptop, Mac mini,
    cloud VMs), through each machine's daemon link.
11. A Chief can create and use cmux Cloud VMs and reach the team VM.
12. Images: people paste or drop images in any chat (stored by content hash); a Chief sees the
    images of its turn, and its OptChat log keeps a reference and a description.
13. Models: Chiefs use the CodeRouter route with the team's Claude and Codex accounts (decision with
    the coordinator), including vision.

Debug
14. A native OptChat debug view in the Mac app (DEV/NIGHTLY first) per Chief: the live view lines,
    the tree walkable from the root, zoom into any line down to the message, the compactor queue,
    the raw log.

## 2. Blockers and conflicts (need a decision or another owner)

- B1 Model route: check 13 depends on R35 (CodeRouter accounts in the agent pane). Until then Chiefs
  cannot run on the team's accounts; Workers AI stays a stopgap.
- B2 Cloud VMs on staging: check 11 needs a Freestyle key on staging, which is forbidden until the
  non-production Freestyle account exists (Lawrence, 2026-10-03).
- B3 Full autonomy (check 9) against the spec: identity-and-permissions and home.md say ops beyond
  read and reply from a non-owner need the owner's approval. Proposed reading: full autonomy for
  the owner's own requests; non-owner requests keep the spec rule. Needs the coordinator's record.
- B4 Same-domain team invites (check 3): needs a list of public mail domains and the team's verified
  domains (DomainDO exists for enterprise); a team without a verified domain gets no domain rule.
- B5 Chief reach into Macs (check 10): needs the daemon link to accept Chief-originated ops with the
  Chief's principal (actor stamp), and the catalog ops for workspaces and acpmux.

## 3. Durable Objects from first principles (Lawrence's question)

Lawrence: DOs earn their place for locks, alarms, realtime fan-out and a single writer; other state
may need only a Worker plus PlanetScale. Proposed audit of every DO class against that test:

| Class | Single writer needed? | Realtime sockets? | Alarms? | Verdict to check |
| --- | --- | --- | --- | --- |
| ConversationDO | yes (dense seq, ledger) | yes | retention | keep |
| UserDO | yes (inbox, settings, chief records) | yes | push queue | keep |
| MuxDO | yes (wake queue) | brain host stream | wake retries | keep or fold into the Chief's DO |
| AddressDO | per-address limits and suppression | no | delivery retries | candidate: PlanetScale rows + Worker, with atomic counters or a rate-limit binding |
| PairingDO, ConnectionDO, FeedDO, SchedulerDO, DomainDO, TeamDO, AccountIndexDO | audit | audit | audit | audit |

The audit and any refactor belong to the backend lead's area; this file only records the question.

## 4. Work items (mapped to owners)

- Home DM/group gaps G1-G7 (feat-cmux-next-home-* branches, in progress) and home-scale.md (backend
  lead reviewing).
- DO audit (section 3), then refactors it justifies.
- Chief harness: hosted OptChat Chief behind the conversation owner's agent ops (chief.md section 9),
  MemoryDO on optchat-wasm, the compactor runner, chief records and subchiefs (UserDO chief.* ops
  exist), Chief-to-Chief rules.
- Chief tools: catalog ops through each Mac's daemon link (workspaces, acpmux spawn), cloud VMs,
  team VM.
- Attachments: upload intent, R2 by content hash, image parts, vision input for the Chief.
- OptChat debug view (Mac, DEV/NIGHTLY).
- Domain-based team invites.
