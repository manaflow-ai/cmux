#!/usr/bin/env python3
"""Publish-command regression: curated notes, not commit titles, become app news.

Runs the real CLI in a disposable Git repository with GitHub/model transports
standing in for external services. No product functions are imported.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = Path(__file__).resolve().parents[1] / "release-notes.py"


def main():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env = {**os.environ, "GIT_AUTHOR_NAME": "Release fixture", "GIT_COMMITTER_NAME": "Release fixture",
               "GIT_AUTHOR_EMAIL": "fixture@example.com", "GIT_COMMITTER_EMAIL": "fixture@example.com"}

        def git(*args):
            return subprocess.check_output(["git", *args], cwd=root, env=env, text=True).strip()

        git("init", "-q")
        git("commit", "-qm", "base", "--allow-empty")
        base = git("rev-parse", "HEAD")
        rows = [
            (101, "Browser profiles: only a person deletes one", "Release note: Browser: Browser profiles can only be deleted by you.", "webviews/src/browser/Profiles.tsx"),
            (102, "Skills/cmux-browser: agents cannot delete browser profiles", "", "skills/cmux-browser/SKILL.md"),
            (103, "Inject the clock into the daily background so next-day art is deterministic", "## Summary\nRefactor the clock injection for test determinism.", "Packages/macOS/CmuxNext/Sources/Clock.swift"),
            (104, "Terminal cursor update", "Release note: none", "Packages/macOS/CmuxNext/Sources/Terminal.swift"),
            (105, "Opaque overlays draw the separator hairline", "## Summary\nFix a missing separator below the sidebar header.", "webviews/src/sidebar/header.tsx"),
            (106, "Browser profile deletion permission", "Release note: Browser: Only you can delete a browser profile.", "webviews/src/browser/Profiles.tsx"),
            (107, "test: browser profile deletion", "", "tests/test_profiles.py"),
            (108, "Blank note regression", "Release note:\n## Summary\nThis line must stay out of news.", "webviews/src/browser/Profiles.tsx"),
        ]
        prs = {}
        for number, title, body, path in rows:
            git("commit", "-qm", f"{title} (#{number})", "--allow-empty")
            prs[f"p{number}"] = {"number": number, "title": title, "body": body, "mergedAt": "2026-10-14T05:20:00Z",
                                "baseRefName": "feat-cmux-next", "mergeCommit": {"oid": git("rev-parse", "HEAD")},
                                "files": {"totalCount": 1, "nodes": [{"path": path}]}}
        (root / "prs.json").write_text(json.dumps({"data": {"repository": prs}}))
        binary = root / "bin"
        binary.mkdir()
        gh = binary / "gh"
        gh.write_text('#!/usr/bin/env python3\nimport pathlib\nprint(pathlib.Path("prs.json").read_text())\n')
        gh.chmod(0o755)
        requests = []

        class Model(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(request)
                answer = {"notes": [{"area": "sidebar", "title": "Sidebar headers keep a clear separator.", "prs": [105]},
                                    # Duplicate candidate rows must collapse; an invented PR is refused.
                                    {"area": "sidebar", "title": "Sidebar headers keep a clear separator.", "prs": [105]},
                                    {"area": "browser", "title": "An invented feature.", "prs": [999]}]}
                data = json.dumps({"choices": [{"message": {"content": json.dumps(answer)}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data)

        server = HTTPServer(("127.0.0.1", 0), Model)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        env.update(PATH=f"{binary}:{env['PATH']}", GH_TOKEN="fixture", GITHUB_REPOSITORY="manaflow-ai/cmux",
                   CMUX_RELEASE_NOTES_MODEL_URL=f"http://127.0.0.1:{server.server_port}/chat/completions")

        def publish(destination, environment):
            subprocess.run([sys.executable, str(SCRIPT), "build", "--build", "7", "--short", "1.0.0-nightly.7",
                            "--date", "2026-10-14T05:20:00Z", "--head", git("rev-parse", "HEAD"),
                            "--since", base, "--out", destination], cwd=root, env=environment, check=True)
            return json.loads((root / destination / "7.json").read_text())

        try:
            notes = publish("notes", env)
            digest = notes.get("userNotes", [])
            assert len(digest) == 2, f"Expected two user notes; got {digest!r}"
            assert digest[0] == {"area": "browser", "title": "Browser profiles can only be deleted by you.", "prs": [101, 106]}, digest
            assert digest[1]["prs"] == [105] and digest[1]["area"] == "sidebar", digest
            assert len(notes["changes"]) == len(rows), "All changes must retain internal history"
            assert len(requests) == 1, "One bounded summarizer call per publish"
            inputs = json.loads(requests[0]["messages"][1]["content"])
            assert {pr["number"] for pr in inputs} == {103, 105, 108}, inputs
            assert next(pr for pr in inputs if pr["number"] == 108)["body"].startswith("Release note:\n"), inputs
            assert all(line["title"] not in notes["changes"] for line in notes["summary"])
            # Appcast is a separate publishing CLI and must not leak the raw titles
            # while the signed notes are still being generated.
            feeds = root / "feeds"
            feeds.mkdir()
            feed = feeds / "appcast-arm64.xml"
            feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                            '<item><sparkle:version>7</sparkle:version></item></channel></rss>')
            subprocess.run([sys.executable, str(SCRIPT), "appcast", "--head", git("rev-parse", "HEAD"),
                            "--since", base, "--appcasts", str(feeds), "--build", "7",
                            "--feeds", feed.name], cwd=root, env=env, check=True)
            description = ET.parse(feed).findtext("./channel/item/description")
            assert description == "Changed: Browser profiles can only be deleted by you.", description
            assert len(requests) == 1, "Appcast must not run the model a second time"
            # Model failure/unavailability never resurrects raw titles.
            offline = publish("offline", {**env, "CMUX_RELEASE_NOTES_MODEL_URL": "http://127.0.0.1:1"})
            assert offline["userNotes"] == digest[:1], offline["userNotes"]
            hidden = publish("no-token", {**env, "GH_TOKEN": "", "GITHUB_TOKEN": ""})
            assert hidden["userNotes"] == [] and hidden["summary"] == [], hidden
            # A busy nightly still makes one size-bounded request. The fixture
            # observes the HTTP boundary, not the summarizer's implementation.
            for number in range(200, 245):
                git("commit", "-qm", f"Browser interaction polish (#{number})", "--allow-empty")
                prs[f"p{number}"] = {"number": number, "title": "Browser interaction polish", "body": "漢" * 3000,
                                    "mergedAt": "2026-10-14T05:20:00Z", "baseRefName": "feat-cmux-next",
                                    "mergeCommit": {"oid": git("rev-parse", "HEAD")},
                                    "files": {"totalCount": 1, "nodes": [{"path": "webviews/src/browser/Profiles.tsx"}]}}
            (root / "prs.json").write_text(json.dumps({"data": {"repository": prs}}))
            requests.clear()
            publish("busy", env)
            assert len(requests) == 1
            inputs = json.loads(requests[0]["messages"][1]["content"])
            assert len(inputs) <= 40, len(inputs)
            assert len(json.dumps(inputs, ensure_ascii=False).encode()) <= 60_000
            print("PASS: release notes publish CLI filters, deduplicates and fails closed")
        finally:
            server.shutdown()
            thread.join()
            server.server_close()


if __name__ == "__main__":
    main()
