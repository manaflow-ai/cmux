# Chat version switcher (< n/m > on a forked or edited prompt)

Leo, 2026-11-21: "i remember/know that if you fork or edit in claude you can simply click a left or right
to go between the variations intra-chat. that's how our forking in a lot of cases should be able to
work. you can split it off if you want, but inline should also be quite doable. either way."

## What exists (read from the code, 2026-11-21)

- Fork: the message actions' Fork button (`MessageActions.tsx` `ForkButton`, `UserBubble.tsx`
  `forkThrough`) calls `chat.fork { throughSeq }`, which asks acpmux `acp.session.fork
  { sessionId, throughSeq }` (`operations.ts` `FORK_OP`) and opens the new chat in its own tab. It
  stays as it is (Leo: "you can split it off if you want").
- Edit: `PromptEditor` sends through `edit.send(rowId, throughSeq, text)`: acpmux forks the chat
  through the turn before the prompt (`hub/fork_at.rs`) and the edited text is sent in the fork. An edit
  is therefore a sibling chat.
- Where forks are recorded: acpmux's summary index (`acpmux-book` `index/kin.rs`): `forks: parent ->
  (child -> fork seq)`, and each `Summary.fork_of { key, seq }` (`acpmux-list-types`). The page sees
  them as `AcpmuxSessionEntry.parentId` / `forkSeq` / `turnCount` (`sessionList.ts`).
  `ListFilter::forks(root)` already lists a chat's forks from the table.
- The switcher already existed for edits (cx-ncc.61, `conversation/branches.ts`): the versions of a
  prompt are the chat it was forked from and its forks at the same turn that went past that turn
  (`turnCount` above the turns inherited); a step is `chat.select { sessionId }`, so the pane shows the
  neighbour chat, whose transcript is the same up to the prompt (a fork by reference reads the
  parent's records through `forkSeq`). A fork nobody sent in, a side chat and an archived one are not
  versions.

## What this PR changes (drawing only)

`VersionSwitcher.tsx` draws the control (it was inline in `UserBubble.tsx`), in two slots chosen by
the page's `data-fork-switcher-look`. The shipped look is the capsule (B). Gallery
`agent-pane.fork-switcher` keeps the other looks and the 1/3, 2/3 and 3/3 states; comparison sheets are
in `/tmp/cao-sheets/fork-switcher/` (round 1: placement and capsule; round 2: capsule variants).

| look | switcher box | prompt height | note |
| --- | --- | --- | --- |
| A bare arrows (before) | 76 x 24 | 43 | grey count among the row's glyphs |
| B capsule (shipped) | 84 x 24 | 43 | one control, count in full ink |
| C arrows over the bubble | 68 x 20 | 65 (+22) | shifts the transcript when a version appears |
| D capsule over the bubble | 72 x 20 | 65 (+22) | same |
| E outlined capsule | 84 x 24 | 43 | quieter, same box as B |
| F roomy capsule | 100 x 24 | 43 | biggest target, 16 wider than B |

## Gaps the protocol leaves (plan, Rust)

1. **The switcher vanishes in a long chat.** `messageBranches` runs only when the whole history is
   loaded (`!canLoadOlder`) because it counts the turns a fork inherited from the loaded rows. The
   Rust side knows this at fork time: record `forkTurns` (turns through the fork) on `fork_of` in the
   summary index, so "went past the fork" is `turnCount > forkTurns` with no transcript read, and the
   prompt a group belongs to is the first user record after `forkSeq` (a seq, which the row carries).
2. **The list the page holds may not hold the siblings.** The versions are derived in TypeScript
   from `snapshot.sessions`. New logic belongs in acpmux (language-boundaries): an
   `acp.session.versions { sessionId }` read answering `[{ forkSeq, sessions: [{ sessionId, turnCount,
   working }], index }]`, computed from `KinTables::forks` (parent -> children with seq) and the
   chat's own `fork_of`, with archived, side and never-sent forks left out as `branches.ts` does now.
   `branches.ts` then shrinks to mapping a group to the row after its `forkSeq`.
3. **A step swaps the chat, not the tail.** `chat.select` shows the neighbour chat and fades a cold
   read in (App.tsx `opened.cold`). True inline would keep the shared prefix rows mounted and swap only
   the rows after the prompt. The fork's page already can draw a chat's history as a kept tail
   (`forkTail.ts` `forkHistoryTail`); selecting a version through the same kept tail would make the step
   one frame with no fade. That needs the host's `chat.select` to take a kept tail, so it is a follow-up.

None of the three is in this PR; (1) and (2) need a protocol change (`acpmux-protocol-codegen`,
policy.json entries) and a Rust test beside `kin_tests.rs`.
