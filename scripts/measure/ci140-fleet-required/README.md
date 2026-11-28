# ci140-fleet-required

Why cmux-required-checks costs about 29 fleet machine-min per merged PR (goal ci-min-per-pr-140).

```sh
python3 fleet_required.py --jobs jobs.jsonl.gz --since 2026-11-26T22:00Z --until 2026-11-27T05:00Z \
  --merged 783 --logs logs/
```

`jobs.jsonl.gz` is the controller's `/v1/jobs?all=1` rows, one per line; `logs/` holds `<job id>.log` from
`/v1/jobs/log?id=ID` for a sample of clippy-changed steps.

## 2026-11-26T22Z to 2026-11-27T05Z (2,260 jobs, 783 merged PRs, 29.0 min per merged PR)

| rank | bucket | runs | min per merged PR | avg min |
|---:|---|---:|---:|---:|
| 1 | clippy-changed, pool VM, done | 587 | 10.0 | 13.4 |
| 2 | clippy-changed, overflow, done | 401 | 7.3 | 14.3 |
| 3 | clippy-changed, pool VM, failed | 228 | 3.7 | 12.6 |
| 4 | react-doctor, all pools | 786 | 3.1 | 3.1 |
| 5 | clippy-changed, overflow, failed | 165 | 2.7 | 12.6 |
| 6 | clippy-changed, fss (all states) | 34 | 1.7 | 38 |
| - | of which runs over 60 min | | 1.2 | |
| - | of which cancelled | | 0.7 | |
| - | same (mode, tree) after a green run | | 0.1 | |

Clippy-changed runs per PR: 1 for 326 PRs, 2 for 119, 3 for 66, 4 for 49, 5 for 35, 6+ for 48 (1.94 heads per PR).
Repeats on an already-green tree are negligible; the cost is per step, not per repeat.

## Why a clippy-changed step costs 13 to 14 minutes

From 20 sampled step logs: median clippy `--all-targets` 500 s, panic ratchet on HEAD 274 s, panic ratchet on the
base 184 s.

- **A. Cold cargo target.** Pool VMs are ephemeral: 1,366 VMs ran 3,466 clippy-changed steps, and 74.8% were the
  first or second on their VM. Each of a VM's two warm cargo slots starts empty, so these steps can't reuse a kept
  target (17 of 20 sampled logs say `created`). Overflow restores no target for path crates. sccache serves
  only non-incremental lib units, so test and bin units, links and build scripts still build cold.
- **B. The base ratchet pass runs on every step.** `feat-cmux-next` is itself over the panic ratchet baseline (about
  30 base-red rows, many "new crate (must be 0)"), so every HEAD fails the strict judge and
  `cmux-tui-clippy-changed.py` checks out the base and runs the ratchet again (18 of 18 sampled steps).

## Proposals (not landed here: each needs a cut, a flip or a trust decision)

- **P1, about 5 min per merged PR:** clear the base ratchet red at its cause (fix the roughly 350 deny hits in code),
  so the strict judge passes on HEAD and the base pass never runs. Raising the baseline instead would be a flip.
- **P2, about 7 min per merged PR:** seed the warm cargo slot on new pool VMs from a target built by a trusted
  base-push writer (about 5 GiB since `CARGO_INCREMENTAL=0`), marked fresh like `cargo_restore_fresh.py`. A new
  shared trusted store is a trust-policy change, so it goes to Leo's TBD list first.
