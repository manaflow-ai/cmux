#!/usr/bin/env python3
"""scripts/ci/gh_app_token.sh: publish-path gh calls go out as the release App, github.token as fallback.

Every workflow's github.token is one actor, so a burst elsewhere refused the nightly publish
(2026-10-26, run 40298250989: HTTP 403 with no x-ratelimit-* headers while core had 4899 calls
left). These tests drive the wrapper against a fake gh, check publish-release-assets.py's
fallback. tests/test_publish_app_token_workflow.py checks that nightly.yml mints the App token and installs the wrapper before
gh_budget_wait.sh (which then wraps it and keeps its wait) in every publish job whose
environment holds the App's credentials.
"""

from __future__ import annotations

import importlib.util
import re
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "gh_app_token.sh"
BUDGET = ROOT / "scripts" / "ci" / "gh_budget_wait.sh"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"
APP, FALLBACK = "ghs_app", "ghs_actions"

# The fake gh logs the token of each call. A token with refusals left in $FAKE_STATE/<token> fails
# with that token's error ($FAKE_STATE/<token>.err); otherwise it prints its arguments and stdin.
FAKE_GH = r"""#!/bin/bash
state="$FAKE_STATE"
case "$*" in *rate_limit*) echo "${GH_TOKEN:-none} $*" >> "$state/rate_reads"; echo 0; exit 0 ;; esac
echo "${GH_TOKEN:-none} $*" >> "$state/log"
left="$(cat "$state/${GH_TOKEN:-none}" 2>/dev/null || echo 0)"
if [ "$left" -gt 0 ]; then
  echo $((left - 1)) > "$state/${GH_TOKEN:-none}"
  cat "$state/${GH_TOKEN:-none}.err" >&2
  exit 1
fi
echo "ok $*"
if [ -n "${READS_STDIN:-}" ]; then cat; fi
"""


class Harness:
    def __init__(self, app_token: str = APP, budget: bool = False, **env: str) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.state = base / "state"
        self.state.mkdir()
        real = base / "real"
        real.mkdir()
        fake = real / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.runner_temp = base / "runner-temp"
        self.runner_temp.mkdir()
        self.github_path = base / "github_path"
        self.env = {
            "PATH": f"{real}:/usr/bin:/bin",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_PATH": str(self.github_path),
            "FAKE_STATE": str(self.state),
            "GH_BUDGET_WAIT_MAX_SECONDS": "2",
            "GH_TOKEN": FALLBACK,
            **env,
        }
        install_env = {**self.env, "GH_APP_TOKEN": app_token, "GH_FALLBACK_TOKEN": FALLBACK}
        self.installed = subprocess.run(["bash", str(SCRIPT), "--install"], env=install_env,
                                        capture_output=True, text=True, check=True)
        self.shim = real / "gh"
        if self.github_path.exists():
            self.shim = Path(self.github_path.read_text().strip().splitlines()[-1]) / "gh"
        if budget:  # gh_budget_wait.sh installs after this wrapper, as in nightly.yml, and wraps it
            self.env["PATH"] = f"{self.shim.parent}:{self.env['PATH']}"
            subprocess.run(["bash", str(BUDGET), "--install"], env=self.env, capture_output=True, text=True, check=True)
            self.shim = Path(self.github_path.read_text().strip().splitlines()[-1]) / "gh"

    def refuse(self, token: str, times: int, error: str) -> None:
        (self.state / token).write_text(str(times))
        (self.state / f"{token}.err").write_text(error + "\n")

    def gh(self, *args: str, stdin: str | None = None, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.shim), *args], env={**self.env, **env}, input=stdin,
                              capture_output=True, text=True, timeout=30)

    def calls(self) -> list[str]:
        log = self.state / "log"
        return log.read_text().splitlines() if log.exists() else []

    def waited(self) -> int:
        ledger = self.runner_temp / "gh-budget-wait" / "waited"
        return int(ledger.read_text()) if ledger.exists() else 0


SECONDARY = "HTTP 403: API rate limit exceeded for installation. (https://api.github.com/repos/o/r/releases)"


