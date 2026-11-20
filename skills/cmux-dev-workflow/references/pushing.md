# Pushing: the cmux-next gate and retries

Moved here from the root CLAUDE.md on 2026-11-19 (docs audit); the root keeps a one-line pointer.

Before every push, run `python3 scripts/cmux-next/prepush-gate.py` (the pre-push hook runs it
too): a few seconds of static checks, no build, refusing only violations your commits add.
Swift/Rust builds and tests stay on the fleet. If it warns that this clone's installed hook copy
is not `origin/feat-cmux-next`'s, run `scripts/install-git-hooks.sh` once from a checkout at
`origin/feat-cmux-next` (a fresh worktree is one); rebase and fetch do not refresh it. What it runs and how the hooks install:
[hooks and lints](hooks-and-lints.md).

- Never `--no-verify` and never `CMUX_NEXT_CHECKS_SKIP_REASON`, unless the failure is
  in files you did not touch. Then say so in your report, naming the check and the base sha.
  CI step "Pushed commits add no violations" names every commit that adds one.

## Retry a failed push

Push with `git push -q`: without `-q`, git spends 4-14 s printing a status for
all of GitHub's ~27,600 refs. `-q` still prints errors and the hook's output. The hook ends with
`pre-push: hook times: <each phase> Ns; total Ns`, which shows where a slow push spent its time.
- `pre-push: refused in <phase>` with a check's findings: fix them and push again. Do not retry unchanged.
- The gate's `ran past its <N>s limit` (600 s, more on a loaded Mac), a failure after `pre-push: passed`
  (`[remote rejected] ... (failed)`, `RPC failed`, `remote end hung up`, a timeout), or a
  `timeout 1500` kill: retry at most 3 times. Wait 30 s before the first retry, 60 s before
  the second and 120 s before the third.
- After each try, `git ls-remote origin refs/heads/<branch>` must equal `git rev-parse HEAD`.
  If it does, the push landed: stop.
- A failed push is never a reason for `--no-verify` or the git data API. After 3 failed retries,
  report the hook-times line and the last error.
- The hook takes a turn: 2 pushes are checked at once on a Mac (`CMUX_PREPUSH_SLOTS`), and the rest
  wait (`pre-push: ... waiting for a turn`; `queue Ns` in the hook-times line). A wait is not a hang.
- On a Mac too loaded to finish the hook (CPU or RAM held above about 95%), push through an
  idle Mac: `scripts/cmux-next/push-from-host.sh --rebase <branch>` pushes `HEAD` to `origin/<branch>`
  from a push host in the fleet registry (`--which-host` prints it; `--host`, more than once for a
  fallback; `--sha`), where the same hook runs
  and refuses the same things. `--rebase` rebases there onto the branch's newest head first, which a
  busy branch needs; the pushed commits then have new ids, so fetch and rebase before more work.
