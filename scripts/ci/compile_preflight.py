#!/usr/bin/env python3
"""The compile preflight's two steps (.github/workflows/cmux-next-compile-preflight.yml).

Leo, 2026-11-27: "surely we can just have legit build fail preflight checks" / "like the classes of failures before
we can analyze them".

  web-touched ROOT BASE HEAD   prints `web=true` when a file BASE..HEAD changes is one web-bundle-key.py --routed
                               names (the web bundles' own inputs, imports outside webviews/ included), else
                               `web=false`; the reason goes to stderr.
  never-web-check ROOT         exits 1 naming each web bundle input (every file web-bundle-key.py --routed names, and
                               any file under its directory inputs) that pr_router.json's compile preflight
                               `paths-ignore` ignores: pr-router.yml skips this job on a change made only of such
                               paths, so one that is a web input would turn the build off for a change to it.
  merge-live-base ROOT BASE PR  re-merges the pull request's head onto the base branch's tip as it is now (the
                               checkout's merge commit is GitHub's, computed when the head last moved: cmux#51044's
                               was 73 min behind the base, so it did not see the `layoutGeometry` import #60849
                               landed, and the preflight passed a head that broke the base). Leaves HEAD a merge
                               commit whose first parent is the live tip; exits 1 on a conflict.
  web-build ROOT OUT           runs scripts/cmux-next/build-web-bundles.sh --out-root OUT (the build the app,
                               NIGHTLY and safe-push.sh run) and, when it fails, names each bundler error as a
                               GitHub annotation, then exits with the build's code.

A file that reaches no web bundle (a gallery is an input too: webviews/ is a whole-directory input) builds nothing.
"""
from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import re
import resource
import subprocess
import sys
import time
from pathlib import Path

KEY_SCRIPT = "scripts/cmux-next/web-bundle-key.py"
BUILD_SCRIPT = "scripts/cmux-next/build-web-bundles.sh"
# A bundler's error line: esbuild's `✘ [ERROR] ...` and `file:line:col: ERROR: ...`, the react-compiler plugin's
# text inside them, tsc's or a script's `error: ...` (cmux#57269: "Identifier 'layoutGeometry' has already been
# declared"; cmux#46930: `Could not resolve "../../components/SignInButton"`).
ERROR_LINE = re.compile(r"\[ERROR\]|: ERROR: |^error: |Could not resolve")
MAX_ANNOTATIONS = 10