class WrapperTests(unittest.TestCase):
    def harness(self, **kwargs) -> Harness:
        h = Harness(**kwargs)
        self.addCleanup(h.tmp.cleanup)
        return h

    def test_a_github_token_call_goes_out_as_the_app(self) -> None:
        h = self.harness()
        result = h.gh("release", "upload", "nightly", "a.dmg")
        self.assertEqual(result.stdout, "ok release upload nightly a.dmg\n")
        self.assertEqual(h.calls(), [f"{APP} release upload nightly a.dmg"])
        token = h.runner_temp / "gh-app-token" / "token"
        self.assertEqual(stat.S_IMODE(token.stat().st_mode), 0o600)
        self.assertNotIn(FALLBACK, "".join(p.read_text() for p in (h.runner_temp / "gh-app-token").rglob("*") if p.is_file()))

    def test_rate_limit_reads_report_github_token_s_budget(self) -> None:
        h = self.harness()
        h.gh("api", "rate_limit", "--jq", ".resources.core.remaining")
        h.gh("api", "--include", "rate_limit")
        self.assertEqual((h.state / "rate_reads").read_text().splitlines(),
                         [f"{FALLBACK} api rate_limit --jq .resources.core.remaining", f"{FALLBACK} api --include rate_limit"])

    def test_another_token_is_left_alone(self) -> None:
        h = self.harness()
        h.gh("api", "x", GH_TOKEN="ghs_release_tag")
        h.gh("api", "y", GH_TOKEN="")
        self.assertEqual(h.calls(), ["ghs_release_tag api x", "none api y"])

    def test_a_refused_app_token_falls_back_to_github_token(self) -> None:
        for error in (SECONDARY, "HTTP 403: Resource not accessible by integration", "HTTP 429: Too Many Requests"):
            h = self.harness()
            h.refuse(APP, 1, error)
            result = h.gh("api", "repos/o/r/actions/runs")
            self.assertEqual(result.returncode, 0, (error, result))
            self.assertEqual(result.stdout, "ok api repos/o/r/actions/runs\n")
            self.assertEqual(h.calls(), [f"{APP} api repos/o/r/actions/runs", f"{FALLBACK} api repos/o/r/actions/runs"])
            self.assertEqual(h.waited(), 0)

    def test_an_area_the_app_cannot_reach_goes_to_github_token_for_the_job(self) -> None:
        h = self.harness()
        h.refuse(APP, 1, "HTTP 403: Resource not accessible by integration (https://api.github.com/x)")
        self.assertEqual(h.gh("api", "repos/o/r/actions/runs/1/artifacts").returncode, 0)
        self.assertEqual(h.gh("api", "--paginate", "/repos/o/r/actions/artifacts?name=x").returncode, 0)
        self.assertEqual(h.gh("api", "repos/o/r/releases/tags/nightly").returncode, 0)
        self.assertEqual(h.calls(), [f"{APP} api repos/o/r/actions/runs/1/artifacts",
                                     f"{FALLBACK} api repos/o/r/actions/runs/1/artifacts",
                                     f"{FALLBACK} api --paginate /repos/o/r/actions/artifacts?name=x",
                                     f"{APP} api repos/o/r/releases/tags/nightly"])

    def test_a_graphql_permission_refusal_falls_back(self) -> None:
        h = self.harness()
        h.refuse(APP, 1, "GraphQL: Resource not accessible by integration (repository.pullRequest)")
        self.assertEqual(h.gh("api", "graphql", "-f", "query=q").returncode, 0)
        self.assertEqual(h.gh("api", "graphql", "-f", "query=r").returncode, 0)
        self.assertEqual(h.calls(), [f"{APP} api graphql -f query=q", f"{FALLBACK} api graphql -f query=q",
                                     f"{FALLBACK} api graphql -f query=r"])

    def test_an_expired_app_token_is_dropped_for_the_job(self) -> None:
        h = self.harness()
        h.refuse(APP, 1, "HTTP 401: Bad credentials (https://api.github.com/x)")
        self.assertEqual(h.gh("api", "x").returncode, 0)
        self.assertEqual(h.gh("api", "y").returncode, 0)
        self.assertEqual(h.calls(), [f"{APP} api x", f"{FALLBACK} api x", f"{FALLBACK} api y"])

    def test_another_app_failure_is_returned_as_is(self) -> None:
        h = self.harness()
        h.refuse(APP, 1, "HTTP 404: Not Found")
        result = h.gh("release", "view", "nightly")
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 404", result.stderr)
        self.assertEqual(h.calls(), [f"{APP} release view nightly"])

    def test_both_refused_backs_off_then_retries_both(self) -> None:
        h = self.harness(GH_BUDGET_WAIT_MAX_SECONDS="1")
        h.refuse(APP, 1, SECONDARY)
        h.refuse(FALLBACK, 1, SECONDARY)
        result = h.gh("release", "upload", "nightly", "a.dmg")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(h.calls(), [f"{APP} release upload nightly a.dmg", f"{FALLBACK} release upload nightly a.dmg",
                                     f"{APP} release upload nightly a.dmg"])
        self.assertIn("backing off 1s", result.stderr)  # 60 s, capped by the job's total
        self.assertEqual(h.waited(), 1)

    def test_an_unreadable_ledger_counts_as_the_whole_budget(self) -> None:
        for content in ("", "garbage", "-5", "1.5"):
            h = self.harness(GH_BUDGET_WAIT_MAX_SECONDS="100")
            ledger = h.runner_temp / "gh-budget-wait" / "waited"
            ledger.parent.mkdir(parents=True, exist_ok=True)
            ledger.write_text(content)
            h.refuse(APP, 1, SECONDARY)
            h.refuse(FALLBACK, 1, SECONDARY)
            result = h.gh("api", "x")
            self.assertEqual(result.returncode, 1, (content, result))
            self.assertNotIn("backing off", result.stderr, content)
            self.assertEqual(ledger.read_text(), content)

    def test_the_wait_is_reserved_before_sleeping(self) -> None:
        text = SCRIPT.read_text()
        self.assertLess(text.index('mv -f "$ledger_dir/waited.$$" "$ledger_dir/waited"'), text.index('sleep "$want"'))
        h = self.harness(GH_BUDGET_WAIT_MAX_SECONDS="1")
        (h.runner_temp / "gh-budget-wait").write_text("not a directory")  # the ledger cannot be written
        h.refuse(APP, 1, SECONDARY)
        h.refuse(FALLBACK, 1, SECONDARY)
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 1, result)
        self.assertIn("not waiting", result.stderr)
        self.assertNotIn("backing off", result.stderr)

    def test_backoff_is_exponential_from_60s_and_honours_retry_after(self) -> None:
        text = SCRIPT.read_text()
        self.assertIn("want=$((60 * (1 << (try - 1))))", text)
        h = self.harness(GH_BUDGET_WAIT_MAX_SECONDS="100")
        h.refuse(APP, 1, SECONDARY)
        h.refuse(FALLBACK, 1, SECONDARY + "\nretry-after: 1")
        result = h.gh("api", "-i", "x")
        self.assertEqual(result.returncode, 0, result)
        self.assertIn("backing off 1s", result.stderr)

    def test_a_permission_refusal_of_github_token_does_not_wait(self) -> None:
        h = self.harness()
        h.refuse(APP, 1, "HTTP 403: Resource not accessible by integration")
        h.refuse(FALLBACK, 1, "HTTP 403: Resource not accessible by integration")
        self.assertEqual(h.gh("api", "x").returncode, 1)
        self.assertEqual(len(h.calls()), 2)
        self.assertEqual(h.waited(), 0)

    def test_the_budget_wrapper_wraps_this_one_and_keeps_its_wait(self) -> None:
        h = self.harness(budget=True, GH_BUDGET_WAIT_MAX_SECONDS="1", GH_APP_TOKEN_ATTEMPTS="1")
        h.refuse(APP, 2, SECONDARY)
        h.refuse(FALLBACK, 1, SECONDARY)
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 0, result)
        self.assertIn("GitHub API budget", result.stderr)  # gh_budget_wait.sh waited, then retried
        self.assertEqual(h.calls(), [f"{APP} api x", f"{FALLBACK} api x", f"{APP} api x", f"{FALLBACK} api x"])

    def test_stdin_is_replayed_for_the_fallback(self) -> None:
        h = self.harness(READS_STDIN="1")
        h.refuse(APP, 1, SECONDARY)
        result = h.gh("api", "x", "--input", "-", stdin='{"a": 1}')
        self.assertEqual(result.stdout, 'ok api x --input -\n{"a": 1}')

    def test_no_app_token_installs_nothing(self) -> None:
        h = self.harness(app_token="")
        self.assertIn("::warning", h.installed.stdout)
        self.assertFalse(h.github_path.exists())


