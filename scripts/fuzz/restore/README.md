# Restore fuzz and chaos fuzz (fuzz catalog rows f and h)

A measurer, not a gate: the fuzz owner runs it on the perf minis; it is no CI job, step or gate.

## Run

```bash
# One exclusive capture lease on a perf mini against fleet build JOB (a done `cmux-ci build cmux` job):
CAPTURE_HOST_POOL=perf-lead CAPTURE_HOST_SLOT_HOSTS="cmux19 cmux21 cmux22 cmux23 cmux24" \
CAPTURE_HOST_EXCLUDE="cmux16 cmux17" \
RJ_DRIVER=scripts/fuzz/restore/restore_fuzz.py RJ_DRIVER_FILES=scripts/cmux-next/austins-day/hog.py \
  scripts/cmux-next/restore-journey-slot.sh JOB OUT -- --seed S [--chaos none|hog|cpu|fd|fdsoft|slowdisk] [--targets app,daemon,acpmux]

# The verdict, only from the oracle's own lines:
python3 scripts/fuzz/restore/verdict.py < OUT/journey.txt

# Replay and shrink a violation (same build, same lease shape):
... restore-journey-slot.sh JOB OUT2 -- --replay OUT/violations.json
```

`restore-journey-slot.sh` does the lease, the staging, the launch and the release; `RJ_DRIVER` makes it run
`restore_fuzz.py` instead of `restore-journey.py`. Never cmux17 without the hand-over line in STATUS.

## What one iteration does

1. Fresh fuzz state: closes the `fz-*` workspaces and makes 1 to 3 new ones (each terminal prints a marker line).
2. 1 to 6 seeded actions on the tag's daemon (bundled `cmux` CLI): new workspace, split, new tab, close tab,
   close workspace, rename, write. After each answer the daemon topology is read: the last confirmed topology.
   An ok answer without its effect is a silent loss.
3. SIGKILL of one process of this slot's build, between actions or with an action in flight (0-250 ms):
   the app (the pid its socket names), its cmux-tui daemon or its acpmux. Nothing else.
4. Relaunch (the app as a person does, with its own launch variables) and wait for restore to settle.
5. Oracle: the restored topology equals the last confirmed one (an in-flight action may land or not, but an
   ok answer before the kill must land); each confirmed terminal still shows its marker; no workspace, tab or
   terminal twice; the app shows what the daemon has. An action that hangs past 10 s is a stall.

Chaos (row h) keeps the same oracle (diskfull: a bounded HFS+ image, `--disk-image-mb`, is mounted at the daemon state dir and filled to `--disk-margin-mb`; every `--disk-recover-every`th iteration runs with the filler removed and must run again; a refused create counts as degraded, with its error and whether it is typed): `hog` (the smoke gate's Austin's-day memory hog), `cpu` (one busy process
per core at user-interactive QoS), `fd` (RLIMIT_NOFILE soft and hard 256 for the relaunched app), `fdsoft` (soft 256, hard kept: the macOS GUI default), `slowdisk`
(`taskpolicy -d throttle` for the relaunched app). The limit and the throttle reach the daemon only when the
new app starts a new one.

Output: `iterations.jsonl`, `violations.json` (with the shrink attempts), `journey.log`; stdout ends with
`RESTORE-FUZZ VIOLATION ...` lines and one `RESTORE-FUZZ SUMMARY ...`.

## Tests

`--visible` samples debug.daemon and debug.surfaces every 250 ms from each kill to the settle, with the rule of restore-journey.py RecoverySampler: no blank pane, each window shows content or the connecting view, a shown terminal is connected, restoring or reconnecting (dead for at most 1 s), and both calls answer (no gap over 1 s; for an app kill, from the new app's first answer).

`python3 scripts/fuzz/restore/test_restore_fuzz.py` (oracle helpers and the verdict reader; no app).

A failed iteration (restore or judge) writes a new `evidence-NNN-<iter|shrinkK>-<seed>/` (the bundle processes, the daemon and app state, and each crash report since the run began whose process path is in this slot build).
