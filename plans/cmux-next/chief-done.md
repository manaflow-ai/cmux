# Definition of done: Home with Chiefs (Lawrence, 2026-10-03)

Status: definition, 2026-10-03, from Lawrence's answers in the chief lane session. Each line is an
acceptance check on the macOS app, first on staging with real accounts, then on production after
the backend lead's review.

## 1. Acceptance checks

People and teams
1. Two people sign in (real Stack accounts) on two Macs; each sees Home.
2. "Team" is the existing cmux team (TeamDO members). Team members can DM each other and create group
   chats with team members (reach policy G1).
3. Invites are by email, either into a DM or into the team. An address on a verified team domain
   (an admin's DNS TXT check) gets a team invite; public mail domains are on a deny list and can
   never be verified; any other address gets a DM invite.
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
9. A Chief has full autonomy for its owner's own requests: no approval cards for its owner.
   Requests from anyone else keep the approval rule (coordinator record CHIEF-DONE, B3).
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

## 2. Blockers and rulings (coordinator, 2026-10-03: R57, decisions CHIEF-DONE 5ffee4e)

- B1 Model route: check 13 depends on R35 (CodeRouter accounts in the agent pane). Until then
  Workers AI stays a stopgap.
- B2 Cloud VMs on staging: blocked until the non-production Freestyle account exists.
- B3 Ruled: full autonomy for the owner's own requests; anyone else's requests keep the approval rule.
- B4 Ruled: team invites only for a verified team domain (admin DNS TXT check); public mail domains
  are on a deny list and can never be verified; otherwise a DM invite.
- B5 Task for the daemon-link owner (after the backend review): the daemon link accepts
  Chief-originated ops with the Chief's principal (actor stamp), and the catalog exposes the
  workspace and acpmux ops a Chief needs.

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

The full audit is plans/cmux-next/do-audit.md (R58, written by this lane, reviewed and owned by the
backend lead after home-scale.md).

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
