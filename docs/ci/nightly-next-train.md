# cmux NEXT nightly release train

Design: leo-workspace `workstreams/cmux-next-nightly-train.md` ([leo-workspace#624](https://github.com/teamleaderleo/leo-workspace/pull/624)).
This page covers what is built: the durable canary verdict, the train planner,
the train workflow and the promote guard's train path (G1'/G2'). Per-car fast
guards (design PR 3), the pulled-build banner (PR 4) and the native workflow
runtime (PR 6) plug into it and are not here.

## Switches

| Repository variable | Default | Effect |
| --- | --- | --- |
| `NIGHTLY_NEXT_TRAIN` | unset (= `dry-run`) | `dry-run`: every tick plans a train and its run summary is the plan; promotion stays as before. `on`: the tick starts the full train instead of a plain promotion. `off`: no train runs. Once a train commit has shipped, keep `on` (see below). |
| `NIGHTLY_NEXT_TRAIN_K` | 4 | Builds per bisection round (1 to 8). |
| `NIGHTLY_NEXT_TRAIN_ROUNDS` | 3 | Bisection rounds before the train gives up (1 to 6). |
| `NIGHTLY_NEXT_TRAIN_CAP_MINUTES` | 120 | Wall-clock cap for one train (30 to 300). |
| `NIGHTLY_NEXT_TRAIN_RUNNER` | empty: `vars.CI_SIDE_LANE_RUNNER` alone | An owned pool label the candidate Release compile takes first, while one of its runners is idle (`pick-train-runner`, `scripts/ci/nightly_build_runner.py`); otherwise `vars.CI_SIDE_LANE_RUNNER`, then the moving Blacksmith macOS 26 label. Never a GitHub-hosted Mac. A compile an owned runner refuses is re-run by the drive and takes Blacksmith. |
| `NIGHTLY_NEXT_TRAIN_CAR_GUARD` | `scripts/ci/nightly-next-car-guard.sh` when it exists | Per-car guard command (design PR 3). Exit 0 keeps the car, 1 quarantines it, anything else is a warning. |

The defaults are the design's (k = 4, 2-hour cap). They are open calls for Leo,
so each is a variable.

Before `NIGHTLY_NEXT_TRAIN=on`:

1. Create environment `nightly-next-train` (deployment branch `feat-cmux-next`)
   with `CMUX_RELEASE_APP_ID` and `CMUX_RELEASE_APP_KEY`. A train commit
   changes workflow files against nightly-next, and `GITHUB_TOKEN` cannot push
   those; the release App (contents and workflows write) pushes the
   `nightly-train/*` refs.

   The environment, its branch policy and the two secrets, in one paste (the
   App ID and the App's private key file come from the release App's settings):

   ```bash
   gh api -X PUT repos/manaflow-ai/cmux/environments/nightly-next-train \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/manaflow-ai/cmux/environments/nightly-next-train/deployment-branch-policies \
     -f name=feat-cmux-next
   gh secret set CMUX_RELEASE_APP_ID -R manaflow-ai/cmux --env nightly-next-train --body "$CMUX_RELEASE_APP_ID"
   gh secret set CMUX_RELEASE_APP_KEY -R manaflow-ai/cmux --env nightly-next-train < release-app.private-key.pem
   ```

   No required reviewers: the canary verdict and the train's Release compile
   (G2') are the gate.
2. Land the main mirror: main's `nightly.yml` promote job, the promote guard,
   `scripts/ci/nightly_next_train.py` (the guard runs its `verify`), the tick,
   the canary, and the dispatch stubs of `nightly-next-train.yml` and
   `nightly-next-verdict.yml` (GitHub registers dispatch workflows only from
   the default branch).

**One way.** Once nightly-next is a train commit, no feat-cmux-next commit
descends from it, so a plain promotion is refused (the ancestor check). Keep
`NIGHTLY_NEXT_TRAIN=on`: a train with nothing quarantined ships the tip's
tree. Going back to plain promotion means moving nightly-next to a
feat-cmux-next commit by force, which is Leo's call.

## Durable verdict

After each scheduled static artifact check of a feed build, `nightly-next-canary.yml` dispatches
`nightly-next-verdict.yml` on branch `nightly-next` (environment `release-next`
holds the feed's R2 token). It writes
`https://files-next.cmux.com/nightly-next/next/verdicts/<build>.json`:

```json
{"schema": 1, "build": "3947349329001", "verdict": "pass", "commit": "<nightly-next commit>",
 "canaryRun": "https://github.com/manaflow-ai/cmux/actions/runs/<id>", "checkedAt": "2026-10-20T16:00:00Z"}
```

The writer reads the commit from the build's own nightly-next run (build number
= `<run id><attempt>`). It accepts `pass` only from a scheduled
`nightly-next-canary.yml` run whose static artifact verification job succeeded. `fail` and
`skipped` never make a build a base, so they are written as given. The pass
also needs the run's own `verdict pass <build>` job, because a skipped check
leaves the canary job green too. The canary's
Actions cache only marks a build as checked, and it expires; the R2 document
does not.

The verdicts sit next to the cmux NEXT feed (`/nightly-next/next/`), not the
legacy NIGHTLY feed at the bare `/nightly-next/`.

## One train

`nightly-next-train.yml` mode `drive`, on `feat-cmux-next`
(`scripts/ci/nightly_next_train_drive.py`):

1. **Base**: the newest feed build with a `pass` verdict. If there is none
   yet, the base is nightly-next's head. A fix-forward passes `good_build`,
   the build the feed serves after a pull.
2. **Cars** of base..tip, first parent: one per squash-merged PR (subject
   `(#N)` and that PR's merge commit), one per direct push (repository
   activity, `before..after`), one per merge commit. The owner is the PR author
   or the push actor. When the base is a train commit, the cars it left out are
   carried in first, so a car that is still broken stays out and a fixed one
   rejoins. Label `nightly-hold` keeps a car out.
3. **Per-car guards** (design PR 3), when installed.
4. **Candidate**: the tip with the quarantined cars reverted, as a train
   commit. If a revert does not apply, the later cars touching the same files
   are pulled out with it ("quarantined with pr-N"). The candidate is pushed to
   `nightly-train/<run>/<n>`, and mode `build` runs its Release compile there
   (job `nightly-next train Release compile`).
5. **Red**: k-way bisection over prefixes of the car list (k builds in
   parallel). The first red prefix names the culprit, which is quarantined,
   and the candidate is built again. One culprit in 40 cars takes at most 3
   rounds of 4.
6. **Give up** after `NIGHTLY_NEXT_TRAIN_ROUNDS` rounds or the cap: nothing
   ships, the current nightly stays, and the summary says why.
7. **Green**: if nightly-next has not moved, it dispatches main's `nightly.yml`
   with `promote_nightly_next_sha=<train commit>`. Each newly quarantined car
   gets one comment: on its PR, or one line in the `nightly-next quarantine`
   issue for a direct push. The comment names the guard, the run and the owner,
   and says the car rejoins once a fix lands on feat-cmux-next. Retries add no
   comments.

The run summary and the `nightly-next-train-<run>` artifact (`train-result.json`)
hold the plan and every build.

### The train commit

```
nightly-next train: <tip> minus 1 car(s)

- pr-123: <title>

Nightly-Train: v1
Nightly-Train-Car: pr-123 <sha>[,<sha>...]
Nightly-Train-Revert: <sha>
```

It has two parents: the nightly-next head it was made on, then the
feat-cmux-next tip. Its tree is the tip minus the listed reverts. nightly-next
still only fast-forwards. Once a train commit has shipped, nightly-next is no
longer an ancestor of feat-cmux-next, so every later promotion is a train
commit, and with nothing quarantined its tree equals the tip.

## Promote guard: G1' and G2'

`scripts/ci/promote-nightly-next.mjs` takes the train path for a commit with
the `Nightly-Train: v1` trailer and two parents:

- **G1'**: the second parent is on feat-cmux-next, every listed revert is in
  that parent's history (a revert of any other commit would add its change
  backwards), and `verifyTrain()`
  (`nightly_next_train.py verify --fetch`, from main's checkout) rebuilds the
  tree from that parent and the `Nightly-Train-Revert:` list, then compares.
  The guard trusts no list it did not rebuild.
- **G2'**: a `nightly-next-train.yml` `workflow_dispatch` run of this
  repository on a `nightly-train/*` ref, for that exact SHA, has a green
  `nightly-next train Release compile` job.
- The first parent must be the current nightly-next.

G3/G4 (release-surface ack) are unchanged. Any other commit takes G1/G2 as
before.

## Commands

```bash
# The plan from the last good build to a commit (writes nothing):
gh workflow run nightly-next-train.yml -R manaflow-ai/cmux --ref feat-cmux-next -f mode=plan
# Local, in a checkout:
python3 scripts/ci/nightly_next_train.py base
python3 scripts/ci/nightly_next_train.py plan --tip <sha> --out train.json --summary plan.md
python3 scripts/ci/nightly_next_train.py candidate --tip <sha> --parent <nightly-next> --quarantine pr-1 --train train.json
python3 scripts/ci/nightly_next_train.py verify --commit <train commit>
```

## Not built yet

- Runtime app smoke on the candidate (window, New Tab, agent answers, no crash).
  The candidate gets only the Release compile; the signed app gets static
  artifact verification before publication, while runtime behavior stays in the
  daemon/app integration lane.
- Triage of a car that fails the same guard twice (flake list), and the daily
  digest for cars out for 3 trains.
