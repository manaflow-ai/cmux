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
- one open run per commit, mode and filter: while a run this script dispatched for the same
  commit and filter is still open, it does not dispatch, names that run and exits 4; an open
  run of another filter or another commit, or a finished run, does not stop a dispatch.
  About 37 cmux-tui runs queued on 2026-11-09, often several for one commit.
- --commit <sha> verifies a pushed commit that is not the branch head (the red commit of a
  two-commit fix): it dispatches cmux-tui.yml on the trusted integration branch
  (feat-cmux-next), so that branch's workflow file runs, with inputs.commit = the sha and
  inputs.source_branch = the caller's pushed branch. A sha that is not on the pushed branch is
  refused before any dispatch, and the one-open-run rule finds a --commit run by its title even
  though its head sha is the trusted branch's. Without --commit the script is unchanged: it
  still refuses a local HEAD that is not the pushed branch head.
- the workflow's validate-inputs step (run here from cmux-tui.yml with a stub gh) accepts a
  commit other than the workflow revision only on feat-cmux-next or main, and only when
  source_branch is a branch of this repository whose head contains the commit (compare API:
  ahead or identical, behind_by 0), so a fork object served by sha is refused.
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
  "run list"*databaseId,status,displayTitle,url*)
    # The open-run lookup: one run per line, "id<TAB>status<TAB>title<TAB>url" (the
    # script's --jq asks for @tsv). Runs whose head is the commit (--commit) come from
    # $STUB_DIR/open-runs; runs on the trusted branch (a --commit dispatch, whose head is
    # that branch's) come from $STUB_DIR/open-runs-trusted.
    if [[ "${FAKE_OPEN_LIST_FAILS:-0}" == 1 ]]; then echo "gh: Server Error (HTTP 503)" >&2; exit 1; fi
    if [[ "$*" == *--commit* ]]; then
      cat "$STUB_DIR/open-runs" 2>/dev/null || true
    elif [[ "$*" == *"--branch feat-cmux-next"* ]]; then
      cat "$STUB_DIR/open-runs-trusted" 2>/dev/null || true
    fi ;;
  "run list"*)
    if [[ "${FAKE_LIST_FAILS:-0}" == 1 ]]; then echo "gh: Server Error (HTTP 503)" >&2; exit 1; fi
    # FAKE_LIST_FINDS=1: GitHub created the run despite the error, and lists it.
    if [[ "${FAKE_LIST_FINDS:-0}" == 1 ]]; then echo __RUN_ID__; fi ;;
  *headSha*) printf '%s\t%s\tworkflow_dispatch\n' "${FAKE_RUN_HEAD:-$(cat "$STUB_DIR/head")}" \
      "${FAKE_RUN_BRANCH:-$(cat "$STUB_DIR/branch")}" ;;
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

    def commit(self, message: str) -> str:
        """Add an empty local commit (not pushed: the remote head stays as it is) and return its sha."""
        git = [self.env["REAL_GIT"], "-C", str(self.repo)]
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", message], check=True, env=self.env)
        return subprocess.run(git + ["rev-parse", "HEAD"], check=True, env=self.env,
                              capture_output=True, text=True).stdout.strip()

    def push(self, sha: str) -> None:
        """Make git ls-remote report `sha` as the head of the pushed branch."""
        (self.dir / "head").write_text(sha, encoding="utf-8")

    def dispatches(self) -> list[str]:
        return [line for line in self.calls() if line.startswith("gh api -X POST")]

    def dispatched_request_id(self, args: list[str], **env: str) -> str:
        """Run the script once and return the request_id it dispatched, then forget the calls."""
        self.run(args, FAKE_STATES="completed|success|1", CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **env)
        found = [part.split("=", 1)[1] for line in self.calls() for part in line.split()
                 if part.startswith("inputs[request_id]=")]
        assert len(found) == 1, self.calls()
        for name in ("calls.log", "dispatches", "views"):
            (self.dir / name).unlink(missing_ok=True)
        return found[0]

    def open_runs(self, *runs: tuple[str, str, str], trusted: bool = False) -> None:
        """Runs the run list shows: (id, status, title) each.

        trusted=False: runs whose head is this commit (a dispatch on the commit's own branch).
        trusted=True: runs on feat-cmux-next (a --commit dispatch, whose head is feat-cmux-next's).
        """
        lines = [f"{run_id}\t{status}\t{title}\thttps://github.com/manaflow-ai/cmux/actions/runs/{run_id}\n"
                 for run_id, status, title in runs]
        name = "open-runs-trusted" if trusted else "open-runs"
        (self.dir / name).write_text("".join(lines), encoding="utf-8")

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


