#!/usr/bin/env python3
"""A cache a pull request can write never reaches a release or secret-holding job.

GitHub's cache store is scoped by ref: a pull_request job's save is read only by that pull request,
while a save from a job that runs in the base branch's scope (pull_request_target, workflow_run,
issue_comment and the other base-context triggers) is read by every release and tag build. The
2026 TanStack attack chained exactly that (pull_request_target, a poisoned cache, then OIDC token
theft; SLSA, "Mini Shai-Hulud: Where SLSA's Boundaries Fall", 2026-05-15). So:

1. No job a base-context trigger can start saves a cache, directly, in a local composite action, or
   in a reusable workflow it calls. A step gated to push or schedule only is not such a save.
   (backend-migrations.yml holds the shape: "it runs with the base's secrets, so it never saves a cache".)
2. sccache has a release-only namespace: a release or secret-holding job that turns sccache on
   uses a key prefix starting with `release/` (or a SCCACHE_DIR named `sccache-release`), and no
   job a pull request can start names that namespace. Today no workflow turns sccache on (the
   pool's GCS sccache serves Linux-pool dev builds only, and its recipe refuses Release), so this
   holds at 0 and keeps the first one honest.

The R2 store, which is not ref-scoped, is held by test_ci_pull_request_caches_are_read_only.py:
its write credentials live in environments limited to main and feat-cmux-next.

It fails a pull request only on a finding that pull request introduces and that is a poisoned
cache: a save a base-context job makes (rule 1), or a pull request job that names the release-only
sccache namespace (rule 2's second half). Each is a cache an untrusted job writes that a release or
secret-holding job later restores and trusts. Every finding already on the base, and the
lower-severity one (a release job using sccache without the release namespace: hygiene, since no
pull request job writes it), is printed report-only. Coordinator interim-coord-2, 2026-11-22: "make
them fail a PR only on findings that PR introduces and that are a real security hole".

The base is CMUX_RELEASE_CACHE_TRUST_BASE (the pull request's base, or a push's previous tip),
compared from its merge-base with HEAD; with none, HEAD^1 (a pull request's merge commit's base
side). The base's .github/ is read from git, so the check needs only that commit's objects. With no
readable base every poisoned-cache finding counts as new. CMUX_RELEASE_CACHE_TRUST_MODE=report
turns failing off; the fixture tests of the detector always assert.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
import unittest.mock
from pathlib import Path
from typing import NamedTuple

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

# "enforce": a poisoned-cache finding the change introduces fails; "report": every finding only warns.
MODE = os.environ.get("CMUX_RELEASE_CACHE_TRUST_MODE", "enforce")

# Triggers whose jobs run in the base branch's cache scope and can be started from outside it.
BASE_CONTEXT = {"pull_request_target", "workflow_run", "issue_comment", "pull_request_review",
                "pull_request_review_comment", "issues", "discussion", "discussion_comment"}
# Triggers whose jobs run code a pull request wrote.
PULL_REQUEST = {"pull_request", "merge_group"} | BASE_CONTEXT
RELEASE_NAME = re.compile(r"(release|publish|nightly|deploy|sign)", re.IGNORECASE)
RELEASE_SCCACHE_PREFIX = "release/"
RELEASE_SCCACHE_DIR = "sccache-release"
SCCACHE_NAMESPACE = re.compile(r"^SCCACHE_(?:[A-Z0-9]+_)?KEY_PREFIX$|^SCCACHE_DIR$")
TRUSTED_ONLY_IF = re.compile(r"github\.event_name\s*==\s*'(push|schedule|workflow_dispatch)'")


class Finding(NamedTuple):
    key: str  # what stays the same across a step rename or a reworded message: the base comparison's identity
    text: str
    blocking: bool  # a poisoned cache: an untrusted job writes what a release or secret-holding job trusts


def triggers(document: dict) -> set[str]:
    on = document.get("on", document.get(True))
    if isinstance(on, str):
        return {on}
    return set(on or [])


def trusted_only(condition: object) -> bool:
    """An `if:` that runs only on push, schedule or dispatch: a plain conjunction naming one of them."""
    text = str(condition or "")
    return bool(TRUSTED_ONLY_IF.search(text)) and "||" not in text


def _off(value: object) -> bool:
    return str(value).strip().lower() in {"false", "${{ false }}"}


def step_saves(step: dict, root: Path, seen: frozenset = frozenset()) -> list[str]:
    """What this step saves to a cache store (the action names), following local composite actions."""
    if trusted_only(step.get("if")):
        return []
    uses = str(step.get("uses", ""))
    name = uses.split("@", 1)[0]
    options = step.get("with") or {}
    lowered = name.lower()
    if name.startswith("./.github/actions/"):
        action_file = next((root / name / f for f in ("action.yml", "action.yaml") if (root / name / f).exists()), None)
        if action_file is None or name in seen:
            return []
        action = yaml.safe_load(action_file.read_text(encoding="utf-8")) or {}
        found = []
        for inner in (action.get("runs") or {}).get("steps") or []:
            found += [f"{name} > {hit}" for hit in step_saves(inner, root, seen | {name})]
        return found
    if lowered.endswith("/restore") or "/cache/restore" in lowered:
        return []
    if lowered in {"actions/cache", "actions/cache/save", "warpbuilds/cache", "warpbuilds/cache/save",
                   "useblacksmith/cache", "useblacksmith/cache/save"}:
        return [] if str(options.get("lookup-only", "")).strip().lower() == "true" else [name]
    if lowered == "swatinem/rust-cache":
        return [] if _off(options.get("save-if", "true")) else [name]
    if lowered in {"actions/setup-node", "actions/setup-python", "actions/setup-java"}:
        return [name] if str(options.get("cache", "")).strip() else []
    if lowered == "actions/setup-go":
        return [] if _off(options.get("cache", "true")) else [name]
    if lowered == "mlugg/setup-zig":
        return [] if _off(options.get("use-cache", "true")) else [name]
    if lowered == "mozilla-actions/sccache-action":
        return [name]
    return []


def _local_workflow(uses: object) -> str | None:
    text = str(uses or "")
    return text.split("@", 1)[0].rsplit("/", 1)[-1] if text.startswith("./.github/workflows/") else None


def base_context_saves(root: Path) -> list[str]:
    return [finding.text for finding in base_context_findings(root)]


def base_context_findings(root: Path) -> list[Finding]:
    """Rule 1: every cache save a base-context trigger can reach, as 'workflow job: step: action'."""
    workflows = {path.name: workflow_jobs.document(path) for path in sorted((root / ".github/workflows").glob("*.y*ml"))}
    failures: list[Finding] = []
    pending = [(name, name) for name, document in workflows.items() if triggers(document) & BASE_CONTEXT]
    visited: set[str] = set()
    while pending:
        name, via = pending.pop()
        if name in visited or name not in workflows:
            continue
        visited.add(name)
        for job_name, job in (workflows[name].get("jobs") or {}).items():
            if trusted_only(job.get("if")):
                continue
            callee = _local_workflow(job.get("uses"))
            if callee:
                pending.append((callee, via))
                continue
            for step in job.get("steps") or []:
                for hit in step_saves(step, root):
                    where = name if name == via else f"{name} (called from {via})"
                    failures.append(Finding(
                        f"base-context-save|{name}|{via}|{job_name}|{hit.split('@', 1)[0].lower()}",
                        f"{where} {job_name}: '{step.get('name') or step.get('uses')}' saves a cache ({hit}); "
                        "a base-context job's save is read by every release build, so restore only", True))
    return failures


def _texts(document: dict, job: dict) -> list[str]:
    return list(workflow_jobs.strings(document.get("env") or {})) + list(workflow_jobs.strings(job))


def enables_sccache(document: dict, job: dict) -> bool:
    for step in job.get("steps") or []:
        if str(step.get("uses", "")).lower().startswith("mozilla-actions/sccache-action"):
            return True
    for scope in [document, job, *(job.get("steps") or [])]:
        for key, value in ((scope.get("env") or {}) if isinstance(scope, dict) else {}).items():
            if str(key) in {"RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WRAPPER"} and "sccache" in str(value):
                return True
    return any(re.search(r"(RUSTC_WRAPPER|rustc-wrapper)\S*\s*=?\s*\S*sccache", text) for text in _texts(document, job))


def sccache_namespaces(document: dict, job: dict) -> list[str]:
    values = []
    for scope in [document, job, *(job.get("steps") or [])]:
        for key, value in ((scope.get("env") or {}) if isinstance(scope, dict) else {}).items():
            if SCCACHE_NAMESPACE.match(str(key)):
                values.append(str(value))
    for text in _texts(document, job):
        values += re.findall(r"SCCACHE_(?:[A-Z0-9]+_)?(?:KEY_PREFIX|DIR)=([^\s;&|]+)", text)
    return values


def is_release_namespace(value: str) -> bool:
    return value.strip("'\"").startswith(RELEASE_SCCACHE_PREFIX) or RELEASE_SCCACHE_DIR in value


def sensitive(path_name: str, document: dict, job: dict) -> bool:
    permissions = [document.get("permissions"), job.get("permissions")]
    oidc = any(isinstance(p, dict) and p.get("id-token") == "write" for p in permissions) or "write-all" in permissions
    return oidc or workflow_jobs.holds_secret(job) or bool(RELEASE_NAME.search(path_name))


def sccache_namespace_failures(root: Path) -> tuple[list[str], int]:
    found, enabled = sccache_namespace_findings(root)
    return [finding.text for finding in found], enabled


def sccache_namespace_findings(root: Path) -> tuple[list[Finding], int]:
    """Rule 2, and how many jobs turn sccache on."""
    failures: list[Finding] = []
    enabled = 0
    for path in sorted((root / ".github/workflows").glob("*.y*ml")):
        document = workflow_jobs.document(path)
        from_pull_request = bool(triggers(document) & PULL_REQUEST)
        for job_name, job in (document.get("jobs") or {}).items():
            namespaces = sccache_namespaces(document, job)
            release_ns = any(is_release_namespace(value) for value in namespaces)
            if from_pull_request and release_ns:
                failures.append(Finding(
                    f"pull-request-names-release-sccache|{path.name}|{job_name}",
                    f"{path.name} {job_name}: a job a pull request can start names the release-only sccache "
                    f"namespace ({RELEASE_SCCACHE_PREFIX!r} / {RELEASE_SCCACHE_DIR!r}); only release jobs write it", True))
            if not enables_sccache(document, job):
                continue
            enabled += 1
            if not from_pull_request and sensitive(path.name, document, job) and not release_ns:
                failures.append(Finding(
                    f"release-sccache-shared-namespace|{path.name}|{job_name}",
                    f"{path.name} {job_name}: a release or secret-holding job turns sccache on without the "
                    f"release-only namespace: set SCCACHE_<BACKEND>_KEY_PREFIX to '{RELEASE_SCCACHE_PREFIX}...' "
                    f"or SCCACHE_DIR to a '{RELEASE_SCCACHE_DIR}' directory (one cold fill)", False))
    return failures, enabled


def release_cache_steps(root: Path) -> int:
    """The cache steps in jobs no pull request starts that hold secrets or release: the readers this guard protects."""
    count = 0
    for path in sorted((root / ".github/workflows").glob("*.y*ml")):
        document = workflow_jobs.document(path)
        if triggers(document) & PULL_REQUEST:
            continue
        for job in (document.get("jobs") or {}).values():
            if not sensitive(path.name, document, job):
                continue
            for step in job.get("steps") or []:
                uses = str(step.get("uses", "")).lower()
                if "cache" in uses or uses.startswith(("actions/setup-go", "mlugg/setup-zig")):
                    count += 1
    return count


def findings(root: Path) -> list[Finding]:
    return base_context_findings(root) + sccache_namespace_findings(root)[0]


def introduced(head: list[Finding], base: list[Finding] | None) -> list[Finding]:
    """The poisoned-cache findings at head that the base lacks (all of them when there is no base)."""
    known = {finding.key for finding in base or []}
    return [finding for finding in head if finding.blocking and finding.key not in known]


def _git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def tree_at(revision: str, repo: Path = ROOT) -> Path:
    """The revision's .github/ in a temporary directory, read from git (no checkout)."""
    target = Path(tempfile.mkdtemp(prefix="release-cache-base-"))
    archive = subprocess.run(["git", "archive", "--format=tar", revision, ".github"], cwd=repo, check=True,
                             capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(target, filter="data")
        else:  # git archive's own output: no absolute or parent paths
            tar.extractall(target)
    return target


def base_revision(repo: Path = ROOT) -> str:
    """The commit this change is judged against, or "" when none is readable."""
    explicit = os.environ.get("CMUX_RELEASE_CACHE_TRUST_BASE", "").strip()
    candidates = [explicit] if explicit and not re.fullmatch(r"0+", explicit) else []
    candidates.append("HEAD^1")
    for candidate in candidates:
        try:
            commit = _git("rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}", cwd=repo)
        except subprocess.CalledProcessError:
            if candidate == explicit and re.fullmatch(r"[0-9a-f]{40}", candidate):
                with contextlib.suppress(subprocess.CalledProcessError):
                    _git("fetch", "--no-tags", "--depth=1", "origin", candidate, cwd=repo)
                    commit = _git("rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}", cwd=repo)
                    return _merge_base(commit, repo)
            continue
        return _merge_base(commit, repo)
    return ""


def _merge_base(commit: str, repo: Path) -> str:
    try:
        return _git("merge-base", commit, "HEAD", cwd=repo) or commit
    except subprocess.CalledProcessError:
        return commit


def base_findings(revision: str, repo: Path = ROOT) -> list[Finding] | None:
    if not revision:
        return None
    try:
        return findings(tree_at(revision, repo))
    except (subprocess.CalledProcessError, yaml.YAMLError, OSError, ValueError) as error:
        print(f"release cache trust: cannot read the base {revision[:12]} ({error}); every poisoned-cache finding counts as new")
        return None


def _tree(files: dict[str, str]) -> Path:
    import tempfile
    root = Path(tempfile.mkdtemp(prefix="release-cache-guard-"))
    for relative, text in files.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    return root


CACHE = "uses: actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae\n        with: {path: x, key: k}"
RESTORE = "uses: actions/cache/restore@27d5ce7f107fe9357f9df03efb73ab90386fccae\n        with: {path: x, key: k}"


def _workflow(trigger: str, step: str, job_extra: str = "", env: str = "") -> str:
    return (f"on: {trigger}\n{env}jobs:\n  build:\n    runs-on: ubuntu-24.04\n{job_extra}"
            f"    steps:\n      - name: s\n        {step}\n")


class ReleaseCachesTrustedWriters(unittest.TestCase):
    def test_repository_introduces_no_poisoned_cache(self):
        failures = [finding.text for finding in introduced(findings(ROOT), base_findings(base_revision()))]
        if MODE != "enforce":
            self.skipTest(f"report-only: {len(failures)} new poisoned-cache finding(s)")
        self.assertEqual(failures, [], "\n".join(failures))

    def test_new_poisoned_cache_fails(self):
        base = _tree({".github/workflows/w.yml": _workflow("pull_request_target", RESTORE)})
        head = _tree({".github/workflows/w.yml": _workflow("pull_request_target", CACHE)})
        self.assertEqual(len(introduced(findings(head), findings(base))), 1)
        self.assertEqual(len(introduced(findings(head), None)), 1)

    def test_poisoned_cache_on_base_reports_only(self):
        base = _tree({".github/workflows/w.yml": _workflow("pull_request_target", CACHE)})
        # The same save, its step renamed: still the base's finding, not a new one.
        head = _tree({".github/workflows/w.yml": _workflow("pull_request_target", CACHE).replace("name: s", "name: renamed")})
        self.assertEqual(len(findings(head)), 1)
        self.assertEqual(introduced(findings(head), findings(base)), [])

    def test_new_low_severity_finding_reports_only(self):
        wrapper = "run: cargo build\n        env: {RUSTC_WRAPPER: sccache}"
        base = _tree({".github/workflows/tui-release.yml": _workflow("push", "run: cargo build")})
        head = _tree({".github/workflows/tui-release.yml": _workflow("push", wrapper)})
        self.assertEqual([finding.blocking for finding in findings(head)], [False])
        self.assertEqual(introduced(findings(head), findings(base)), [])

    def test_base_is_read_from_git(self):
        repo = _tree({".github/workflows/w.yml": _workflow("pull_request_target", RESTORE)})
        identity = ["-c", "user.name=t", "-c", "user.email=t@example.com"]
        _git("init", "-q", cwd=repo)
        _git("add", ".", cwd=repo)
        _git(*identity, "commit", "-qm", "base", cwd=repo)
        (repo / ".github/workflows/w.yml").write_text(_workflow("pull_request_target", CACHE), encoding="utf-8")
        _git(*identity, "commit", "-qam", "head", cwd=repo)
        with unittest.mock.patch.dict(os.environ, {"CMUX_RELEASE_CACHE_TRUST_BASE": ""}):
            base = base_revision(repo)
        self.assertEqual(base, _git("rev-parse", "HEAD^1", cwd=repo))
        self.assertEqual(base_findings(base, repo), [])
        self.assertEqual(len(introduced(findings(repo), base_findings(base, repo))), 1)

    def test_reads_the_real_tree(self):
        # The guard reads the workflows that hold the risk, or it proves nothing.
        self.assertTrue((ROOT / ".github/workflows/backend-migrations.yml").exists())
        self.assertGreater(release_cache_steps(ROOT), 0)

    def test_pull_request_target_save_fails(self):
        root = _tree({".github/workflows/w.yml": _workflow("pull_request_target", CACHE)})
        self.assertEqual(len(base_context_saves(root)), 1)

    def test_report_fails_only_a_new_poisoned_cache_in_enforce_mode(self):
        root = _tree({".github/workflows/w.yml": _workflow("pull_request_target", CACHE)})
        for mode, base, failing, label in (("enforce", None, 1, "::error title=Release cache trust (new poisoned cache)::"),
                                           ("enforce", findings(root), 0, "(already on the base)::"),
                                           ("report", None, 0, "(new poisoned cache, report mode)::")):
            with self.subTest(mode=mode, base=base), unittest.mock.patch(f"{__name__}.MODE", mode), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(len(report(root, base)), failing)
                self.assertIn(label, out.getvalue())

    def test_pull_request_target_restore_passes(self):
        root = _tree({".github/workflows/w.yml": _workflow("pull_request_target", RESTORE)})
        self.assertEqual(base_context_saves(root), [])

    def test_pull_request_save_is_ref_scoped(self):
        root = _tree({".github/workflows/w.yml": _workflow("pull_request", CACHE)})
        self.assertEqual(base_context_saves(root), [])

    def test_save_in_local_action_and_called_workflow_fails(self):
        root = _tree({
            ".github/actions/warm/action.yml": "runs:\n  using: composite\n  steps:\n    - " + CACHE.replace("\n        ", "\n      ") + "\n",
            ".github/workflows/caller.yml": "on: workflow_run\njobs:\n  call:\n    uses: ./.github/workflows/callee.yml\n",
            ".github/workflows/callee.yml": _workflow("workflow_call", "uses: ./.github/actions/warm"),
        })
        failures = base_context_saves(root)
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("called from caller.yml", failures[0])
        self.assertIn("./.github/actions/warm > actions/cache", failures[0])

    def test_push_only_step_and_implicit_caches(self):
        gated = CACHE + "\n        if: github.event_name == 'push'"
        root = _tree({".github/workflows/a.yml": _workflow("[pull_request_target, push]", gated)})
        self.assertEqual(base_context_saves(root), [])
        for step, saves in (("uses: actions/setup-go@v5", True), ("uses: actions/setup-go@v5\n        with: {cache: false}", False),
                            ("uses: actions/setup-node@v4", False), ("uses: actions/setup-node@v4\n        with: {cache: npm}", True),
                            ("uses: Swatinem/rust-cache@v2\n        with: {save-if: false}", False), ("uses: Swatinem/rust-cache@v2", True),
                            ("uses: mlugg/setup-zig@v2", True), ("uses: mlugg/setup-zig@v2\n        with: {use-cache: false}", False)):
            with self.subTest(step=step):
                root = _tree({".github/workflows/w.yml": _workflow("issue_comment", step)})
                self.assertEqual(bool(base_context_saves(root)), saves)

    def test_release_job_sccache_needs_release_namespace(self):
        wrapper = "run: cargo build\n        env: {RUSTC_WRAPPER: sccache}"
        root = _tree({".github/workflows/tui-release.yml": _workflow("push", wrapper)})
        failures, enabled = sccache_namespace_failures(root)
        self.assertEqual((len(failures), enabled), (1, 1), failures)
        root = _tree({".github/workflows/tui-release.yml": _workflow(
            "push", wrapper, env="env: {SCCACHE_GCS_KEY_PREFIX: release/sccache/v1}\n")})
        self.assertEqual(sccache_namespace_failures(root), ([], 1))

    def test_pull_request_job_may_not_name_release_namespace(self):
        step = "run: SCCACHE_S3_KEY_PREFIX=release/v1 RUSTC_WRAPPER=sccache cargo build"
        root = _tree({".github/workflows/ci.yml": _workflow("pull_request", step)})
        failures, _ = sccache_namespace_failures(root)
        self.assertEqual(len(failures), 1, failures)
        root = _tree({".github/workflows/ci.yml": _workflow("pull_request", step.replace("release/", "pr/"))})
        self.assertEqual(sccache_namespace_failures(root)[0], [])


def report(root: Path, base: list[Finding] | None = None, base_name: str = "none") -> list[Finding]:
    """Print the counts, annotate each finding, write the step summary, and return the ones that fail."""
    found = findings(root)
    new = introduced(found, base)
    failing = new if MODE == "enforce" else []
    _, enabled = sccache_namespace_findings(root)
    print(f"release or secret-holding cache steps: {release_cache_steps(root)}; "
          f"base-context cache saves: {len(base_context_findings(root))}; jobs with sccache on: {enabled}; "
          f"findings: {len(found)}, new poisoned caches: {len(new)} (base {base_name[:12]}); mode: {MODE}")
    lines = []
    for finding in found:
        if finding in failing:
            level, why = "error", "new poisoned cache"
        elif finding in new:
            level, why = "warning", "new poisoned cache, report mode"
        elif finding.blocking:
            level, why = "warning", "already on the base"
        else:
            level, why = "warning", "lower severity"
        print(f"::{level} title=Release cache trust ({why})::{finding.text}")
        lines.append(f"- {why}: {finding.text}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"### Release cache trust ({MODE})\n\n")
            out.write("".join(lines) or "No findings.\n")
    return failing


if __name__ == "__main__":
    base = base_revision()
    failing = report(ROOT, base_findings(base), base or "none")
    result = unittest.main(exit=False).result
    if not result.wasSuccessful() or failing:
        sys.exit(1)
