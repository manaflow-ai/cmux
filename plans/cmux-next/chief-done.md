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

## 5. Status of checks 1-4, 8, 9 (a673, 2026-10-26)

Live on staging: `bun backend/scripts/chief-multiplayer-staging.ts` (two throwaway Stack accounts,
deleted at the end; 28/28 on 2026-10-26 after the fixes below). Hermetic:
`backend/apps/api/test/chief-multiplayer-e2e.test.ts`, `chief-group-rules.test.ts`. Model evals:
`Native/OptChat/optchat-chief/evals/cases/multiplayer-a673-*.json` (old prompt 8/12, new 12/12).

| Check | State | Proof |
| --- | --- | --- |
| 1 Two people sign in, each sees Home | done (API) | staging script: user.ensure, main Chief, inbox.list for both. The Mac UI was not driven on two Macs. |
| 2 Team members DM and make groups | done | Stack team mirrored into TeamDO in about 3 s (webhook); dm.open by id; group with both. |
| 3 Invites by email: verified domain gets a team invite, else a DM invite | open | DM invites by email work (home-dm-group-e2e). Team invites by email exist only in the web console (web/services/teams/invitations.ts); domain claims exist in TeamDO (domain.claim/verify). Missing: the Home invite path that sends a verified-domain address to a team invite. |
| 4 Live on both: messages, edits, reactions, read state, typing | done (sockets) | staging script: each socket gets the other's message in about 70-160 ms, typing, edit, reaction, read cursor, unread in the inbox. Push in the background is not checked. |
| 8 Chiefs in shared conversations, each with its own owner's grants | done | each person adds only their own Chief (another's is forbidden); the reply rule (auto, all) picks who answers; two Chiefs never wake each other. |
| 9 Owner autonomy, approval rule for others | done | a teammate's effect request gets "owner approval required" and nothing runs; the owner's runs at once. |

Fixes found by these checks: a non-owner's message in the same batch made the owner's own request
refused (fixed: only a message that asks this Chief removes its autonomy); a Chief's ready reply was
dropped after 5 agent_rate refusals in a busy group (fixed: agent_rate retries for 2 min); neither
the Cloud Chief nor the Mac Chief knew which group member was its owner (fixed: the header says
"(your owner)" / "from your owner", and both prompts carry the owner rule).
