#!/usr/bin/env python3
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Imported by name, never loaded by path: one module object per file (the script module load check).
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
import base_red_checks as module  # noqa: E402


class BaseRedChecksTests(unittest.TestCase):
    def test_parses_failed_summary_and_ansi(self):
        text = "\x1b[31m### 2 cmux-next check(s) failed\x1b[0m\n- Main-thread concurrency (failure)\n- Crash safety (timed_out)\n"
        self.assertEqual(module.failed_names(text), {"Main-thread concurrency", "Crash safety"})

    def test_parses_timestamped_job_log_lines(self):
        # As the job-logs endpoint returns them (push run 40596227506).
        text = ("2026-10-27T22:43:14.6681431Z ### 1 cmux-next check(s) failed\n"
                "2026-10-27T22:43:14.6689782Z - Check the app FFI pin (failure)\n"
                "2026-10-27T22:43:14.6690119Z Each check's own step log has the details.\n")
        self.assertEqual(module.failed_names(text), {"Check the app FFI pin"})

    def test_green_summary_has_no_reds(self):
        self.assertEqual(module.failed_names("All blocking cmux-next checks passed.\\n"), set())

    def test_pending_previous_tip_is_warning_only(self):
        original = module.api
        try:
            module.api = lambda _base, _token, _path: (
                b'{"check_runs":[{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)",'
                b'"status":"in_progress"}]}'
            )
            self.assertIsNone(module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token"))
        finally:
            module.api = original

    def test_completed_previous_tip_still_reads_failed_names(self):
        original = module.api
        try:
            def fake_api(_base, _token, path):
                if "/check-runs?" in path:
                    return (
                        b'{"check_runs":[{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)",'
                        b'"status":"completed","conclusion":"failure",'
                        b'"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/1/job/42"}]}'
                    )
                return b"- Main-thread concurrency (failure)\n"
            module.api = fake_api
            self.assertEqual(
                module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token"),
                {"Main-thread concurrency"},
            )
        finally:
            module.api = original


    def test_previous_tip_job_is_asked_for_by_name(self):
        # 250+ check runs on a tip: an unfiltered first page can miss the job.
        original = module.api
        paths = []
        try:
            def fake_api(_base, _token, path):
                paths.append(path)
                if "/check-runs?" in path:
                    if "check_name=cmux-next+checks+%28god+files%2C+concurrency%2C+crash+safety%2C+l10n%29" not in path:
                        return b'{"total_count":264,"check_runs":[{"name":"other","status":"completed"}]}'
                    return (
                        b'{"check_runs":[{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)",'
                        b'"status":"completed","conclusion":"cancelled",'
                        b'"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/1/job/42"}]}'
                    )
                return b"- Script tests (pin-cmux-tui, embed-cef, ensure-cef store) (cancelled)\n"
            module.api = fake_api
            self.assertEqual(
                module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token"),
                {"Script tests (pin-cmux-tui, embed-cef, ensure-cef store)"},
            )
            self.assertIn("/actions/jobs/42/logs", paths[-1])
        finally:
            module.api = original

    def test_redirect_to_another_host_drops_the_token(self):
        # The job-logs 302 goes to a signed blob URL that refuses a bearer token (401).
        handler = module.DropAuthOnRedirect()
        request = module.urllib.request.Request(
            "https://api.github.com/repos/manaflow-ai/cmux/actions/jobs/42/logs",
            headers={"Authorization": "Bearer token", "Accept": "application/vnd.github+json"},
        )
        moved = handler.redirect_request(request, None, 302, "Found", {}, "https://blob.example.net/logs?sig=x")
        self.assertFalse(moved.has_header("Authorization"))
        self.assertEqual(moved.get_header("Accept"), "application/vnd.github+json")
        same = handler.redirect_request(request, None, 302, "Found", {}, "https://api.github.com/other")
        self.assertEqual(same.get_header("Authorization"), "Bearer token")
        downgraded = handler.redirect_request(request, None, 307, "Temporary", {}, "http://api.github.com/other")
        self.assertFalse(downgraded.has_header("Authorization"))

    def test_unknown_previous_status_fails_closed(self):
        original = module.api
        try:
            for run in ('{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)"}',
                        '{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)","status":"odd"}'):
                module.api = lambda _base, _token, _path, run=run: ('{"check_runs":[%s]}' % run).encode()
                with self.assertRaises(RuntimeError):
                    module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token")
        finally:
            module.api = original

    def test_skipped_push_run_does_not_shadow_the_base_tier_run(self):
        original = module.api
        name = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        runs = [
            {"name": name, "status": "completed", "conclusion": "skipped",
             "started_at": "2026-11-22T04:30:00Z", "details_url": "https://github.com/o/r/actions/runs/1/job/11"},
            {"name": name, "status": "completed", "conclusion": "failure",
             "started_at": "2026-11-22T04:20:00Z", "details_url": "https://github.com/o/r/actions/runs/2/job/22"},
        ]
        paths = []

        def fake_api(_base, _token, path):
            paths.append(path)
            if "/check-runs" in path:
                return json.dumps({"check_runs": runs}).encode()
            if path.endswith("/jobs/22/logs"):
                return b"2026-11-22T04:25:00.0Z - Crash safety (failure)\n"
            raise AssertionError(f"read the skipped run's log: {path}")

        try:
            module.api = fake_api
            reds = module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token")
        finally:
            module.api = original
        self.assertEqual(reds, {"Crash safety"})
        self.assertTrue(paths[-1].endswith("/jobs/22/logs"))

    def test_only_skipped_runs_means_no_checks_job(self):
        original = module.api
        run = {"name": "cmux-next checks (god files, concurrency, crash safety, l10n)",
               "status": "completed", "conclusion": "skipped"}
        try:
            module.api = lambda _base, _token, _path: json.dumps({"check_runs": [run]}).encode()
            with self.assertRaises(RuntimeError):
                module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token")
        finally:
            module.api = original

if __name__ == "__main__":
    unittest.main()
