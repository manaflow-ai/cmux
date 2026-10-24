# cmux CI runner prototype

Wrap an existing trusted check command with a capacity limit, a deadline, and a
JSON execution receipt. An outside repository can install this package without
cmux, an agent account, or a service token. This R&D prototype runs on Linux and
macOS with Python 3.10 or newer.

Install a reviewed commit, replacing `FULL_COMMIT_SHA` with its 40-character SHA:

```sh
python3 -m pip install 'git+https://github.com/manaflow-ai/cmux@FULL_COMMIT_SHA#subdirectory=examples/cmux-ci-runner'
cmux-ci-run --label tests --pool "$HOME/.cache/cmux-ci/my-project" --slots 2 \
  --timeout 600 --receipt .artifacts/tests.json -- python3 -m unittest
```

For a local checkout, use `python3 -m pip install ./examples/cmux-ci-runner`, or
invoke `python3 examples/cmux-ci-runner/cmux_ci.py` with the same arguments. The
command's output streams to the caller. A successful run exits 0 and writes a
receipt with `status: "passed"`; a failed command preserves its exit code.
Archive the receipt with your CI provider's existing artifact upload mechanism.
No workflow or service is installed automatically.

Use one private `--pool` directory for all callers sharing a capacity budget on
the same host. `--slots` is fixed when that directory is first used. Concurrent
callers claim different slots using OS locks, which release when a runner exits
or crashes. When capacity is full, the runner writes `capacity_unavailable` and
exits 75 immediately; the caller decides when to retry. Different directories
or different hosts have separate capacity budgets.

The timeout covers execution after capacity is claimed. Timeout exits 124;
cancellation exits 128 plus the signal number; setup errors exit 125. The runner
sends SIGTERM, allows two seconds to exit, and then sends SIGKILL to the command's
process group. It also stops remaining group members after a normal command
exit, so check commands must not leave dev servers running. Children that create
new sessions escape this cleanup boundary; run untrusted code in a container or
VM with its own lifecycle. This runner executes with the caller's permissions.

Receipts contain a run ID, label, UTC timestamps, slot, queue/run milliseconds,
status, and exit code. They omit argv, environment, and command output; use a
non-secret label. `--rate-usd 0.50` adds `estimated_cost_usd` for execution time
only. It is a supplied rate estimate, not a billing record; queue time, idle
capacity, disks, network, and provider billing minimums are excluded. Receipt
files are written atomically with mode 0600.

Try the behavior tests:

```sh
python3 -m unittest discover -s examples/cmux-ci-runner -p 'test_*.py' -v
```

This is an opt-in packaging prototype. Remote allocation, remote admission,
GitHub check publishing, authentication, and payment collection are future
integration points. A caller may wrap its existing SSH/container command, but
this package's capacity claim remains on the caller's host.
