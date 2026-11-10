#!/usr/bin/env python3
"""scripts/verify-cmux-tui-hosted.sh never cancels its hosted run when the wait ends.

Run 42503576472 (2026-11-08) was cancelled by its own wrapper 5 minutes into a
6-hour wait: ci-owned-pool-rescue cancelled attempt 1 and re-ran it, glaeda-gh
wait ruled on the cancelled attempt, and the wrapper read the re-run as "queued"
and ran `gh run cancel`. This drives the real script against stub gh, glaeda-gh
and git ls-remote (no network) and checks what it does to the run:

- at the deadline it does not cancel, prints how to keep waiting, and exits 3;
- a waiter that returns before the run is done is started again;
- a run cancelled by someone else and re-run within the rescue window is followed,
  and a deadline inside that window is "still running", not a failure;
- glaeda-gh down (exit 3) gives one round of gh run watch, then glaeda-gh again;
- rounds are spaced, so a waiter that returns at once does not spin on the API;
- --cancel-on-timeout cancels at the deadline;
- Ctrl-C (SIGINT to the process group) cancels; SIGTERM or SIGHUP to the script does not;
- a dispatch that gets HTTP 5xx is tried again (3 tries), a run GitHub created anyway is adopted,
  and when every try fails the script says no run was created;
- a 404 or 500 on the first read of the new run is not a failure: the script names the run,
  waits on it with glaeda-gh, and checks its revision before it accepts an artifact;
- only a 404, a 5xx or a network drop on that read is waited out; a 401, a 403 or a broken gh
  exits 1 at once;
- exit 3 with a revision that is not confirmed does not tell the operator to download artifacts;
- one open run per commit, mode and filter: while a run this script dispatched for the same
  commit and filter is still open, it does not dispatch, names that run and exits 4; an open
  run of another filter or another commit, or a finished run, does not stop a dispatch.
  About 37 cmux-tui runs queued on 2026-11-09, often several for one commit.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify-cmux-tui-hosted.sh"
RUN_ID = "4242"

GH_STUB = r"""#!/usr/bin/env bash
echo "gh $*" >> "$STUB_DIR/calls.log"
case "$*" in
  api*)
    # FAKE_DISPATCH_FAILS: how many dispatches answer HTTP 502 (FAKE_DISPATCH_CODE) first.
    n=$(cat "$STUB_DIR/dispatches" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$STUB_DIR/dispatches"
    if (( n < ${FAKE_DISPATCH_FAILS:-0} )); then
      echo "gh: Server Error (HTTP ${FAKE_DISPATCH_CODE:-502})" >&2
      exit 1
    fi
    echo __RUN_ID__ ;;
  "run list"*--commit*)
    # The open-run lookup: one run per line, "id<TAB>status<TAB>title<TAB>url" (the
    # script's --jq asks for @tsv). The test writes the lines to $STUB_DIR/open-runs.
    if [[ "${FAKE_OPEN_LIST_FAILS:-0}" == 1 ]]; then echo "gh: Server Error (HTTP 503)" >&2; exit 1; fi
    cat "$STUB_DIR/open-runs" 2>/dev/null || true ;;
  "run list"*)
    if [[ "${FAKE_LIST_FAILS:-0}" == 1 ]]; then echo "gh: Server Error (HTTP 503)" >&2; exit 1; fi
    # FAKE_LIST_FINDS=1: GitHub created the run despite the error, and lists it.
    if [[ "${FAKE_LIST_FINDS:-0}" == 1 ]]; then echo __RUN_ID__; fi ;;
  *headSha*)
    # FAKE_IDENTITY_FAILS: how many identity reads fail first (FAKE_IDENTITY_CODE, default 404:
    # GitHub answers 404 or 500 for a few seconds after it creates a run). FAKE_IDENTITY_SHA
    # answers another commit (a run of another revision).
    n=$(cat "$STUB_DIR/identity-reads" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$STUB_DIR/identity-reads"
    if (( n < ${FAKE_IDENTITY_FAILS:-0} )); then
      case "${FAKE_IDENTITY_CODE:-404}" in
        broken) echo "gh: unknown flag: --json" >&2 ;;
        network) printf 'error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n' >&2 ;;
        *) echo "failed to get run: HTTP ${FAKE_IDENTITY_CODE:-404}: Not Found (https://api.github.com/repos/manaflow-ai/cmux/actions/runs/__RUN_ID__)" >&2 ;;
      esac
      exit 1
    fi
    printf '%s\t%s\tworkflow_dispatch\n' "${FAKE_IDENTITY_SHA:-$(cat "$STUB_DIR/head")}" "$(cat "$STUB_DIR/branch")" ;;
  *status,conclusion*)
    n=$(cat "$STUB_DIR/views" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$STUB_DIR/views"
    IFS=';' read -ra states <<< "$FAKE_STATES"
    (( n >= ${#states[@]} )) && n=$((${#states[@]} - 1))
    state="${states[$n]}"
    # Answer the way the --jq the script passed would: @tsv is tab separated.
    if [[ "$*" == *'@tsv'* ]]; then printf '%s\n' "$state" | tr '|' '\t'; else printf '%s\n' "$state"; fi ;;
  "run cancel"*) exit 0 ;;
  "run watch"*) exit 0 ;;
  "run download"*) exit 9 ;;
  *log-failed*) echo "(failed log)" ;;