def key_module(root: Path):
    """web-bundle-key.py of the checkout at ROOT, loaded as a module (its name has dashes)."""
    spec = importlib.util.spec_from_file_location("web_bundle_key", root / KEY_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def changed_files(root: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--no-renames", base, head],
                         check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def web_touched(files: list[str], routed: list[str], matcher_of) -> list[str]:
    """The FILES a web bundle reads: those any ROUTED pathspec matches (matcher_of is web-bundle-key's
    pathspec_matcher)."""
    matches = matcher_of(routed)
    return [f for f in files if matches(f)]


def cmd_web_touched(root: Path, base: str, head: str) -> int:
    module = key_module(root)
    files = changed_files(root, base, head)
    hit = web_touched(files, module.routed_inputs(str(root)), module.pathspec_matcher)
    if hit:
        more = f" and {len(hit) - 1} more" if len(hit) > 1 else ""
        print(f"web bundle sources changed: {hit[0]}{more}", file=sys.stderr)
    else:
        print(f"none of the {len(files)} changed files is a web bundle input", file=sys.stderr)
    print(f"web={'true' if hit else 'false'}")
    return 0


# The router's answer (pr_router.py preflight_web) is this job's own web-touched answer, computed in pr-router.yml's
# route job before a runner is taken: about 60% of the web bundle build jobs the router's directory supersets started
# found no web bundle input (99 of 164 web-routed feat-cmux-next commits, 2026-11-27: a Swift source or a
# scripts/cmux-next tool under the `affects` dirs), each a runner for ~43 s. Leo, 2026-11-27: "de facto, im asking
# for 99% fewer minutes of ci time, period." The route job's checkout is sparse, so router_web first answers what
# needs no webviews/ file (a webviews/ change or a static INPUTS path is web; nothing else is decided without the
# import scan), then checks out webviews/ (the mirror serves whole blobs: about 0.5 s) and every file outside it that
# a scanned import names (rounds, until imported_inputs finds nothing the index has that the disk lacks), so
# imported_inputs reads the same files as the full checkout's. Anything it cannot read answers None: the router
# then runs the job, whose own web-touched step decides as before.
ROUTER_ROUNDS = 6
ROUTER_MAX_PATHS = 2000
ROUTER_GIT_TIMEOUT_S = 90


def _git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True,
                          timeout=ROUTER_GIT_TIMEOUT_S).stdout


def partial_clone(root: Path) -> bool:
    """Whether ROOT's clone filters blobs (a fork's or a push's route checkout): a sparse add would fetch each
    webviews/ blob from GitHub, so the router does not try."""
    try:
        return bool(_git(root, "config", "--get-regexp", r"^(remote\..*\.promisor|extensions\.partialclone)$").strip())
    except subprocess.CalledProcessError:
        return False


def sparse_pattern(path: str) -> str:
    """A non-cone sparse-checkout pattern for exactly PATH (a directory when it ends in `/`), anchored at the root."""
    return "/" + re.sub(r"([\\*?\[\]!#])", r"\\\1", path)


def sparse_add(root: Path, paths: list[str]) -> None:
    _git(root, "sparse-checkout", "add", "--skip-checks", *[sparse_pattern(p) for p in paths])


def absent_imports(root: Path, module, found: list[str]) -> list[str]:
    """Tracked files the import scan could have read or resolved to but the sparse disk lacks: for each FOUND pathspec
    (imported_inputs) that is not on disk, the index's files for each candidate resolve() tries (and the directory)."""
    candidates = []
    for spec in found:
        if spec.startswith(":(") or (root / spec).exists():
            continue
        candidates += [spec + s for s in module.FILE_SUFFIXES] + [spec + s for s in module.INDEX_FILES]
    if not candidates:
        return []
    listed = _git(root, "ls-files", "-z", "--", *candidates)
    return sorted({p for p in listed.split("\0") if p and not (root / p).exists()})


def router_web(root: Path, files: list[str], add=sparse_add) -> tuple[bool | None, str]:
    """(web-touched's answer for FILES at ROOT's checkout, why); (None, why) when it cannot be read here. ADD checks
    paths out of a sparse checkout (tests pass a fake)."""
    module = key_module(root)
    static = module.pathspec_matcher([p for p in module.INPUTS if p != module.CATALOG_GLOB])
    hit = [f for f in files if static(f)]
    if hit:
        return True, f"{hit[0]} is a web bundle input (web-bundle-key.py INPUTS)"
    if partial_clone(root):
        return None, "this checkout filters blobs, so the import scan cannot read webviews/ here"
    if not (root / "webviews").is_dir():
        add(root, ["webviews/"])
    module.unresolved = lambda message: None  # the job's own web-touched step reports them
    for _ in range(ROUTER_ROUNDS):
        absent = absent_imports(root, module, module.imported_inputs(str(root)))
        if not absent:
            break
        if len(absent) > ROUTER_MAX_PATHS:
            return None, f"the imports name {len(absent)} files outside webviews/, more than the router checks out"
        add(root, absent)
    else:
        return None, f"imports still name files the sparse checkout lacks after {ROUTER_ROUNDS} rounds"
    hit = web_touched(files, module.routed_inputs(str(root)), module.pathspec_matcher)
    if hit:
        return True, f"{hit[0]} is a web bundle input (web-bundle-key.py --routed)"
    return False, f"none of the {len(files)} changed files is a web bundle input (web-bundle-key.py --routed)"


ROUTER_MANIFEST = "scripts/ci/pr_router.json"
PREFLIGHT_CALLEE = "cmux-next-compile-preflight.yml"
# A file of each ignored kind under a directory input: a new file there must still start the job.
PROBE_NAMES = ("probe.rs", "Cargo.toml", "Cargo.lock", "Probe.swift", "probe.py", "probe.md", "probe.yml")


def router_ignores(root: Path):
    """A predicate: True for a path pr_router.json's compile preflight `paths-ignore` ignores (GitHub's filter
    semantics, scripts/ci/workflow_paths_cover_inputs.py admits, as pr_router.py matches_filter reads them)."""
    import json

    patterns = json.loads((root / ROUTER_MANIFEST).read_text())["callees"][PREFLIGHT_CALLEE].get("paths-ignore") or []
    spec = importlib.util.spec_from_file_location("workflow_paths_cover_inputs",
                                                  root / "scripts/ci/workflow_paths_cover_inputs.py")
    filters = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = filters  # its dataclasses look their module up here
    spec.loader.exec_module(filters)
    return lambda path: bool(patterns) and not filters.admits("paths-ignore", patterns, path)


def never_web_problems(root: Path, routed: list[str], ignored) -> list[str]:
    """The web bundle inputs (ROUTED pathspecs: their tracked files, and a probe file of each ignored kind under each
    directory input) the IGNORED predicate skips."""
    listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *routed], check=True,
                            capture_output=True, text=True).stdout
    paths = [p for p in listed.split("\0") if p]
    for spec in routed:
        if not spec.startswith(":(") and (root / spec).is_dir():
            paths += [f"{spec.rstrip('/')}/{name}" for name in PROBE_NAMES]
    return sorted({p for p in paths if ignored(p)})


