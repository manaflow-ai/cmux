# ACP UI integration status

Owner: ACP UI integration lead (Lawrence's coordinator). Goal (Lawrence, 2026-10-02): all of Leo's agent pane and acpmux work is on feat-cmux-next, and a tagged build runs a real agent chat end to end. Leo's lanes stay the owners of their PRs; this file tracks state and merge order. Cross-team contact goes through the mailbox (`inbox/leo/coordinator`, replies to `inbox/lawrence-coordinator/acp-ui-integration`).

## Merge order (approved by the coordinator, 2026-10-03)

1. #16174 (feat-cmux-next-acpmux into feat-cmux-next): the Rust cmux CLI, the acpmux crate, the daemon v2 state ops, git.diff/git.status, grouped permissions, handoff, session adoption. Only the integration lead merges the base into feat-cmux-next-acpmux now. Pushes need a cmux-tui landing window.
2. #16898 (cx-acpmux-bundle, Leo's lane): builds acpmux and copies it into `Contents/Resources/bin/acpmux` with `acpmux.version`. Before #16174 lands it builds the pinned ref in `scripts/cmux-next/acpmux.ref`; after, it builds the in-tree crate from the same commit as the app.
3. Pane PRs that need a rebase by Leo's lanes: #16958, #16941, #16942.

## Status table (2026-10-03 00:30 UTC)

Already on feat-cmux-next: about 60 agent pane PRs by Leo's lanes, among them #16231 (pane host), #16426, #16433, #16452, #16544, #16561, #16578, #16598 to #16615, #16627, #16642, #16643, #16647, #16648, #16662, #16682, #16695, #16697, #16715, #16721, #16727, #16729, #16733, #16735, #16736, #16739, #16741, #16742 (file search), #16746, #16748 (folder trust), #16750, #16755, #16767 (git scopes), #16896, #16905, #16910 (acpmux error and retry), #16986. Merged into feat-cmux-next-acpmux (arrive with #16174): #16930 handoff, #16940 adopt, #16949 and #16951 grouped permissions, #16955, #16970, #16984 git checkpoints.

| PR | Base | Title | State | Next step | Owner |
| --- | --- | --- | --- | --- | --- |
| [#16174](https://github.com/manaflow-ai/cmux/pull/16174) | feat-cmux-next | Rust cmux CLI with acpmux and cmux acp | conflicting (3 files, resolved locally) | final base merge + regen, push in landing window, merge when green | integration lead |
| [#16898](https://github.com/manaflow-ai/cmux/pull/16898) | feat-cmux-next | bundle the pinned acpmux daemon | mergeable, swift test red | fix red, merge after #16174 | Leo lane |
| [#16958](https://github.com/manaflow-ai/cmux/pull/16958) | feat-cmux-next | group tool permission requests in the agent pane | conflicting | rebase after #16174 | Leo lane |
| [#16941](https://github.com/manaflow-ai/cmux/pull/16941) | feat-cmux-next | read Changes from the session host through the native bridge | needs rebase | rebase after #16174 | Leo lane |
| [#16942](https://github.com/manaflow-ai/cmux/pull/16942) | feat-cmux-next | Changes options menu, branch pill, tracked-only banner | mergeable | checks, then merge | Leo lane |
| [#17002](https://github.com/manaflow-ai/cmux/pull/17002) | feat-cmux-next | agent chat from the new tab page starts in its folder | open | checks | Leo lane |
| [#16577](https://github.com/manaflow-ai/cmux/pull/16577) | feat-cmux-next | accept or reject each hunk | stale since 10-02 11:03 | rebase | Leo lane |
| [#16579](https://github.com/manaflow-ai/cmux/pull/16579) | feat-cmux-next | mic button and dictation | stale | rebase | Leo lane |
| [#16557](https://github.com/manaflow-ai/cmux/pull/16557) -> [#16583](https://github.com/manaflow-ai/cmux/pull/16583) -> [#16584](https://github.com/manaflow-ai/cmux/pull/16584) | stack | slash menu, attachments, steer | stale | rebase the stack | Leo lane |
| [#16603](https://github.com/manaflow-ai/cmux/pull/16603) -> [#16604](https://github.com/manaflow-ai/cmux/pull/16604) -> [#16614](https://github.com/manaflow-ai/cmux/pull/16614) | stack | ACP inspector log, panel, palette toggle | stale | rebase the stack | Leo lane |
| [#16719](https://github.com/manaflow-ai/cmux/pull/16719) | feat-cmux-next | sidebar row detail prototype | conflicting | rebase or close | Leo lane |
| [#16953](https://github.com/manaflow-ai/cmux/pull/16953) | feat-cmux-next | ci: self-heal bundle conflicts | conflicting | rebase | Leo lane |
| [#16773](https://github.com/manaflow-ai/cmux/pull/16773) | feat-cmux-next | file.open as a catalog action | conflicting | rebase | Leo lane |
| [#17034](https://github.com/manaflow-ai/cmux/pull/17034) | feat-cmux-next-acpmux | scoped ACP tool permission rules (docs) | mergeable | retarget to feat-cmux-next after #16174 | Leo lane |
| [#16430](https://github.com/manaflow-ai/cmux/pull/16430) -> [#16434](https://github.com/manaflow-ai/cmux/pull/16434) -> [#16501](https://github.com/manaflow-ai/cmux/pull/16501) -> [#16507](https://github.com/manaflow-ai/cmux/pull/16507) | feat-cmux-next-acpmux stack | cmux agent message, hooks, Codex app-server, agent list | stale since 10-01 | retarget after #16174 | Leo lane |
| [#16521](https://github.com/manaflow-ai/cmux/pull/16521) | feat-cmux-next | Agent GUI conversation layers (Aziz) | stale | not Leo's; Aziz's lane | Aziz lane |

## Daemon ops the page calls

| Op | Served by | On feat-cmux-next today |
| --- | --- | --- |
| initialize, watch, attach, session/new, prompt, `_acpmux/permission_respond`, set_mode, set_model | acpmux | the crate is not in the tree; arrives with #16174 |
| session/set_config_option | acpmux | arrives with #16174 |
| git.diff, git.status | page asks acpmux through the native bridge (`App.tsx` handlers) | arrives with #16174; #16941 moves them to the session host |
| file.search, acp.trust.get/set | acpmux client handlers in the page | arrives with #16174 |

## Open items

- The interim client repair EmptyWorkspaceRepair (fe5a8692167) is removed once the host-death fix is on feat-cmux-next.
- End-to-end check (tagged build): New Agent Chat, Claude Code and Codex through `sr`, streamed reply, permission answered, Changes view diff, session list. Results are recorded below when the run is done.