esac
""".replace("__RUN_ID__", RUN_ID)

GLAEDA_STUB = r"""#!/usr/bin/env bash
# Like glaeda-gh wait: exit 2 once --timeout passes (FAKE_WAITER_SLEEP is how
# long the run takes to look decided), else FAKE_WAITER_STATUS (default 1).
echo "glaeda-gh $*" >> "$STUB_DIR/calls.log"
timeout=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--timeout" ]]; then timeout="$2"; fi
  shift
done
wait_for="${FAKE_WAITER_SLEEP:-0}"
if [[ -n "$timeout" && "$wait_for" -ge "$timeout" ]]; then
  sleep "$timeout"
  echo "run: timeout (stub)"
  exit 2
fi
if [[ "$wait_for" -gt 0 ]]; then sleep "$wait_for"; fi
echo "run: FAILURE (stub)"
exit "${FAKE_WAITER_STATUS:-1}"
"""

GIT_STUB = r"""#!/usr/bin/env bash
if [[ " $* " == *" ls-remote "* ]]; then
  printf '%s\trefs/heads/%s\n' "$(cat "$STUB_DIR/head")" "$(cat "$STUB_DIR/branch")"
  exit 0
fi
exec "$REAL_GIT" "$@"
"""


class Sandbox:
    """A clean checkout holding the script, with stubs first on PATH."""

    def __init__(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="verify-hosted-test."))
        self.groups: list[int] = []
        self.repo = self.dir / "repo"
        self.bin = self.dir / "bin"
        (self.repo / "scripts").mkdir(parents=True)
        self.bin.mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts" / SCRIPT.name)
        real_git = shutil.which("git")
        assert real_git, "git is required"
        self.env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.dir),
            "TMPDIR": str(self.dir),
            "STUB_DIR": str(self.dir),
            "REAL_GIT": real_git,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        }
        for name, body in (("gh", GH_STUB), ("glaeda-gh", GLAEDA_STUB), ("git", GIT_STUB)):
            path = self.bin / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        git = [real_git, "-C", str(self.repo)]
        subprocess.run(git + ["init", "-q", "-b", "verify-test"], check=True, env=self.env)
        subprocess.run(git + ["add", "-A"], check=True, env=self.env)
        subprocess.run(git + ["commit", "-q", "-m", "fixture"], check=True, env=self.env)
        subprocess.run(git + ["remote", "add", "origin", "https://github.com/manaflow-ai/cmux"], check=True, env=self.env)
        head = subprocess.run(git + ["rev-parse", "HEAD"], check=True, env=self.env,
                              capture_output=True, text=True).stdout.strip()
        (self.dir / "head").write_text(head, encoding="utf-8")
        (self.dir / "branch").write_text("verify-test", encoding="utf-8")

    def start(self, args: list[str], **env: str) -> subprocess.Popen[str]:
        # Fast defaults a case may override.
        full_env = {**self.env, "CMUX_TUI_HOSTED_ROUND_SECONDS": "1", "CMUX_TUI_HOSTED_DISPATCH_BACKOFF_SECONDS": "1",
                    "CMUX_TUI_HOSTED_RESCUE_WINDOW_SECONDS": "5", **env}
        process = subprocess.Popen(["bash", f"scripts/{SCRIPT.name}", *args], cwd=self.repo, env=full_env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                   start_new_session=True)
        self.groups.append(process.pid)
        return process

    def run(self, args: list[str], **env: str) -> tuple[int, str]:
        process = self.start(args, **env)
        try:
            output, _ = process.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
            return -1, output + "\n(test: the script did not end within 90 s)"
        return process.returncode, output

    def calls(self) -> list[str]:
        log = self.dir / "calls.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def count(self, prefix: str) -> int:
        return sum(1 for line in self.calls() if line.startswith(prefix))

    def head(self) -> str:
        return (self.dir / "head").read_text(encoding="utf-8").strip()

    def dispatched_request_id(self, args: list[str]) -> str:
        """Run the script once and return the request_id it dispatched, then forget the calls."""
        self.run(args, FAKE_STATES="completed|success|1", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
        found = [part.split("=", 1)[1] for line in self.calls() for part in line.split()
                 if part.startswith("inputs[request_id]=")]
        assert len(found) == 1, self.calls()
        for name in ("calls.log", "dispatches", "views"):
            (self.dir / name).unlink(missing_ok=True)
        return found[0]

    def open_runs(self, *runs: tuple[str, str, str]) -> None:
        """Runs of this commit that the run list shows: (id, status, title) each."""
        lines = [f"{run_id}\t{status}\t{title}\thttps://github.com/manaflow-ai/cmux/actions/runs/{run_id}\n"
                 for run_id, status, title in runs]
        (self.dir / "open-runs").write_text("".join(lines), encoding="utf-8")

    def close(self) -> None:
        for group in self.groups:  # stub sleeps a killed waiter left behind
            try:
                os.killpg(group, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        shutil.rmtree(self.dir, ignore_errors=True)


def check(failures: list[str], name: str, ok: bool, box: Sandbox, output: str) -> None:
    if not ok:
        failures.append(f"{name}\n--- output ---\n{output}\n--- calls ---\n" + "\n".join(box.calls()))


def scenario(failures: list[str], name: str, test) -> None:
    box = Sandbox()
    try:
        test(failures, name, box)
    finally:
        box.close()


def dispatch_server_error_is_retried(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_DISPATCH_FAILS="2",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 3 and box.count("gh run download") >= 1
          and "HTTP 502" in out, box, out)


def dispatch_server_errors_give_up_and_say_no_run(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_DISPATCH_FAILS="9",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 1 and box.count("gh api -X POST") == 3 and "no run was created" in out
          and box.count("glaeda-gh wait run") == 0, box, out)


def dispatch_error_with_a_created_run_adopts_it(failures: list[str], name: str, box: Sandbox) -> None:
    # A 5xx can come after GitHub created the run: it is found by its request id, never dispatched twice.
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_DISPATCH_FAILS="1", FAKE_LIST_FINDS="1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 1 and box.count("gh run download") >= 1, box, out)


def dispatch_lookup_failure_does_not_dispatch_again(failures: list[str], name: str, box: Sandbox) -> None:
    # The run list fails in the same incident: the run may exist, so no second dispatch, and say how to check.
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_DISPATCH_FAILS="9", FAKE_LIST_FAILS="1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 1 and box.count("gh api -X POST") == 1 and "gh run list --repo" in out
          and "HTTP 503" in out, box, out)


def dispatch_client_error_is_not_retried(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_DISPATCH_FAILS="9",
                        FAKE_DISPATCH_CODE="422", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 1 and box.count("gh api -X POST") == 1 and "HTTP 422" in out, box, out)


def deadline_does_not_cancel(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="queued||1", FAKE_WAITER_SLEEP="30",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="3")
    check(failures, name, code == 3 and box.count("gh run cancel") == 0
          and f"glaeda-gh wait run manaflow-ai/cmux/{RUN_ID}" in out, box, out)


def early_waiter_return_waits_again(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="queued||1;in_progress||1;completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh run cancel") == 0 and box.count("glaeda-gh wait run") == 3
          and box.count("gh run download") >= 1 and "exited 1" in out, box, out)


def rescue_rerun_is_followed(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|cancelled|1;queued||2;completed|success|2",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh run cancel") == 0 and box.count("glaeda-gh wait run") == 3
          and "waiting up to 5s for a re-run" in out and box.count("gh run download") >= 1, box, out)


def deadline_inside_rescue_window_is_still_running(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|cancelled|1", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="3",
                        CMUX_TUI_HOSTED_RESCUE_WINDOW_SECONDS="60")
    check(failures, name, code == 3 and box.count("gh run cancel") == 0
          and box.count("gh run download") == 0, box, out)


def daemon_down_falls_back_for_one_round(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="queued||1;queued||1;completed|success|1", FAKE_WAITER_STATUS="3",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh run cancel") == 0 and box.count("gh run watch") == 1
          and box.count("glaeda-gh wait run") == 2 and box.count("gh run download") >= 1, box, out)


def cancelled_without_rerun_fails(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|cancelled|1", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    # Rounds are CMUX_TUI_HOSTED_ROUND_SECONDS (1 s) apart over the 5 s window:
    # a dozen reads at most, not a spin on the API.
    views = box.count(f"gh run view --repo manaflow-ai/cmux {RUN_ID} --json status")
    check(failures, name, code == 1 and box.count("gh run cancel") == 0
          and box.count("gh run download") == 0 and 2 <= views <= 12, box, out)


def cancel_on_timeout_flag_cancels(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--cancel-on-timeout", "--full"], FAKE_STATES="queued||1", FAKE_WAITER_SLEEP="30",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="3")
    check(failures, name, code == 1 and box.count("gh run cancel") == 1, box, out)


def open_run_of_same_commit_and_filter_refuses(status: str):
    def test(failures: list[str], name: str, box: Sandbox) -> None:
        request_id = box.dispatched_request_id(["--filter", "alpha_test"])
        box.open_runs(("9001", status, f"cmux-tui focused {request_id} @ {box.head()}"))
        code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                            CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
        check(failures, name, code == 4 and box.count("gh api -X POST") == 0
              and "https://github.com/manaflow-ai/cmux/actions/runs/9001" in out
              and box.count("glaeda-gh wait run") == 0, box, out)
    return test


def open_full_run_of_same_commit_refuses(failures: list[str], name: str, box: Sandbox) -> None:
    request_id = box.dispatched_request_id(["--full"])
    box.open_runs(("9002", "queued", f"cmux-tui full {request_id} @ {box.head()}"))
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 4 and box.count("gh api -X POST") == 0
          and "https://github.com/manaflow-ai/cmux/actions/runs/9002" in out, box, out)


def open_run_of_another_filter_dispatches(failures: list[str], name: str, box: Sandbox) -> None:
    other = box.dispatched_request_id(["--filter", "beta_test"])
    box.open_runs(("9003", "queued", f"cmux-tui focused {other} @ {box.head()}"))
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 1 and "runs/9003" not in out, box, out)


def open_run_of_another_mode_dispatches(failures: list[str], name: str, box: Sandbox) -> None:
    other = box.dispatched_request_id(["--full"])
    box.open_runs(("9004", "queued", f"cmux-tui full {other} @ {box.head()}"))
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 1, box, out)


def open_run_of_another_commit_dispatches(failures: list[str], name: str, box: Sandbox) -> None:
    request_id = box.dispatched_request_id(["--filter", "alpha_test"])
    other_sha = "0" * 40 if box.head() != "0" * 40 else "1" * 40
    box.open_runs(("9005", "queued", f"cmux-tui focused {request_id} @ {other_sha}"))
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 1, box, out)


def finished_run_of_same_commit_and_filter_dispatches(failures: list[str], name: str, box: Sandbox) -> None:
    request_id = box.dispatched_request_id(["--filter", "alpha_test"])
    box.open_runs(("9006", "completed", f"cmux-tui focused {request_id} @ {box.head()}"))
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 1, box, out)


def open_run_lookup_failure_still_dispatches(failures: list[str], name: str, box: Sandbox) -> None:
    # The lookup only saves Mac time; a failed list must not block verification.
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1", FAKE_OPEN_LIST_FAILS="1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, box.count("gh api -X POST") == 1, box, out)


def first_run_read_failure_waits_on_the_run(code_name: str):
    """Run 42688604218 (2026-11-09): the dispatch created the run, the first read of it
    answered HTTP 404, and the script exited 1 with the run still going. Run 42688525295
    (#39820) got HTTP 500 the same way. The script now names the run, hands the wait to
    glaeda-gh wait run, and checks the run's revision once it can read it."""
    def test(failures: list[str], name: str, box: Sandbox) -> None:
        code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_IDENTITY_FAILS="1",
                            FAKE_IDENTITY_CODE=code_name, CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
        check(failures, name, box.count("gh api -X POST") == 1
              and box.count(f"glaeda-gh wait run manaflow-ai/cmux/{RUN_ID}") >= 1
              and box.count("gh run download") >= 1 and box.count("gh run cancel") == 0
              and f"actions/runs/{RUN_ID}" in out, box, out)
    return test


def transient_first_read_exit_code(code_name: str):
    """A 404 or a 5xx on the first read, then a green run: the script waits and exits 0."""
    def test(failures: list[str], name: str, box: Sandbox) -> None:
        code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_IDENTITY_FAILS="1",
                            FAKE_IDENTITY_CODE=code_name, CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
        # gh run download exits 9 in the stub, so a waited run reaches the download and ends there.
        check(failures, name, box.count("glaeda-gh wait run") >= 1 and box.count("gh run download") >= 1
              and "could not show it yet" in out, box, out)
    return test


def permanent_first_read_error_exits_at_once(code_name: str):
    """A 401, a 403 or a broken gh will not heal by waiting: exit 1 at once, without a wait.

    The run exists, so the error names it; the script does not cancel it."""
    def test(failures: list[str], name: str, box: Sandbox) -> None:
        code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_IDENTITY_FAILS="99",
                            FAKE_IDENTITY_CODE=code_name, CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
        check(failures, name, code == 1 and box.count("glaeda-gh wait run") == 0
              and box.count("gh run watch") == 0 and box.count("gh run cancel") == 0
              and f"actions/runs/{RUN_ID}" in out, box, out)
    return test


def deadline_with_an_unconfirmed_revision_names_no_download(failures: list[str], name: str, box: Sandbox) -> None:
    """Exit 3 while the run's revision is not confirmed: say so, and do not tell the
    operator to download artifacts of a run that may be another revision."""
    code, out = box.run(["--full"], FAKE_STATES="queued||1", FAKE_WAITER_SLEEP="30", FAKE_IDENTITY_FAILS="99",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="3")
    check(failures, name, code == 3 and box.count("gh run cancel") == 0
          and f"glaeda-gh wait run manaflow-ai/cmux/{RUN_ID}" in out
          and "gh run download" not in out and "revision is not confirmed" in out, box, out)


def deadline_with_a_confirmed_revision_still_names_the_download(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="queued||1", FAKE_WAITER_SLEEP="30",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="3")
    check(failures, name, code == 3 and "gh run download" in out, box, out)


def cancel_on_timeout_with_an_unconfirmed_revision(failures: list[str], name: str, box: Sandbox) -> None:
    """--cancel-on-timeout cancels the run it dispatched (the dispatch named it) and exits 1,
    also while the first read has not confirmed its revision."""
    code, out = box.run(["--cancel-on-timeout", "--full"], FAKE_STATES="queued||1", FAKE_WAITER_SLEEP="30",
                        FAKE_IDENTITY_FAILS="99", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="3")
    check(failures, name, code == 1 and box.count("gh run cancel") == 1 and "gh run download" not in out, box, out)


def unreadable_run_is_refused_before_download(failures: list[str], name: str, box: Sandbox) -> None:
    # The revision is never confirmed: no artifact from that run is accepted.
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_IDENTITY_FAILS="99",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 1 and box.count("glaeda-gh wait run") >= 1
          and box.count("gh run download") == 0 and box.count("gh run cancel") == 0
          and f"actions/runs/{RUN_ID}" in out, box, out)