spec = importlib.util.spec_from_file_location("publisher_app_token", ROOT / "scripts/ci/publish-release-assets.py")
publisher = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = publisher
spec.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def client(self, failures: dict[str, list[int]]):
        client = publisher.GitHub("o/r", APP, fallback=FALLBACK)
        seen = []

        def fake(method, url, **kwargs):
            seen.append(client.token)
            statuses = failures.get(client.token, [])
            if statuses:
                raise publisher.RequestError(f"{method} HTTP {statuses[0]}", status=statuses.pop(0))
            return {"ok": True}
        client._request = fake
        return client, seen

    def test_a_refused_app_upload_is_sent_again_with_github_token(self) -> None:
        for status in (401, 403, 429):
            client, seen = self.client({APP: [status]})
            self.assertEqual(client.request("POST", "https://uploads.github.com/x", body=b"a"), {"ok": True})
            self.assertEqual(seen, [APP, FALLBACK])
            client.request("GET", "https://api.github.com/y")
            self.assertEqual(seen, [APP, FALLBACK, FALLBACK])

    def test_concurrent_refusals_switch_once_and_every_call_succeeds(self) -> None:
        import threading
        client = publisher.GitHub("o/r", APP, fallback=FALLBACK)
        barrier = threading.Barrier(4)
        seen = []

        def fake(method, url, **kwargs):
            token = client.token
            seen.append(token)
            if token == APP:
                barrier.wait(timeout=5)  # every worker is refused with the App token at once
                raise publisher.RequestError("POST HTTP 403", status=403, rate_limited=True)
            return {"ok": True}
        client._request = fake
        results = []
        workers = [threading.Thread(target=lambda: results.append(client.request("POST", "https://x", body=b"a")))
                   for _ in range(4)]
        for w in workers:
            w.start()
        for w in workers:
            w.join(timeout=10)
        self.assertEqual(results, [{"ok": True}] * 4)
        self.assertEqual((client.token, client.fallback), (FALLBACK, ""))
        self.assertEqual(seen.count(FALLBACK), 4)

    def test_hashing_an_asset_falls_back_and_never_sends_the_token_to_another_host(self) -> None:
        import http.server
        import urllib.request
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                requests.append((self.headers.get("Host"), self.path, self.headers.get("Authorization")))
                if self.headers.get("Authorization") == f"Bearer {APP}":
                    self.send_response(403)
                    self.end_headers()
                elif self.path == "/asset":
                    self.send_response(302)
                    self.send_header("Location", f"http://localhost:{port}/storage")
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"data")

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        client = publisher.GitHub("o/r", APP, fallback=FALLBACK)
        url = f"http://127.0.0.1:{port}/asset"
        opener = urllib.request.build_opener(publisher._SameHostAuthRedirect)

        class Local:  # asset_digest takes only https URLs; send its request to the local server
            @staticmethod
            def open(request, timeout):
                request.full_url = url
                return opener.open(request, timeout=timeout)
        with unittest.mock.patch.object(publisher, "_OPENER", Local):
            digest = client.asset_digest({"name": "a", "url": "https://api.github.com/x", "size": 4})
        self.assertEqual(digest, "sha256:" + __import__("hashlib").sha256(b"data").hexdigest())
        self.assertEqual(client.token, FALLBACK)
        self.assertEqual([r[2] for r in requests], [f"Bearer {APP}", f"Bearer {FALLBACK}", None])
        self.assertEqual(requests[-1][1], "/storage")

    def test_finalize_and_prune_take_the_app_token_first(self) -> None:
        self.assertIn("client = publisher.client_from_env(args.repo)", (ROOT / "scripts/ci/finalize-release.py").read_text())
        spec = importlib.util.spec_from_file_location("prune_app_token", ROOT / "scripts/prune_nightly_release_assets.py")
        prune = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = prune  # its dataclasses look their module up
        spec.loader.exec_module(prune)
        prune._app_token[0] = APP
        seen = []

        def fake(method, path, token, *, attempts=None):
            seen.append(token)
            if token == APP:
                raise prune.GitHubAPIError(403, "API rate limit exceeded for installation")
            return {"ok": True}
        with unittest.mock.patch.dict("os.environ", {"GH_TOKEN": FALLBACK}), \
                unittest.mock.patch.object(prune, "_github_api_json", fake):
            self.assertEqual(prune.github_api_json("GET", "repos/o/r/releases/tags/nightly"), {"ok": True})
            self.assertEqual(prune.github_api_json("GET", "repos/o/r/releases/1/assets"), {"ok": True})
        self.assertEqual(seen, [APP, FALLBACK, FALLBACK])

    def test_finalize_download_falls_back_when_the_app_token_is_refused(self) -> None:
        spec = importlib.util.spec_from_file_location("finalize_app_token", ROOT / "scripts/ci/finalize-release.py")
        finalize = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = finalize
        spec.loader.exec_module(finalize)
        client = publisher.GitHub("o/r", APP, fallback=FALLBACK)
        seen = []
        body = unittest.mock.MagicMock()

        def fake_open(c, url):
            seen.append(c.token)
            if c.token == APP:
                raise urllib.error.HTTPError(url, 403, "Forbidden", {}, None)
            return body
        with unittest.mock.patch.object(finalize, "open_asset", fake_open):
            self.assertIs(finalize.open_asset_with_fallback(client, "https://api.github.com/a"), body)
        self.assertEqual(seen, [APP, FALLBACK])
        self.assertEqual(client.token, FALLBACK)
        # A refusal of the fallback itself is raised, not retried.
        with unittest.mock.patch.object(finalize, "open_asset", fake_open):
            client.token = APP
            client.fallback = ""
            with self.assertRaises(urllib.error.HTTPError):
                finalize.open_asset_with_fallback(client, "https://api.github.com/a")
        self.assertIn("open_asset_with_fallback(client, remote[\"url\"])", (ROOT / "scripts/ci/finalize-release.py").read_text())

    def test_another_failure_after_a_concurrent_switch_is_not_sent_again(self) -> None:
        client = publisher.GitHub("o/r", APP, fallback=FALLBACK)
        seen = []

        def fake(method, url, **kwargs):
            seen.append(client.token)
            client.token, client.fallback = FALLBACK, ""  # another worker switched meanwhile
            raise publisher.RequestError(f"{method} HTTP 422", status=422)
        client._request = fake
        with self.assertRaises(publisher.RequestError):
            client.request("POST", "https://api.github.com/x", body=b"a")
        self.assertEqual(seen, [APP])

    def test_another_failure_does_not_switch(self) -> None:
        client, seen = self.client({APP: [422]})
        with self.assertRaises(publisher.RequestError):
            client.request("POST", "https://api.github.com/x", body=b"a")
        self.assertEqual(seen, [APP])

    def test_main_reads_the_app_token_first(self) -> None:
        with unittest.mock.patch.dict("os.environ", {"GH_APP_TOKEN": APP, "GH_TOKEN": FALLBACK}):
            client = publisher.client_from_env("o/r")
        self.assertEqual((client.token, client.fallback), (APP, FALLBACK))
        with unittest.mock.patch.dict("os.environ", {"GH_APP_TOKEN": "", "GH_TOKEN": FALLBACK}):
            client = publisher.client_from_env("o/r")
        self.assertEqual((client.token, client.fallback), (FALLBACK, ""))
        self.assertIn("client = client_from_env(args.repo)", (ROOT / "scripts/ci/publish-release-assets.py").read_text())


if __name__ == "__main__":
    unittest.main()
