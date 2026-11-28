#!/usr/bin/env python3
"""request-nightly-next.sh promotes only a commit whose web bundles built green.

nightly-next runs 45897378989, 45902437067, 45907763450 and 45914099065 (2026-11-26) passed the
Release compile precheck and then failed about an hour in at "Build the web bundles (cmux-next)" on
base web reds. The script now also reads the R2 object cmux-next.yml's web-bundles job publishes
under the commit's source key: a newer commit whose bundles are missing is passed over for an older
one whose bundles are there.

The script runs for real against a throwaway origin; its fleet reads (the compile results service and
the web bundle store) go to a local HTTP server, and the cmux-tui tree helpers are stubs.
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/request-nightly-next.sh"
REPO = "manaflow-ai/cmux"
TREE_KEY = "a" * 40

STUBS = {
    "scripts/cmux-next/pin-cmux-tui.sh": f"#!/usr/bin/env bash\necho key={TREE_KEY}\n",
    "scripts/cmux-next/tree-commit-marker.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/cmux-next/nightly_quarantine.py": "import sys\nsys.exit(0)\n",
    "scripts/ci/cmux_tui_tree_key.py": f"print('{TREE_KEY}')\n",
    # The commit's own key script, as the real one: a digest of its web inputs.
    "scripts/cmux-next/web-bundle-key.py": (
        "import hashlib, pathlib, sys\n"
        "print(hashlib.sha256(pathlib.Path(sys.argv[1], 'webviews/src/app.ts').read_bytes()).hexdigest())\n"
    ),
    ".github/workflows/nightly.yml": "env:\n  NIGHTLY_NEXT_NOTARY_PAUSED: ''\n",
}


def web_key(source: str) -> str:
    return hashlib.sha256(source.encode()).hexdigest()


class Fleet(http.server.BaseHTTPRequestHandler):
    green_keys: set[str] = set()
    store_status: int | None = None  # set to answer every bundle read with this status

    def log_message(self, *args) -> None:  # quiet
        pass

    def do_GET(self) -> None:
        if self.path.startswith("/compile/"):
            sha = self.path.split("/")[2].split("?")[0]
            body = json.dumps({"sha": sha, "repo": REPO, "recipe_version": 2,
                               "configuration": "release-onone", "state": "pass"}).encode()
            self.send_response(200)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_HEAD(self) -> None:
        name = self.path.rsplit("/", 1)[-1]
        if Fleet.store_status is not None:
            self.send_response(Fleet.store_status)
        elif any(name == f"cmux-next-web-bundles-v1-{k}.tar.zst" for k in Fleet.green_keys):
            self.send_response(200)
        else:
            self.send_response(404)
        self.end_headers()


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True,
                          text=True).stdout.strip()


def commit(work: Path, source: str, message: str) -> str:
    (work / "webviews/src/app.ts").write_text(source)
    git(work, "add", "-A")
    git(work, "commit", "-q", "-m", message)
    return git(work, "rev-parse", "HEAD")


def scenario(green_sources: list[str], store_status: int | None = None) -> tuple[str, dict[str, str]]:
    """Origin: nightly-next at A; feat-cmux-next A -> B (good web) -> C (broken web). Runs the script at C."""
    tmp = Path(tempfile.mkdtemp(prefix="nightly-web-gate-"))
    try:
        work = tmp / "work"
        work.mkdir()
        git(work, "init", "-q", "-b", "feat-cmux-next")
        for rel, text in STUBS.items():
            path = work / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            path.chmod(0o755)
        shutil.copy(SCRIPT, work / "scripts/cmux-next/request-nightly-next.sh")
        (work / "webviews/src").mkdir(parents=True)
        shas = {
            "A": commit(work, "export const v = 1\n", "A"),
            "B": commit(work, "export const v = 2\n", "B"),
            "C": commit(work, "import { v } from './v'\nimport { v } from './v'\n", "C"),
        }
        origin = tmp / "origin.git"
        git(tmp, "init", "-q", "--bare", str(origin))
        git(work, "remote", "add", "origin", str(origin))
        git(work, "push", "-q", "origin", f"{shas['C']}:refs/heads/feat-cmux-next",
            f"{shas['A']}:refs/heads/nightly-next")
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho 'gh is not reachable in this test' >&2\nexit 1\n")
        (bin_dir / "gh").chmod(0o755)

        Fleet.green_keys = {web_key(s) for s in green_sources}
        Fleet.store_status = store_status
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fleet)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_address[1]}"
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("GITHUB_", "GH_", "NIGHTLY_NEXT", "CMUX_NIGHTLY_NEXT", "RUNNER_"))}
        env.update({
            "PATH": f"{bin_dir}{os.pathsep}{env.get('PATH', '')}",
            "CMUX_NIGHTLY_NEXT_PRECHECK_RESULTS": f"{base}/compile",
            "CMUX_NIGHTLY_NEXT_WEB_BUNDLES_URL": f"{base}/objects",
            "TMPDIR": str(tmp),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        try:
            run = subprocess.run(["bash", "scripts/cmux-next/request-nightly-next.sh", "--repo", REPO,
                                  "--tree-ready", shas["C"]], cwd=work, env=env, capture_output=True,
                                 text=True, timeout=120)
        finally:
            server.shutdown()
            server.server_close()
        out = run.stdout + run.stderr
        assert run.returncode == 0, out
        # The candidate checkouts the walk made are gone.
        assert git(work, "worktree", "list").count("\n") == 0, git(work, "worktree", "list")
        return out, shas
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_a_commit_whose_web_bundles_failed_is_passed_over_for_an_older_green_one() -> None:
    # C compiled in Release (the precheck passes) but its web bundles never built; B's did.
    out, shas = scenario(green_sources=["export const v = 2\n"])
    c, b = shas["C"][:12], shas["B"][:12]
    assert f"precheck {c}" in out, out
    assert f"not promoting {c}: no web bundles are published for its key" in out, out
    assert f"web bundles {b}: its web bundles (key" in out, out
    assert f"promotable {b}" in out, out
    assert f"promotable {c}" not in out, out


def test_the_tip_is_promoted_when_its_web_bundles_built() -> None:
    out, shas = scenario(green_sources=["export const v = 2\n",
                                        "import { v } from './v'\nimport { v } from './v'\n"])
    assert f"promotable {shas['C'][:12]}" in out, out


def test_no_commit_is_promoted_while_none_has_green_web_bundles() -> None:
    out, shas = scenario(green_sources=[])
    assert "\npromotable " not in "\n" + out, out
    assert f"not promoting {shas['B'][:12]}: no web bundles" in out, out


def test_a_store_that_does_not_answer_promotes_the_tip_with_a_warning() -> None:
    out, shas = scenario(green_sources=[], store_status=500)
    assert "the web bundle store did not answer" in out, out
    assert f"promotable {shas['C'][:12]}" in out, out


def main() -> None:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    print(f"{len(tests)} passed")


if __name__ == "__main__":
    sys.exit(main())
