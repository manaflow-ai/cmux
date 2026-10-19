# Risk tiers for feat-cmux-next pull requests

Each pull request into `feat-cmux-next` is labeled `risk:low`, `risk:normal` or `risk:high` from
what it changes. Only high waits for a person. Low and normal merge on agent review and the checks
relevant to the change, with no extra waiting: the `risk evidence` check passes as soon as it has
graded them, in about a minute, alongside the rest of CI.

`.github/workflows/risk-tier.yml` sets the label and runs the `risk evidence` check. The
classifier is `scripts/ci/risk_tier.py`, and its tests are in `tests/test_risk_tier.py`.
`gh-merge-green` won't merge while that check is red on the exact head.

## Tiers

A pull request takes the highest tier of any file it changes. A file no rule names is normal.

| Tier | What | Before merge |
| --- | --- | --- |
| low | docs, plans, skills, copy (`*.xcstrings`, `*.strings`), generated output, tests and fixtures, agent and tooling config (`.claude/`, `tools/`, prototypes) | green relevant checks. Post-merge checks catch the rest. |
| normal | everything else: cmux NEXT UI and logic, webviews, the daemon and cmux-tui, web routes, CI workflows and scripts, `gh-merge-green`, pins, defaults behind a setting | agent review and the relevant checks, then auto-merge or the batch queue. No person. |
| high | the six kinds below | a person looks first: an approving review on the head commit by someone other than the author, or `risk:human-ok` added by a maintainer |

High is kept small on purpose. Each kind is here because a regression in it can't be undone by
reverting the commit, or because it takes out the safety net every other tier relies on:

| High kind | Paths or change | Why (audit evidence) |
| --- | --- | --- |
| auth and credentials | `CmuxAuthRuntime`, `CMUXAuthCore`, `WebAuth/`, keychain and token stores, `web/services/auth/`, `web/proxy.ts`, any `auth`, `oauth`, `sign-in` or `login` path word, `*.entitlements` | #12121 sent signed-in production users into a sign-in loop. A leaked token stays leaked after a revert. |
| socket and relay access policy | `ControlAuthorizer`, `ControlPeer*`, `CheckedAccess`, the socket path, peer inspectors, relay crates, `services/iroh-relay-minter`, `web/services/relay`, any `relay-policy` or `socket-access` file | Who may drive the app or forward through a relay. #20644 (P1) broke local agent chats against this policy. The app has no relay policy yet, so every relay path must stay default-deny. |
| stored-data migrations | `*/migrations/*`, `drizzle/`, `migrate/`, `*Migrat*` sources, `web/convex/schema*`, `backend/db/schema*` | #16397 deployed code before its migration was applied: every Cloud VM create failed for about 7 hours. A bad migration loses data on every machine that runs it. |
| release, signing, notarization and the updater | `nightly*.yml`, any script or workflow named for sign, notarize, appcast, sparkle, release, publish, deploy, nightly, promote or rollback, `scripts/ci/lib/`, `CmuxNextUpdater` | Two release breaks in the window (#18817, 19f51d5ef2). A broken updater stops fixes from reaching anyone, so it breaks the nightly safety net that normal relies on. |
| the risk gate itself | `risk-tier.yml`, `risk_tier.py`, `CODEOWNERS` | It grades every other pull request. |
| new data deletion, new privileged trigger | a product-code line that adds a delete of files or rows (`removeItem(at:`, `remove_dir_all`, `rmtree`, `DELETE FROM`, `DROP TABLE`, `trashItem`, `deleteAll…`, `purge…`); a workflow line that adds `pull_request_target` or `workflow_run` | Deleted user data doesn't come back with a revert. 16c570b576 put a cargo cache on `pull_request_target`, a cache-poisoning path. Tests, CI scripts and comments don't count. |

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
- **CI workflows and merge tooling** (`cmux-next.yml`, `ci.yml`, `gh-merge-green`). They broke
  CI often (18 of the 142 fixes), but a bad line is one revert away and hurts no user. The cost
  of making them wait on a person was higher than the cost of the reds.
- **Pins and the package graph** (`ghostty`, `vendor/`, `Package.resolved`). Three stale pins
  broke the build (#16319, #15747, #11163). The compile checks catch that, and the fix is a
  one-line pin move. The takeback check above catches the stale-squash cause.
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

Graded with both classifiers, the 825 pull requests merged into `feat-cmux-next` from
2026-09-28 to 2026-10-19:

| | low | medium / normal | high |
| --- | --- | --- | --- |
| previous rules (paths, 40- and 1,000-line thresholds) | 89 | 493 | 243 (29%) |
| these rules | 67 | 704 | 54 (6.5%) |

The 54 high: 22 add a delete of files or stored rows, 17 touch release, signing or the updater,
9 auth, 7 socket or relay policy, 2 migrations, 1 the gate. 193 that the previous rules made high
are normal now, mostly runtime changes over 40 lines and CI routing. 22 that were low are normal
now: CI scripts that aren't docs or tests.

## Changing a designation

A wrong tier is a bug in `scripts/ci/risk_tier.py`. To change one:

1. Edit the rule in `RULES` (ordered; the first match wins) or the change-kind regexes
   (`DELETES`, `PRIVILEGED_TRIGGER`), with a one-line comment saying why.
2. Add or update a case in `tests/test_risk_tier.py`, ideally a real pull request's files in
   `test_audit_sample_of_real_pull_requests`.
3. Update the tables above with the evidence.

The pull request is high (it changes the gate), so a person looks before it lands.

## Rollout

Until 2026-10-24 00:00 UTC (`ENFORCE_FROM` in `risk-tier.yml`) a held pull request only gets a
warning, and the check passes. After that, a held pull request blocks merge. A verdict from the
advisory window doesn't count after the cutover: `gh-merge-green` reads `ENFORCE_FROM` from the
base and refuses a `risk evidence` check whose job started before it, or one that never ran. Edit
the description or push to re-grade.

After approving a high pull request, re-run its `risk evidence` check, or edit the description, so
it re-grades. Adding `risk:human-ok` re-grades on its own.

## Ship risky behavior dark

A high-tier change that a user would notice lands behind a setting or Debug toggle that defaults
off, unless it fixes a regression. nightly-next is the canary. When a change breaks nightly-next
and the fix isn't ready before the next cut, revert it:

```bash
gh-merge-green --revert manaflow-ai/cmux#<number>
```

## Sign-off labels

`risk:human-ok` (and the older `risk:waived`) count only when a maintainer (admin or maintain
role) added them; the check reads who did. Agents never add either.