def late_read_of_another_revision_is_refused(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--full"], FAKE_STATES="completed|success|1", FAKE_IDENTITY_FAILS="1",
                        FAKE_IDENTITY_SHA="f" * 40, CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 1 and box.count("gh run download") == 0
          and "is not this revision" in out, box, out)


def signal_case(signum: int, whole_group: bool, want_cancels: int, want_code: int):
    def test(failures: list[str], name: str, box: Sandbox) -> None:
        process = box.start(["--full"], FAKE_STATES="queued||1", FAKE_WAITER_SLEEP="60",
                            CMUX_TUI_HOSTED_TIMEOUT_SECONDS="120")
        deadline = time.monotonic() + 30
        while box.count("glaeda-gh wait run") == 0 and time.monotonic() < deadline:
            if process.poll() is not None:
                break
            time.sleep(0.1)  # the waiter stub has not started yet; bounded by the deadline above
        if whole_group:
            os.killpg(process.pid, signum)  # what Ctrl-C does: the whole foreground group
        else:
            os.kill(process.pid, signum)  # what a harness that ends the command does
        try:
            output, _ = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        check(failures, name, process.returncode == want_code and box.count("gh run cancel") == want_cancels,
              box, output)
    return test


def main() -> int:
    if not shutil.which("bash") or not shutil.which("git"):
        print("bash and git are required", file=sys.stderr)
        return 1
    failures: list[str] = []
    for name, test in [
        ("a dispatch that gets HTTP 5xx is tried again", dispatch_server_error_is_retried),
        ("three 5xx dispatches give up and say no run was created", dispatch_server_errors_give_up_and_say_no_run),
        ("a 5xx dispatch whose run GitHub did create is adopted, not dispatched twice",
         dispatch_error_with_a_created_run_adopts_it),
        ("a failed run lookup after a 5xx does not dispatch again", dispatch_lookup_failure_does_not_dispatch_again),
        ("a 4xx dispatch is not tried again", dispatch_client_error_is_not_retried),
        ("at the deadline the run is not cancelled and the script exits 3", deadline_does_not_cancel),
        ("a waiter that returns before the run is done is started again", early_waiter_return_waits_again),
        ("a run cancelled by the CI rescue and re-run is followed", rescue_rerun_is_followed),
        ("a run cancelled by someone else and not re-run fails without a cancel", cancelled_without_rerun_fails),
        ("a deadline inside the rescue window is still running (exit 3)", deadline_inside_rescue_window_is_still_running),
        ("glaeda-gh down: one round of gh run watch, then glaeda-gh again", daemon_down_falls_back_for_one_round),
        ("--cancel-on-timeout cancels at the deadline", cancel_on_timeout_flag_cancels),
        ("Ctrl-C cancels the run", signal_case(signal.SIGINT, True, 1, 130)),
        ("SIGTERM does not cancel the run", signal_case(signal.SIGTERM, False, 0, 143)),
        ("SIGHUP does not cancel the run", signal_case(signal.SIGHUP, False, 0, 129)),
        ("a queued run of the same commit and filter: no dispatch, exit 4",
         open_run_of_same_commit_and_filter_refuses("queued")),
        ("an in-progress run of the same commit and filter: no dispatch, exit 4",
         open_run_of_same_commit_and_filter_refuses("in_progress")),
        ("a waiting run of the same commit and filter: no dispatch, exit 4",
         open_run_of_same_commit_and_filter_refuses("waiting")),
        ("an open full run of the same commit: no second full dispatch, exit 4", open_full_run_of_same_commit_refuses),
        ("an open run of another filter does not stop a dispatch", open_run_of_another_filter_dispatches),
        ("an open full run does not stop a focused dispatch", open_run_of_another_mode_dispatches),
        ("an open run of another commit does not stop a dispatch", open_run_of_another_commit_dispatches),
        ("a finished run of the same commit and filter does not stop a dispatch",
         finished_run_of_same_commit_and_filter_dispatches),
        ("a failed open-run lookup still dispatches", open_run_lookup_failure_still_dispatches),
        ("a 404 on the first read of the new run: wait on it, do not exit 1",
         first_run_read_failure_waits_on_the_run("404")),
        ("a 500 on the first read of the new run: wait on it, do not exit 1",
         first_run_read_failure_waits_on_the_run("500")),
        ("a run whose revision is never read is refused before download", unreadable_run_is_refused_before_download),
        ("a 404 first read, then a green run: the script waits and goes on", transient_first_read_exit_code("404")),
        ("a 502 first read, then a green run: the script waits and goes on", transient_first_read_exit_code("502")),
        ("a network drop (no HTTP code) on the first read, then a green run: the script waits and goes on",
         transient_first_read_exit_code("network")),
        ("a 401 first read exits 1 at once, without a wait", permanent_first_read_error_exits_at_once("401")),
        ("a 403 first read exits 1 at once, without a wait", permanent_first_read_error_exits_at_once("403")),
        ("a broken gh on the first read exits 1 at once, without a wait", permanent_first_read_error_exits_at_once("broken")),
        ("exit 3 with an unconfirmed revision names no gh run download",
         deadline_with_an_unconfirmed_revision_names_no_download),
        ("exit 3 with a confirmed revision still names gh run download",
         deadline_with_a_confirmed_revision_still_names_the_download),
        ("--cancel-on-timeout with an unconfirmed revision cancels and exits 1",
         cancel_on_timeout_with_an_unconfirmed_revision),
        ("a late read that shows another revision is refused", late_read_of_another_revision_is_refused),
    ]:
        scenario(failures, name, test)
    if failures:
        print("\n\n".join(f"FAIL: {f}" for f in failures), file=sys.stderr)
        return 1
    print("ok: verify-cmux-tui-hosted.sh leaves its run alone unless Ctrl-C or --cancel-on-timeout says otherwise,"
          " and keeps one open run per commit, mode and filter")
    return 0


if __name__ == "__main__":
    sys.exit(main())