# --commit: a run for a pushed commit that is not the branch head (the red commit of a fix).
TRUSTED_REF = "feat-cmux-next"
# The head sha GitHub gives a run dispatched on the trusted branch: that branch's, not the tested commit's.
TRUSTED_HEAD = "f" * 40
COMMIT_PATH_ENV = {"FAKE_RUN_BRANCH": TRUSTED_REF, "FAKE_RUN_HEAD": TRUSTED_HEAD}


def commit_path_dispatches_non_head_on_trusted_ref(failures: list[str], name: str, box: Sandbox) -> None:
    red = box.head()
    fix = box.commit("fix")
    box.push(fix)  # the branch head on origin is the fix; the red commit is HEAD~1
    code, out = box.run(["--commit", red, "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    posts = box.dispatches()
    post = posts[0] if len(posts) == 1 else ""
    check(failures, name, len(posts) == 1
          and f" -f ref={TRUSTED_REF} " in post
          and f" -f inputs[commit]={red} " in post
          and " -f inputs[source_branch]=verify-test " in post
          and f" -f inputs[request_id]={red[:12]}-f" in post
          and " -f inputs[mode]=focused " in post
          and "local HEAD" not in out
          and "is not this revision" not in out
          and box.count("glaeda-gh wait run") >= 1 and box.count("gh run download") >= 1, box, out)


def commit_path_accepts_the_pushed_head(failures: list[str], name: str, box: Sandbox) -> None:
    # --commit also takes the branch head itself, and full mode.
    head = box.head()
    code, out = box.run(["--commit", head, "--full"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    posts = box.dispatches()
    check(failures, name, len(posts) == 1 and f" -f ref={TRUSTED_REF} " in posts[0]
          and f" -f inputs[commit]={head} " in posts[0] and box.count("gh run download") >= 1, box, out)


def commit_path_refuses_an_unpushed_commit(failures: list[str], name: str, box: Sandbox) -> None:
    unpushed = box.commit("not pushed")  # local only: origin's branch head is still the fixture commit
    code, out = box.run(["--commit", unpushed, "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    check(failures, name, code == 1 and not box.dispatches() and unpushed in out
          and box.count("glaeda-gh wait run") == 0, box, out)


def commit_path_refuses_an_unknown_commit(failures: list[str], name: str, box: Sandbox) -> None:
    # A sha this clone does not have (for example a fork's object): not on the pushed branch.
    unknown = "e" * 40
    code, out = box.run(["--commit", unknown, "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    check(failures, name, code == 1 and not box.dispatches() and unknown in out, box, out)


def commit_path_refuses_a_short_sha(failures: list[str], name: str, box: Sandbox) -> None:
    code, out = box.run(["--commit", box.head()[:12], "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    check(failures, name, code == 2 and not box.dispatches(), box, out)


def commit_path_refuses_a_second_open_run(failures: list[str], name: str, box: Sandbox) -> None:
    red = box.head()
    box.push(box.commit("fix"))
    request_id = box.dispatched_request_id(["--commit", red, "--filter", "alpha_test"], **COMMIT_PATH_ENV)
    # The open run is on the trusted branch and its head is that branch's: only its title names the commit.
    box.open_runs(("9007", "in_progress", f"cmux-tui focused {request_id} @ {red}"), trusted=True)
    code, out = box.run(["--commit", red, "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    check(failures, name, code == 4 and not box.dispatches()
          and "https://github.com/manaflow-ai/cmux/actions/runs/9007" in out
          and box.count("glaeda-gh wait run") == 0, box, out)


def commit_path_sees_an_open_run_on_the_commits_branch(failures: list[str], name: str, box: Sandbox) -> None:
    # A run dispatched the default way (on the branch, head = the commit) is the same verification.
    request_id = box.dispatched_request_id(["--filter", "alpha_test"])
    head = box.head()
    box.open_runs(("9008", "queued", f"cmux-tui focused {request_id} @ {head}"))
    code, out = box.run(["--commit", head, "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    check(failures, name, code == 4 and not box.dispatches() and "runs/9008" in out, box, out)


def commit_path_open_run_of_another_commit_dispatches(failures: list[str], name: str, box: Sandbox) -> None:
    red = box.head()
    fix = box.commit("fix")
    box.push(fix)
    request_id = box.dispatched_request_id(["--commit", fix, "--filter", "alpha_test"], **COMMIT_PATH_ENV)
    box.open_runs(("9009", "queued", f"cmux-tui focused {request_id} @ {fix}"), trusted=True)
    code, out = box.run(["--commit", red, "--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60", **COMMIT_PATH_ENV)
    check(failures, name, len(box.dispatches()) == 1 and "runs/9009" not in out, box, out)


def default_path_sees_an_open_commit_path_run(failures: list[str], name: str, box: Sandbox) -> None:
    head = box.head()
    request_id = box.dispatched_request_id(["--commit", head, "--filter", "alpha_test"], **COMMIT_PATH_ENV)
    box.open_runs(("9010", "waiting", f"cmux-tui focused {request_id} @ {head}"), trusted=True)
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 4 and not box.dispatches() and "runs/9010" in out, box, out)


def default_path_dispatches_the_head_on_its_own_branch(failures: list[str], name: str, box: Sandbox) -> None:
    head = box.head()
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    posts = box.dispatches()
    check(failures, name, len(posts) == 1 and " -f ref=verify-test " in posts[0]
          and f" -f inputs[commit]={head} " in posts[0] and "source_branch" not in posts[0]
          and box.count("gh run download") >= 1, box, out)


def default_path_still_refuses_an_unpushed_head(failures: list[str], name: str, box: Sandbox) -> None:
    pushed = box.head()
    local = box.commit("not pushed")
    code, out = box.run(["--filter", "alpha_test"], FAKE_STATES="completed|success|1",
                        CMUX_TUI_HOSTED_TIMEOUT_SECONDS="60")
    check(failures, name, code == 1 and not box.dispatches()
          and f"is {pushed}, but local HEAD is {local}" in out, box, out)


# cmux-tui.yml's validate-inputs step, run as GitHub runs a `shell: bash` step, with a stub gh.
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"
VALIDATE_GH_STUB = r"""#!/usr/bin/env bash
echo "gh $*" >> "$STUB_DIR/calls.log"
case "$*" in
  # The source branch's head (--jq .object.sha); FAKE_SOURCE_HEAD empty: no such branch.
  *"repos/manaflow-ai/cmux/git/ref/heads/"*)
    if [[ -z "${FAKE_SOURCE_HEAD:-}" ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo "$FAKE_SOURCE_HEAD" ;;
  # compare/<commit>...<branch head>: "<status> <behind_by>", as the step's --jq asks.
  *"repos/manaflow-ai/cmux/compare/"*)
    if [[ -z "${FAKE_COMPARE:-}" ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo "$FAKE_COMPARE" ;;
  *) echo "unexpected gh call: $*" >&2; exit 97 ;;
esac
"""


def run_validate_step(*, commit: str, workflow_sha: str, ref: str, source_branch: str = "",
                      mode: str = "focused", test_filter: str = "alpha_test",
                      **fake: str) -> tuple[int, str, list[str]]:
    import yaml  # tooling-tests installs PyYAML; only these cases need it

    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    [step] = [step for step in workflow["jobs"]["validate-inputs"]["steps"]
              if step.get("name") == "Validate dispatch inputs"]
    contexts = {
        "inputs.commit": commit, "inputs.mode": mode, "inputs.test_filter": test_filter,
        "inputs.request_id": "abc123-f00000000-1-1", "inputs.source_branch": source_branch,
        "github.sha": workflow_sha, "github.ref": ref, "github.repository": "manaflow-ai/cmux",
        "github.token": "test-token",
    }
    directory = Path(tempfile.mkdtemp(prefix="validate-step-test."))
    try:
        env = {"PATH": f"{directory}:{os.environ['PATH']}", "STUB_DIR": str(directory), **fake}
        # The step's env, with each ${{ expression }} replaced the way GitHub would.
        for key, value in (step.get("env") or {}).items():
            expression = str(value).strip()
            assert expression.startswith("${{") and expression.endswith("}}"), (key, value)
            expression = expression[3:-2].strip()
            assert expression in contexts, f"the test does not know the step's {key}: {value}"
            env[key] = contexts[expression]
        gh = directory / "gh"
        gh.write_text(VALIDATE_GH_STUB, encoding="utf-8")
        gh.chmod(0o755)
        script = directory / "step.sh"
        script.write_text(step["run"], encoding="utf-8")
        result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
                                env=env, capture_output=True, text=True, timeout=60)
        log = directory / "calls.log"
        calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        return result.returncode, result.stdout + result.stderr, calls
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def validate_step_cases(failures: list[str]) -> None:
    red, head, feat = "a" * 40, "b" * 40, "c" * 40
    trusted = "refs/heads/feat-cmux-next"

    def case(name: str, want_ok: bool, *, calls_have: str = "", no_calls: bool = False, **kwargs) -> None:
        code, out, calls = run_validate_step(**kwargs)
        ok = (code == 0) == want_ok
        if calls_have and not any(calls_have in line for line in calls):
            ok = False
        if no_calls and calls:
            ok = False
        if not ok:
            failures.append(f"validate-inputs: {name} (exit {code})\n--- output ---\n{out}\n--- calls ---\n"
                            + "\n".join(calls))

    case("the dispatched head itself passes with no API call", True, no_calls=True,
         commit=head, workflow_sha=head, ref="refs/heads/verify-test")
    case("another commit on a branch's own dispatch is refused", False,
         commit=red, workflow_sha=head, ref="refs/heads/verify-test", source_branch="verify-test",
         FAKE_SOURCE_HEAD=head, FAKE_COMPARE="ahead 0")
    case("another commit on feat-cmux-next, contained in its source branch, passes", True,
         calls_have=f"repos/manaflow-ai/cmux/compare/{red}...{head}",
         commit=red, workflow_sha=feat, ref=trusted, source_branch="verify-test",
         FAKE_SOURCE_HEAD=head, FAKE_COMPARE="ahead 0")
    case("another commit on main, contained in its source branch, passes", True,
         commit=red, workflow_sha=feat, ref="refs/heads/main", source_branch="task/verify-test",
         FAKE_SOURCE_HEAD=head, FAKE_COMPARE="ahead 0")
    case("the source branch's head itself passes", True,
         commit=head, workflow_sha=feat, ref=trusted, source_branch="verify-test",
         FAKE_SOURCE_HEAD=head, FAKE_COMPARE="identical 0")
    case("a commit the source branch does not contain (a fork object) is refused", False,
         commit=red, workflow_sha=feat, ref=trusted, source_branch="verify-test",
         FAKE_SOURCE_HEAD=head, FAKE_COMPARE="diverged 2")
    case("a commit newer than the source branch is refused", False,
         commit=red, workflow_sha=feat, ref=trusted, source_branch="verify-test",
         FAKE_SOURCE_HEAD=head, FAKE_COMPARE="behind 3")
    case("a source branch that does not exist is refused", False,
         commit=red, workflow_sha=feat, ref=trusted, source_branch="gone",
         FAKE_SOURCE_HEAD="", FAKE_COMPARE="ahead 0")
    case("another commit with no source branch is refused before any API call", False, no_calls=True,
         commit=red, workflow_sha=feat, ref=trusted, source_branch="")
    case("an unsafe source branch name is refused before any API call", False, no_calls=True,
         commit=red, workflow_sha=feat, ref=trusted, source_branch="x..y")
    case("a fork-style owner:branch source is refused before any API call", False, no_calls=True,
         commit=red, workflow_sha=feat, ref=trusted, source_branch="someone:verify-test")
    case("an uppercase commit is still refused", False, no_calls=True,
         commit=red.upper(), workflow_sha=feat, ref=trusted, source_branch="verify-test")
    case("full mode still refuses a test filter", False,
         commit=head, workflow_sha=head, ref="refs/heads/verify-test", mode="full", test_filter="x")


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
        ("--commit with a pushed non-head sha dispatches it on feat-cmux-next",
         commit_path_dispatches_non_head_on_trusted_ref),
        ("--commit takes the pushed head too, in full mode", commit_path_accepts_the_pushed_head),
        ("--commit refuses a commit that is not on the pushed branch", commit_path_refuses_an_unpushed_commit),
        ("--commit refuses a sha this clone does not have", commit_path_refuses_an_unknown_commit),
        ("--commit refuses a short sha (exit 2)", commit_path_refuses_a_short_sha),
        ("--commit: an open --commit run of the same commit and filter: no dispatch, exit 4",
         commit_path_refuses_a_second_open_run),
        ("--commit: an open run on the commit's own branch: no dispatch, exit 4",
         commit_path_sees_an_open_run_on_the_commits_branch),
        ("--commit: an open --commit run of another commit does not stop a dispatch",
         commit_path_open_run_of_another_commit_dispatches),
        ("default path: an open --commit run of the same commit and filter: exit 4",
         default_path_sees_an_open_commit_path_run),
        ("default path: dispatches the pushed head on its own branch, with no source_branch",
         default_path_dispatches_the_head_on_its_own_branch),
        ("default path: still refuses a local HEAD that is not pushed", default_path_still_refuses_an_unpushed_head),
    ]:
        scenario(failures, name, test)
    validate_step_cases(failures)
    if failures:
        print("\n\n".join(f"FAIL: {f}" for f in failures), file=sys.stderr)
        return 1
    print("ok: verify-cmux-tui-hosted.sh leaves its run alone unless Ctrl-C or --cancel-on-timeout says otherwise,"
          " keeps one open run per commit, mode and filter, and verifies a pushed non-head commit with --commit;"
          " cmux-tui.yml accepts that commit only from a branch of this repository")
    return 0


if __name__ == "__main__":
    sys.exit(main())
