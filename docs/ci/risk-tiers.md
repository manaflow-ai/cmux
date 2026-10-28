# Risk tiers for feat-cmux-next pull requests

Each pull request into `feat-cmux-next` is labeled `risk:low`, `risk:normal` or `risk:high` from
what it changes. Only high waits for a person. Low and normal merge on agent review and the checks
relevant to the change, with no extra waiting: the `risk evidence` check passes as soon as it has
graded them, in about a minute, alongside the rest of CI.

`.github/workflows/risk-tier.yml` sets the label and runs the `risk evidence` check. The
classifier is `scripts/ci/risk_tier.py`, and its tests are in `tests/test_risk_tier.py`.
Nothing merges while that check is red on the exact head: `next-autoland` (`scripts/ci/next_batch.py`)
into `feat-cmux-next` and `gh-merge-green` both refuse it.

## Tiers

A pull request takes the highest tier of any file it changes. A file no rule names is normal.

| Tier | What | Before merge |
| --- | --- | --- |
| low | docs, plans, skills, copy (`*.xcstrings`, `*.strings`), logs (even inside a high directory), generated output, tests and fixtures, agent and tooling config (`.claude/`, `tools/`, prototypes) | green relevant checks. Post-merge checks catch the rest. |
| normal | everything else: cmux NEXT UI and logic, webviews, the daemon and cmux-tui, web routes, CI workflows and scripts, pins and lockfiles (even inside a high directory), defaults behind a setting | agent review and the relevant checks, then auto-merge or the batch queue. No person. |
| high | the six kinds below | an independent review receipt `Review (<reviewer>): SHIP at <full head sha>` on the exact head plus a green compile. The line goes in the description (no comment needed) or leads a comment. An approving review on the head by a collaborator other than the author, or `risk:human-ok` added by a maintainer, also counts. Only a BLOCK or FIX on the head turns the check red; with no verdict yet it passes with a warning |

High is kept small on purpose. Each kind is here because a regression in it can't be undone by
reverting the commit, or because it takes out the safety net every other tier relies on:

