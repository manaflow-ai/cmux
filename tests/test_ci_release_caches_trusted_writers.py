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
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

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
    """Rule 1: every cache save a base-context trigger can reach, as 'workflow job: step: action'."""
    workflows = {path.name: workflow_jobs.document(path) for path in sorted((root / ".github/workflows").glob("*.y*ml"))}
    failures: list[str] = []
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
                    failures.append(f"{where} {job_name}: '{step.get('name') or step.get('uses')}' saves a cache ({hit}); "
                                    "a base-context job's save is read by every release build, so restore only")
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
    """Rule 2, and how many jobs turn sccache on."""
    failures: list[str] = []
    enabled = 0
    for path in sorted((root / ".github/workflows").glob("*.y*ml")):
        document = workflow_jobs.document(path)
        from_pull_request = bool(triggers(document) & PULL_REQUEST)
        for job_name, job in (document.get("jobs") or {}).items():
            namespaces = sccache_namespaces(document, job)
            release_ns = any(is_release_namespace(value) for value in namespaces)
            if from_pull_request and release_ns:
                failures.append(f"{path.name} {job_name}: a job a pull request can start names the release-only sccache "
                                f"namespace ({RELEASE_SCCACHE_PREFIX!r} / {RELEASE_SCCACHE_DIR!r}); only release jobs write it")
            if not enables_sccache(document, job):
                continue
            enabled += 1
            if not from_pull_request and sensitive(path.name, document, job) and not release_ns:
                failures.append(f"{path.name} {job_name}: a release or secret-holding job turns sccache on without the "
                                f"release-only namespace: set SCCACHE_<BACKEND>_KEY_PREFIX to '{RELEASE_SCCACHE_PREFIX}...' "
                                f"or SCCACHE_DIR to a '{RELEASE_SCCACHE_DIR}' directory (one cold fill)")
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
    def test_repository_has_no_base_context_cache_save(self):
        failures = base_context_saves(ROOT)
        self.assertEqual(failures, [], "\n".join(failures))

    def test_repository_sccache_namespaces(self):
        failures, _ = sccache_namespace_failures(ROOT)
        self.assertEqual(failures, [], "\n".join(failures))

    def test_reads_the_real_tree(self):
        # The guard reads the workflows that hold the risk, or it proves nothing.
        self.assertTrue((ROOT / ".github/workflows/backend-migrations.yml").exists())
        self.assertGreater(release_cache_steps(ROOT), 0)

    def test_pull_request_target_save_fails(self):
        root = _tree({".github/workflows/w.yml": _workflow("pull_request_target", CACHE)})
        self.assertEqual(len(base_context_saves(root)), 1)

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


if __name__ == "__main__":
    failures, enabled = sccache_namespace_failures(ROOT)
    print(f"release or secret-holding cache steps: {release_cache_steps(ROOT)}; "
          f"base-context cache saves: {len(base_context_saves(ROOT))}; jobs with sccache on: {enabled}")
    unittest.main()
