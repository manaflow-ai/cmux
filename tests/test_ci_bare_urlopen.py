"""No bare urlopen of api.github.com or files*.cmux.com in workflows or scripts.

Run 45868119309 (classic nightly resume) died on a bare `urlopen` of api.github.com's release read: HTTP 403 with no
reason. The CDN in front of files.cmux.com / files-next.cmux.com refuses Python's default User-Agent
(Cloudflare Browser Integrity Check, hq docs/handbook/cdn-refuses-the-default-client.md). A read of either host from
Python goes through `gh api` (retries, own UA, shows the refusal) or a `urllib.request.Request` naming a User-Agent.
A call that never reaches those hosts says so with `# user-agent: <why>` on its line or the line above.
"""
import ast
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOSTS = ("api.github.com", "files.cmux.com", "files-next.cmux.com")
OPENERS = {"urlopen", "urlretrieve"}
MARK = "# user-agent:"
# Existing bare reads, per file, from before this check: a ratchet. A new file or a higher count fails; fix one and
# lower its count (the test fails on a stale number so the list only shrinks). Convert to `gh api` or a Request
# naming a User-Agent, as #59218 did for the publish guard.
BASELINE = {
    ".github/workflows/cloud-machine-tests.yml": 1,
    ".github/workflows/resolve-dispatch-ref.yml": 2,
    ".github/workflows/test-ios.yml": 1,
    "scripts/ci/actions_artifact_prune.py": 1,
    "scripts/ci/auto_triage.py": 1,
    "scripts/ci/cla_quota_rerun.py": 1,
    "scripts/ci/cmux_binaries_prune.py": 1,
    "scripts/ci/cmux_next_dev_publish_supersede.py": 1,
    "scripts/ci/cmux_tui_artifacts_retry.py": 1,
    "scripts/ci/delta_since_green.py": 1,
    "scripts/ci/download-run-artifact.py": 2,
    "scripts/ci/guard_attribution.py": 1,
    "scripts/ci/hosted_light_rescue.py": 1,
    "scripts/ci/nightly_next_feed_watch.py": 1,
    "scripts/ci/nightly_sign_admit.py": 1,
    "scripts/ci/owned_pool_rescue.py": 2,
    "scripts/ci/parallel_artifact_download.py": 1,
    "scripts/ci/pr_status.py": 1,
    "scripts/ci/submodule_forward_only.py": 1,
    "scripts/ci/sync_labels.py": 1,
}


def tracked(*globs: str) -> list[Path]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", *globs], capture_output=True, check=True)
    return [ROOT / n for n in out.stdout.decode().split("\0") if n]


def is_request(node) -> bool:
    return isinstance(node, ast.Call) and (getattr(node.func, "attr", None) == "Request"
                                           or getattr(node.func, "id", None) == "Request")


def names_agent(request: ast.Call) -> bool:
    headers = next((k.value for k in request.keywords if k.arg == "headers"), None)
    if headers is None and len(request.args) >= 3:
        headers = request.args[2]
    if headers is None:
        return False
    if not isinstance(headers, ast.Dict):
        return True  # unreadable headers: held to the file naming a User-Agent below
    keys = [k.value.lower() for k in headers.keys if isinstance(k, ast.Constant) and isinstance(k.value, str)]
    return "user-agent" in keys or None in headers.keys


def marked(lines: list[str], lineno: int) -> bool:
    return MARK in lines[lineno - 1] or (lineno >= 2 and lines[lineno - 2].strip().startswith(MARK))


def bare_opens(text: str) -> list[int]:
    """Lines of urlopen/urlretrieve calls in Python source whose argument is not a Request naming a User-Agent."""
    tree, lines, out = ast.parse(text), text.splitlines(), []
    for scope in (n for n in ast.walk(tree) if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef))):
        requests = {t.id for n in ast.walk(scope) if isinstance(n, ast.Assign) and is_request(n.value)
                    and names_agent(n.value) for t in n.targets if isinstance(t, ast.Name)}
        for n in ast.walk(scope):
            if not (isinstance(n, ast.Call) and n.args):
                continue
            name = n.func.attr if isinstance(n.func, ast.Attribute) else getattr(n.func, "id", "")
            if name not in OPENERS:
                continue
            arg = n.args[0]
            if (is_request(arg) and names_agent(arg)) or (isinstance(arg, ast.Name) and arg.id in requests):
                continue
            if not marked(lines, n.lineno):
                out.append(n.lineno)
    return sorted(set(out))


def yaml_bare_opens(text: str) -> list[int]:
    """Workflow run blocks hold Python in heredocs the AST cannot parse whole: a `urlopen(` line in a workflow
    naming a host is bare unless the workflow names a User-Agent or marks the line."""
    if "user-agent" in text.lower() and "Request(" in text:
        return []
    lines = text.splitlines()
    return [i for i, line in enumerate(lines, 1)
            if re.search(r"\b(urlopen|urlretrieve)\(", line) and not line.lstrip().startswith("#")
            and not marked(lines, i)]


def scan() -> list[str]:
    found = []
    for path in tracked("*.py"):
        parts = path.relative_to(ROOT).parts
        if parts[0] in ("tests", "tests_v2") or path.name.startswith("test_") or "node_modules" in parts:
            continue
        text = path.read_text(errors="replace")
        if not any(h in text for h in HOSTS):
            continue
        try:
            found += [f"{path.relative_to(ROOT)}:{n}" for n in bare_opens(text)]
        except SyntaxError:
            continue
    for path in tracked(".github/workflows/*.yml", ".github/workflows/*.yaml"):
        text = path.read_text(errors="replace")
        if any(h in text for h in HOSTS):
            found += [f"{path.relative_to(ROOT)}:{n}" for n in yaml_bare_opens(text)]
    return found


class BareUrlopen(unittest.TestCase):
    def test_no_new_bare_urlopen_in_files_that_read_github_or_the_cdn(self):
        counts = {}
        for hit in scan():
            counts[hit.rsplit(":", 1)[0]] = counts.get(hit.rsplit(":", 1)[0], 0) + 1
        worse = {f: n for f, n in counts.items() if n > BASELINE.get(f, 0)}
        self.assertEqual(worse, {}, "a bare urlopen in a file that names api.github.com or files*.cmux.com: use "
                                    "`gh api`, or a urllib.request.Request with a User-Agent, or mark the line "
                                    f"`{MARK} <why>`")
        stale = {f: n for f, n in BASELINE.items() if counts.get(f, 0) < n}
        self.assertEqual(stale, {}, "fixed: lower these counts in BASELINE")

    def test_detector_sees_bare_reads_and_passes_named_ones(self):
        self.assertEqual(bare_opens("import urllib.request\nurllib.request.urlopen(u)\n"), [2])
        self.assertEqual(bare_opens("from urllib.request import Request, urlopen\nurlopen(Request('u'))\n"), [2])
        self.assertEqual(bare_opens("import urllib.request as r\nr.urlopen(r.Request('u', headers={'User-Agent': 'x/1'}))\n"), [])
        self.assertEqual(bare_opens("import urllib.request\nurllib.request.urlopen(u)  # user-agent: R2\n"), [])
        self.assertEqual(yaml_bare_opens("x: https://api.github.com\n  with urlopen(request) as r:\n"), [2])
        self.assertEqual(yaml_bare_opens("  with urlopen(request) as r:  # user-agent: loopback\n"), [])


if __name__ == "__main__":
    unittest.main()