def cmd_never_web_check(root: Path) -> int:
    routed = key_module(root).routed_inputs(str(root))
    problems = never_web_problems(root, routed, router_ignores(root))
    for path in problems[:MAX_ANNOTATIONS]:
        print(f"::error title=compile preflight paths-ignore::{path} is a web bundle input (web-bundle-key.py --routed) "
              f"that {ROUTER_MANIFEST}'s {PREFLIGHT_CALLEE} paths-ignore skips; add a `!{path}` line there")
    if problems:
        print(f"compile preflight: {len(problems)} web bundle input(s) the router would skip", file=sys.stderr)
        return 1
    print(f"compile preflight: no web bundle input ({len(routed)} pathspecs) is a path the router skips", file=sys.stderr)
    return 0


def error_lines(log: str) -> list[str]:
    """The bundler error lines of a failed build's LOG, deduplicated, first MAX_ANNOTATIONS."""
    seen: list[str] = []
    for line in log.splitlines():
        text = line.strip()
        if ERROR_LINE.search(text) and text not in seen:
            seen.append(text)
    return seen[:MAX_ANNOTATIONS]


DEPTHS = (300, 2000, 20000)


def git_run(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    cmd = ["git", "-C", str(root)]
    token = os.environ.get("GIT_AUTH_TOKEN", "")
    if token and args and args[0] == "fetch":
        import base64
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        cmd += ["-c", f"http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}"]
    return subprocess.run(cmd + list(args), check=check, capture_output=True, text=True)


def cmd_merge_live_base(root: Path, base_ref: str, pr: str) -> int:
    head = git_run(root, "rev-parse", "-q", "--verify", "HEAD^2", check=False)
    if head.returncode != 0:
        print("merge-live-base: HEAD is not a merge commit; nothing to re-merge", file=sys.stderr)
        return 0
    head_sha = head.stdout.strip()
    old_base = git_run(root, "rev-parse", "HEAD^1").stdout.strip()
    # Only a shallow checkout fetches shallow: a full clone must not turn shallow.
    shallow = git_run(root, "rev-parse", "--is-shallow-repository", check=False).stdout.strip() == "true"
    git_run(root, "fetch", "--no-tags", *(["--depth=1"] if shallow else []), "origin", f"+refs/heads/{base_ref}:refs/remotes/origin/{base_ref}")
    tip = git_run(root, "rev-parse", f"refs/remotes/origin/{base_ref}").stdout.strip()
    if tip == old_base:
        print(f"merge-live-base: the merge commit's base {tip[:12]} is the live tip", file=sys.stderr)
        return 0
    git_run(root, "checkout", "-q", "--detach", tip)
    merged = None
    for depth in DEPTHS:
        git_run(root, "fetch", "--no-tags", *([f"--depth={depth}"] if shallow else []), "origin", tip, f"+refs/pull/{pr}/head:refs/remotes/pull/{pr}/head")
        merged = git_run(root, "-c", "user.name=cmux-ci", "-c", "user.email=ci@cmux.invalid", "merge", "--no-ff",
                         "--no-edit", "-m", f"Merge {head_sha} into {tip}", head_sha, check=False)
        if merged.returncode == 0 or "unrelated histories" not in (merged.stderr + merged.stdout):
            break
    if merged is None or merged.returncode != 0:
        text = ((merged.stdout + merged.stderr) if merged else "").strip().splitlines()[-1:] or ["merge failed"]
        print(f"::error title=live base merge::this head does not merge onto {base_ref} {tip[:12]}: {text[0]}")
        return 1
    print(f"merge-live-base: built on {base_ref} {tip[:12]}, not the checkout's {old_base[:12]}")
    return 0


def cmd_web_build(root: Path, out: str) -> int:
    source = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                            capture_output=True, text=True)
    source_sha = source.stdout.strip() if source.returncode == 0 else None
    started = time.monotonic()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.Popen(["bash", str(root / BUILD_SCRIPT), "--out-root", out], cwd=root,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    log = []
    for line in proc.stdout:
        sys.stdout.write(line)
        log.append(line)
    code = proc.wait()
    took = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    print("CMUX_WEB_BUILD " + json.dumps({
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "source_sha": source_sha,
        "event_sha": os.environ.get("GITHUB_SHA"),
        "source_key": os.environ.get("CMUX_WEB_SOURCE_KEY"),
        "job": os.environ.get("GITHUB_JOB"),
        "builds": 1, "exit_code": code, "wall_seconds": round(took, 3),
        "cpu_seconds": round(after.ru_utime + after.ru_stime - usage.ru_utime - usage.ru_stime, 3),
    }, sort_keys=True))
    if code == 0:
        print(f"compile preflight: the web bundles built in {took:.0f} s")
        return 0
    errors = error_lines("".join(log)) or [f"{BUILD_SCRIPT} exited {code}"]
    for text in errors:
        print(f"::error title=web bundle build::{text}")
    print(f"compile preflight: the web bundle build failed in {took:.0f} s (exit {code}); this change would turn "
          f"feat-cmux-next's web bundles and NIGHTLY red")
    return code or 1


def artifact_manifest(directory: Path, key: str) -> dict:
    """Bind the source/toolchain key to every transported output, not a runner-local stamp."""
    return {"source_key": key, "files": {
        path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(directory.rglob("*"))
        if path.is_file() and path.name != "cmux-web-artifact.json"
    }}


def cmd_artifact(mode: str, directory: Path, key: str) -> int:
    manifest = directory / "cmux-web-artifact.json"
    current = artifact_manifest(directory, key)
    if not current["files"]:
        raise ValueError("web artifact has no outputs")
    if mode == "write":
        manifest.write_text(json.dumps(current, sort_keys=True) + "\n")
    elif json.loads(manifest.read_text()) != current:
        raise ValueError("web artifact source key or output digest mismatch")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[1] == "web-touched":
        return cmd_web_touched(Path(argv[2]).resolve(), argv[3], argv[4])
    if len(argv) == 3 and argv[1] == "never-web-check":
        return cmd_never_web_check(Path(argv[2]).resolve())
    if len(argv) == 5 and argv[1] == "merge-live-base":
        return cmd_merge_live_base(Path(argv[2]).resolve(), argv[3], argv[4])
    if len(argv) == 4 and argv[1] == "web-build":
        return cmd_web_build(Path(argv[2]).resolve(), argv[3])
    if len(argv) == 5 and argv[1] == "web-artifact" and argv[2] in {"write", "verify"}:
        return cmd_artifact(argv[2], Path(argv[3]).resolve(), argv[4])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    sys.exit(main(sys.argv))