| High kind | Paths or change | Why (audit evidence) |
| --- | --- | --- |
| auth and credentials | `CmuxAuthRuntime`, `CMUXAuthCore`, `WebAuth/`, keychain and token stores, `web/services/auth/`, `web/proxy.ts`, any `auth`, `oauth`, `sign-in` or `login` path word, `*.entitlements` | #12121 sent signed-in production users into a sign-in loop. A leaked token stays leaked after a revert. |
| socket and relay access policy | `ControlAuthorizer`, `ControlPeer*`, `CheckedAccess`, the socket path, peer inspectors, relay crates, `services/iroh-relay-minter`, `web/services/relay`, any `relay-policy` or `socket-access` file | Who may drive the app or forward through a relay. #20644 (P1) broke local agent chats against this policy. The app has no relay policy yet, so every relay path must stay default-deny. |
| agent pane host op or allowlist (socket and relay access policy): what an agent pane may make the host do | the page ops list `AgentPageProvider.swift` (`AgentPageOps`), `AcpmuxPaneMethods*` (the `_acpmux/*` methods and `knownParams` a pane may relay), the page-op param tables `AgentPaneEnvironmentRequest` and `AgentPaneReplyRequest`, the frame check `AgentPaneTransport+Check`, the gesture rule `AgentPaneTransport+Frames` (`decide`, which spends a click's ticket) and `AgentPaneGestureIntent` (which methods a ticket redeems), the tickets themselves `AgentPaneUserGestures`, the app actions a page may run `AgentPaneModel+Actions` (`connectActions`), the folder policy `AcpmuxPathPolicy` and the folders a person picks `AgentPaneTransport+PickedFolder`, the relayed-allow proof `AgentPaneTransport+RelayedAllow` (signs an allow with the person key), the full-access refusal `AgentPaneTransport+FullAccess`, `AgentPanePendingAsks` (opens its own acpmux connection for a page), the Rust mirror `cmux-agent-pane-policy`, and acpmux's `server/remote_guard.rs`. Their tests stay low; the rest of `CmuxNextAgentPane` stays normal | #22646 added the page op `chat.asks.pending`, which read another chat's permission asks over the host's own acpmux connection and reached a peer daemon until review caught it (fixed by naming the chat `local/<id>` and refusing replies that name a peer). It graded normal by path. A page is untrusted content, so a new op is a new way into the host; every new op edits the ops list. |
| stored-data migrations | `migrations/`, `*/migrations/*`, `drizzle/`, `migrate/`, `*Migrat*` sources, `web/convex/schema*`, `backend/db/schema*` | #16397 deployed code before its migration was applied: every Cloud VM create failed for about 7 hours. A bad migration loses data on every machine that runs it. |
| release, signing, notarization and the updater | `nightly*.yml`, any script or workflow named for sign, notarize, appcast, sparkle, release, publish, deploy, nightly, promote or rollback, `scripts/ci/lib/`, `CmuxNextUpdater` and `CmuxUpdater` (except the channel and preference values below) | Two release breaks in the window (#18817, 19f51d5ef2). A broken updater stops fixes from reaching anyone, so it breaks the nightly safety net that normal relies on. |
| the risk gate itself | `risk-tier.yml`, `risk-tier-tests.yml`, `risk_tier.py`, `CODEOWNERS`, and what refuses a red `risk evidence`: `scripts/gh-merge-green`, and `scripts/ci/next_batch.py` with `cmux-next-batch.yml` (next-autoland) | It grades every other pull request. A normal change to an enforcer could drop the refusal with no person looking. |
| new data deletion, new privileged trigger | a product-code line that adds a delete of files or rows (`removeItem(at:`, `remove_dir_all`, Rust `fs::remove_file`/`fs::remove_dir`, `rmtree`, `DELETE FROM`, `DROP TABLE`, `trashItem`, `deleteAll…`, Drizzle `db.delete(`/`tx.delete(`) that the pull request doesn't also remove from product code (an edited or moved delete isn't new, so retargeting an existing delete is normal: agent review catches that; a cleanup line moved out of a test into product code is new); a workflow line that adds `pull_request_target` or `workflow_run` | Deleted user data doesn't come back with a revert. 16c570b576 put a cargo cache on `pull_request_target`, a cache-poisoning path. Tests, CI scripts (`scripts/`, `*/scripts/`), generated bindings, comments and in-memory purges don't count. |

### Taking back a recent change

Separately from the tier, a pull request that takes back what another pull request merged in the
last 7 days is held. It deletes most of what that pull request added, and puts back most of what
it replaced. This is how a stale-base squash silently undoes other work: one (50a0c607aee, #21194)
undid #21199, #21369 and #21384. The check names the pull request. To clear it, merge the base
and push. If it's on purpose, add a line `Takes back #N: <why>` to the description. An agent
clears this; no person is needed.

### What is deliberately not high

- **Size.** There is no line-count rule. In the audit, the changes that broke things were as
  often small as large: the unclosed CSS rule (#19473) was one line, and the P1 (#20644) was 48
  lines. A size rule mostly made large, safe UI work wait.
- **CI workflows** (`cmux-next.yml`, `ci.yml`), apart from the gate's enforcers above. They broke
  CI often (18 of the 142 fixes), but a bad line is one revert away and hurts no user. The cost
  of making them wait on a person was higher than the cost of the reds.
- **Pins and the package graph** (`ghostty`, `vendor/`, `Package.resolved`). Three stale pins
  broke the build (#16319, #15747, #11163). The compile checks catch that, and the fix is a
  one-line pin move. The takeback check above catches the stale-squash cause.
- **The update channel setting** (`CmuxUpdater/UpdateRing.swift`, `CmuxNextUpdater/UpdatePreferences.swift`,
  and the settings schema). Choosing a ring reuses the feeds the release pipeline already signs,
  and the updater still verifies every download (Leo, 2026-10-21, after #22781). The code that
  decides whether the updater runs (`UpdateTrack`), or parses, probes, installs or verifies an
  update, stays high, and so does the rest of the `CmuxUpdater` package: the Sparkle driver, the install
  code, `UpdateFeedResolver` and the channel switch's `AppSignatureVerification`.
- **Defaults** (`schemas/defaults/`). A default ships with its setting, so undo is the setting
  (#21686).
- **The daemon, protocol and terminal paths.** These had real regressions (a render deadlock
  from #8698, and an app option older cmux-tui builds refused), but none lost data, and every fix
  was a forward fix in the next nightly. They need agent review and the relevant tests, not a
  person.

## The audit behind this (2026-08-20 to 2026-10-18)

We read every fix commit on `main` and `feat-cmux-next` in the window that names the commit it
fixes (573 scanned, 142 with a firm culprit), and every revert (83).

| Bucket | Count | What it was |
| --- | --- | --- |
| base red from a pull request | 56 | a merged pull request turned a check red on the base: lint, guards, tests that never ran before merge |
| base red from a direct push | 30 | all on `feat-cmux-next`, all pushed without a pull request |
| real regression | 28 | a user-visible break (the list below) |
| other | 11 | design or ownership rollbacks |
| unfinished | 9 | half-done work reverted by its own author |
| stale-base squash | 8 | a squash that silently undid other merged work |

Of the 28 real regressions, by severity:

- **Production auth or data: 3.** The sign-in loop (#12121), the unapplied migration (#16397),
  and `/api/vm` throwing on rows from a retired provider (#11566). The first two are high now.
  The third was a read path in `web/services`, fixed forward in a day; it stays normal.
- **Release breaks: 2** (#18817, 19f51d5ef2). High now.
- **Security: 1, latent.** The `pull_request_target` cache (16c570b576). High now as a change kind.
- **P1 functional: 1** (#20644, agent chats). The caller changed, not the policy, so no path rule
  sees it. It stays normal; its regression test is the guard.
- **Crashes and hangs: 3** (a drag-end crash, a Cmd+Y crash, a render deadlock). Each was
  UI or logic code, fixed forward within a day. Normal.
- **Functional UI and logic: 18.** Normal. Every one was fixed forward or reverted the same or
  next day, and none lost data.

So most real regressions are normal-tier UI and logic, and asking a person to look at every one
of those would have stopped all merging. The tiers put a person only where a revert doesn't undo
the damage.

The biggest bucket is base reds (86 of 142), and tiers don't fix those. They come from checks
that don't run before merge (`feat-cmux-next` pull requests skip `cmux-next swift test` unless
labeled `full-ci`) and from direct pushes. On 2026-10-18, three direct pushes to `feat-cmux-next`
(the sidebar card transition at c5a1f900ec, the error journal at 1597dc9c14, browser popups at
fa8b3fcdda) broke lint and concurrency guards and kept every pull request into the branch red
for about 1.5 to 2 hours. The fix for that is running the relevant checks before merge and not
pushing directly, not a person's review.

### Replay over feat-cmux-next

Graded with both classifiers, the 1,035 pull requests merged into `feat-cmux-next` from
2026-09-28 to 2026-10-20 (first-parent, up to d080fa059e):

| | low | medium / normal | high |
| --- | --- | --- | --- |
| previous rules (paths, 40- and 1,000-line thresholds) | 133 | 598 | 304 (29%) |
| these rules | 90 | 866 | 79 (7.6%) |

Why the 79 are high (a pull request can have more than one reason): 30 add a delete of files or
stored rows (stores and caches in the daemon, CmuxNext and acpmux that remove files), 20 touch
release, signing or the updater, 10 auth, 9 socket or relay policy, 7 the gate or its enforcers
(`gh-merge-green`, `next_batch.py`), 4 a privileged workflow trigger, 4 migrations. 242 that the
previous rules made high are normal now, mostly runtime changes over 40 lines and CI routing. 42
that were low are normal now: CI scripts and lockfiles, which aren't docs or tests.

## Changing a designation

A wrong tier is a bug in `scripts/ci/risk_tier.py`. To change one:

1. Edit the rule in `RULES` (ordered; the first match wins) or the change-kind regexes
   (`DELETES`, `PRIVILEGED_TRIGGER`), with a one-line comment saying why.
2. Add or update a case in `tests/test_risk_tier.py`, ideally a real pull request's files in
   `test_audit_sample_of_real_pull_requests`.
3. Update the tables above with the evidence.

The pull request is high (it changes the gate): an independent SHIP at the exact head plus a green compile clears it.

## Rollout

Until 2026-10-24 00:00 UTC (`ENFORCE_FROM` in `risk-tier.yml`) a held pull request only gets a
warning, and the check passes. After that, a held pull request blocks merge. A verdict from the
advisory window doesn't count after the cutover: `gh-merge-green` reads `ENFORCE_FROM` from the
base and refuses a `risk evidence` check whose job started before it, or one that never ran. Edit
the description or push to re-grade.

Put the receipt in the description: editing the description re-grades the check on its own. After
posting a receipt comment on, or approving, a high pull request instead, re-run its `risk evidence`
check, or edit the description, so it re-grades: a comment or review doesn't trigger the check.
Adding `risk:human-ok` re-grades on its own.

A high pull request with no verdict on its head passes with a warning in the job summary ("no
review verdict on the head commit yet"), not a red check. It still lands only after an independent
review passes. The newest verdict on the head being a BLOCK, FIX or change request is the one hold.

## Ship risky behavior dark

A high-tier change that a user would notice lands behind a setting or Debug toggle that defaults
off, unless it fixes a regression. nightly-next is the canary. When a change breaks nightly-next
and the fix isn't ready before the next cut, revert it:

```bash
gh-merge-green --revert manaflow-ai/cmux#<number>
```

## Sign-off labels

`risk:human-ok` (and the older `risk:waived`) count only when a maintainer (admin or maintain
role) added them; the check reads who did. Agents never add either, and never need to: a SHIP
receipt on the head is enough. The receipt is a line of the description, or the first line of a
comment or review body, from a collaborator (for the description, its author must be one, the same
rule as a commenter); it names the full head sha and isn't a self-review. A description line inside
an HTML comment doesn't count, and description lines rank below every comment and review, so a later
BLOCK comment beats a SHIP in the description. The newest verdict on the head
decides, read as one timeline with approvals and change requests of the head commit: a later BLOCK
or change request beats an earlier SHIP or approval, a BLOCK wins a tie, and any push needs a new
receipt. The label counts only while no verdict names the head.
