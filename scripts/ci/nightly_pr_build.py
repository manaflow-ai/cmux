#!/usr/bin/env python3
"""The NIGHTLY's own app compile and Rust helper builds, on a pull request (.github/workflows/nightly-pr-build.yml).

The ordinary pull request checks compile the app in Debug or plain Release. The Nightly uses
-DCMUX_BLOCKING_CHECKS and -Osize (hot targets at -O) for arm64 and x86_64, and it builds its Rust
helpers in release with their own features. This runs the Nightly's settings on the pull request,
advisory: no rule requires its checks.

  route --base B --rev R
                    print `swift=true|false` and `helpers=true|false`: whether the commits
                    B..R change what the app compile (SWIFT_INPUTS) or a helper (HELPER_INPUTS)
                    is built from.
  keys --rev SHA    print `keys=<json>` for $GITHUB_OUTPUT: one input key per Swift arch
                    (scripts/ci/job_input_fingerprint.py job nightly-pr-build) and one for the
                    helpers. A pass saves its key as an actions/cache entry; a later run whose
                    inputs are the same finds it and skips the build.
  base-red --rev SHA --base-tip SHA
                    print `base_red=<url>` when the newest Nightly compile red on any pull request (artifact
                    nightly-app-compile-red) was the base's, and SHA still has its failing files as that base had
                    them, so building SHA would only repeat it; else print nothing. Fails open.
  helpers           cargo check --release --locked each helper the Nightly bundles, with the
                    features and profile its build script passes (HELPERS), on this host's target.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import job_input_fingerprint  # noqa: E402

ARCHS = ("arm64", "x86_64")
WORKFLOW = ".github/workflows/nightly-pr-build.yml"

# Each Rust helper the Nightly bundles (scripts/ci/nightly-steps/app-build-mobile-host.sh and
# chief-build.sh), as its build script builds it: the working directory, the cargo arguments past
# `build --locked --release --target T`, and the release profile it sets. tests/test_nightly_pr_build.py
# reads the build scripts and fails when one of these no longer matches them.
HELPERS = (
    {
        "name": "cmux-rd (Screen Sharing helper)",
        "script": "scripts/cmux-next/build-screen-sharing-helper.sh",
        "dir": "cmux-tui/crates/cmux-rd-host",
        "args": ["--no-default-features", "--features", "link computer-use", "--bin", "cmux-rd"],
        "profile": {"CARGO_PROFILE_RELEASE_LTO": "fat", "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "1",
                    "CARGO_PROFILE_RELEASE_DEBUG": "0"},
    },
    {
        "name": "cmux-mobile-host",
        "script": "scripts/cmux-next/build-mobile-host.sh",
        "dir": "cmux-next-ios/rust",
        "args": ["--package", "cmux-mobile-host", "--bin", "cmux-mobile-host"],
        "profile": {"CARGO_PROFILE_RELEASE_LTO": "fat", "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "1",
                    "CARGO_PROFILE_RELEASE_PANIC": "abort"},
    },
    {
        "name": "optchat-chief",
        "script": "scripts/cmux-next/build-optchat-chief.sh",
        "dir": "Native/OptChat/optchat-chief",
        "args": ["--bin", "optchat-chief"],
        "profile": {},
    },
)

# What the helpers compile from: their trees, the cmux-tui crates they use by path, the toolchain pins
# and this check itself. The key is these paths' object ids at the commit.
HELPER_INPUTS = (
    "cmux-tui", "cmux-next-ios/rust", "Native/OptChat", "Native/DiffSidecar", ".cargo",
    ".github/actions/setup-cmux-tui-rust", ".github/actions/runner-cargo-home", "scripts/ci/toolchain-r2.sh",
    *(helper["script"] for helper in HELPERS), "scripts/ci/nightly_pr_build.py", WORKFLOW,
)


# What the app compile reads, as fnmatch patterns ("*" spans folders): the packages and what they
# vendor, the app resources, the Xcode pin and check-release-compile.sh with what it sources
# (cmux_next_route.MAC_RELEASE_INPUTS), and this check. Test targets never count
# (job_input_fingerprint.PRODUCT_EXCLUDES).
SWIFT_INPUTS = (
    "Packages/*", "vendor/*", "ghostty", "ghostty-next", ".gitmodules", ".xcode-version", "Resources/*",
    "scripts/cmux-next/check-release-compile.sh", "scripts/cmux-next/lib/*", "scripts/ci/xcode-pins.txt",
    "scripts/select-ci-xcode.sh", "scripts/ci/nightly_pr_build.py", "scripts/ci/job_input_fingerprint.py",
    "scripts/ci/run-xcodebuild-with-diagnostics.sh", "scripts/ci/swiftpm-binary-module-guard.sh",
    "scripts/ci/cmux_next_route.py", WORKFLOW,
)


def excluded(path: str) -> bool:
    parts = path.split("/")
    return any(job_input_fingerprint.product_excluded("/".join(parts[:n])) for n in range(1, len(parts) + 1))


def swift_input(path: str) -> bool:
    if excluded(path) and path != WORKFLOW:
        return False
    return (any(fnmatch.fnmatchcase(path, pattern) for pattern in SWIFT_INPUTS)
            or job_input_fingerprint.route.mac_release_input(path))


def helper_input(path: str) -> bool:
    return any(path == root or path.startswith(root + "/") for root in HELPER_INPUTS)


def route(paths: list[str]) -> dict[str, bool]:
    return {"swift": any(map(swift_input, paths)), "helpers": any(map(helper_input, paths))}


def git(*args: str, root: Path = ROOT) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def helper_key(rev: str, root: Path = ROOT, recipe_rev: str | None = None) -> str:
    recipe = recipe_rev or rev
    source_inputs = [path for path in HELPER_INPUTS
                     if path not in {"scripts/ci/nightly_pr_build.py", WORKFLOW}]
    ids = job_input_fingerprint.object_ids(str(root), rev, source_inputs)
    ids.update(job_input_fingerprint.object_ids(str(root), recipe,
                                                ["scripts/ci/nightly_pr_build.py", WORKFLOW]))
    raw = json.dumps({"job": "nightly-pr-build-helpers", "inputs": ids, "helpers": HELPERS}, sort_keys=True)
    return "nightly-pr-build-helpers-" + hashlib.sha256(raw.encode()).hexdigest()


def keys(rev: str, root: Path = ROOT, recipe_rev: str | None = None) -> dict[str, str]:
    out = {}
    for arch in ARCHS:
        key, _ = job_input_fingerprint.fingerprint(
            str(root), rev, "nightly-pr-build", [f"arch={arch}"],
            workflow_rev=recipe_rev, recipe_rev=recipe_rev)
        out[arch] = f"nightly-pr-build-{arch}-{key}"
    out["helpers"] = helper_key(rev, root, recipe_rev)
    return out


# Base-red skip for the app compile. On 2026-11-27 07-13Z, 49 of the 99 red app compile jobs (2,113 of 2,746 red
# job-min) failed on one base error, `SettingDescriptor+Palette.swift:37: main actor-isolated static property
# 'curatedThemes'` (jobs 140444314566, 140495576918), on heads that never touched that file; fixed on the base by
# #61522 at 13:56Z. Each of those builds took ~43 min to say what the first one said. A red job uploads its Swift
# diagnostics (RED_ARTIFACT-ARCH); a pass uploads PASS_ARTIFACT-ARCH. The route reads the newest red and skips the
# build when:
#   - the red's failing files (each `path.swift:L:C: error|note:`) are the same blobs at that red's head, at the base
#     tip it was merged onto (so the head did not cause them), and at this head (so this head would fail the same);
#   - no pass since then had those same blobs (a pass with them means the red is fixed, say in another file);
#   - it is under RED_MAX_AGE_H old, the PR is not labeled full-ci, and this run is not one of the AUDIT_PERCENT
#     audits (seeded by run id and attempt), which build anyway so a fix in another file is seen within ~30 min.
# Any read that fails or runs long builds: the skip fails open. Only same-repository runs' verdicts count (trusted).
# One red on either arch skips both: the reds seen are arch-independent (#62033 cancels the other arch on a red too).
RED_ARTIFACT = "nightly-app-compile-red"
PASS_ARTIFACT = "nightly-app-compile-pass"
RED_MAX_AGE_H = 6
AUDIT_PERCENT = 10
MAX_PASSES = 20
DIAGNOSTIC = re.compile(r"(?:^|[\s/])((?:Packages|vendor|Resources|ghostty|ghostty-next|Sources|Native)/[^\s:]+?\.swift):"
                        r"\d+:\d+: (?:error|note): ")
API = os.environ.get("GITHUB_API_URL", "https://api.github.com")


def failing_files(diagnostics: str) -> list[str]:
    """Repo paths of the Swift files the diagnostics name, from the fleet's absolute `.../src/PATH:L:C:` lines."""
    return sorted({m.group(1) for line in diagnostics.splitlines() for m in DIAGNOSTIC.finditer(line)})


def blobs(rev: str, paths: list[str], root: Path = ROOT) -> dict[str, str]:
    """Each path's object id at rev ("" when absent)."""
    out = subprocess.run(["git", "-C", str(root), "ls-tree", rev, "--", *paths], check=True, capture_output=True,
                         text=True).stdout
    found = {line.split("\t", 1)[1]: line.split()[2] for line in out.splitlines() if "\t" in line}
    return {path: found.get(path, "") for path in paths}


def audited(run_id: str, attempt: str, percent: int = AUDIT_PERCENT) -> bool:
    return int(hashlib.sha256(f"{run_id}:{attempt}".encode()).hexdigest(), 16) % 100 < percent


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # the artifact zip's signed URL must not get the token
        return None


def _api(path: str, token: str, raw: bool = False):
    request = urllib.request.Request(f"{API}/{path}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    if not raw:
        with urllib.request.urlopen(request, timeout=15) as answer:
            return json.load(answer)
    try:
        urllib.request.build_opener(_NoRedirect).open(request, timeout=20)
    except urllib.error.HTTPError as redirect:
        if redirect.code in (301, 302, 303, 307, 308) and redirect.headers.get("Location"):
            with urllib.request.urlopen(redirect.headers["Location"], timeout=30) as answer:
                return answer.read()
        raise
    raise RuntimeError("artifact download answered without a redirect")


SHA = re.compile(r"[0-9a-f]{40}")


def trusted(artifact: dict) -> bool:
    """Uploaded by a run of a same-repository head: a fork PR's run can upload artifacts too (its own workflow
    file), so its verdicts are never read."""
    run = artifact.get("workflow_run") or {}
    return (not artifact.get("expired") and run.get("repository_id") is not None
            and run.get("repository_id") == run.get("head_repository_id") and bool(SHA.fullmatch(run.get("head_sha") or "")))


def _artifacts(repo: str, name: str, token: str) -> list[dict]:
    """Trusted unexpired artifacts NAME-ARCH (each arch's job uploads its own), newest first."""
    items = [a for arch in ARCHS
             for a in _api(f"repos/{repo}/actions/artifacts?name={name}-{arch}&per_page=50", token).get("artifacts", [])]
    return sorted((a for a in items if trusted(a)), key=lambda a: a["created_at"], reverse=True)


def _when(stamp: str) -> dt.datetime:
    return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def decide_base_red(red: dict | None, passes: list[dict], rev: str, blobs_at, now: dt.datetime) -> str | None:
    """The red's job URL when rev would only repeat the base's red, else None (red: verdict.json plus created_at
    and diagnostics; passes: {"head", "created_at"} newer first; blobs_at(rev, paths) -> {path: oid})."""
    if not red or not all(SHA.fullmatch(str(red.get(k, ""))) for k in ("head", "base")) or now - _when(red["created_at"]) > dt.timedelta(hours=RED_MAX_AGE_H):
        return None
    files = failing_files(red.get("diagnostics", ""))
    if not files:
        return None
    want = blobs_at(red["head"], files)
    if not all(want.values()) or blobs_at(red["base"], files) != want or blobs_at(rev, files) != want:
        return None
    for done in passes:
        if _when(done["created_at"]) > _when(red["created_at"]) and blobs_at(done["head"], files) == want:
            return None
    return red.get("job") or "the newest nightly app compile red"


def base_red(rev: str, base_tip: str, root: Path = ROOT) -> str | None:
    if "full-ci" in [*json.loads(os.environ.get("PR_LABELS") or "[]"), os.environ.get("ADDED_LABEL", "")]:
        return None
    if audited(os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("GITHUB_RUN_ATTEMPT", "1")):
        print("nightly app compile: this run is a base-red audit; building", file=sys.stderr)
        return None
    repo, token = os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"]
    reds = _artifacts(repo, RED_ARTIFACT, token)
    if not reds:
        return None
    newest = reds[0]
    with zipfile.ZipFile(io.BytesIO(_api(f"repos/{repo}/actions/artifacts/{newest['id']}/zip", token, raw=True))) as z:
        red = json.loads(z.read("verdict.json"))
        red["diagnostics"] = z.read("diagnostics.txt").decode(errors="replace")
    red["created_at"] = newest["created_at"]
    if red.get("head") != newest["workflow_run"]["head_sha"] or not SHA.fullmatch(str(red.get("base", ""))):
        return None  # the verdict must name its own run's head, and a commit id
    passes = [{"head": a["workflow_run"]["head_sha"], "created_at": a["created_at"]}
              for a in _artifacts(repo, PASS_ARTIFACT, token)
              if a["created_at"] > newest["created_at"] and (a.get("workflow_run") or {}).get("head_sha")][:MAX_PASSES]
    wanted = sorted({red["head"], red["base"], *(p["head"] for p in passes)} - {rev, base_tip})
    if wanted:
        subprocess.run(["git", "-C", str(root), "-c", "protocol.version=2", "fetch", "-q", "--no-tags", "--depth=1",
                        "--filter=blob:none", "origin", "--", *wanted], check=True, timeout=120)
    url = decide_base_red(red, passes, rev, lambda r, paths: blobs(r, paths, root),
                          dt.datetime.now(dt.timezone.utc))
    if url:
        files = ", ".join(failing_files(red["diagnostics"]))
        first = next((line.strip() for line in red["diagnostics"].splitlines() if ": error: " in line), "")[-300:]
        print(f"::warning title=nightly app compile::base red, not the head: {url} failed on {files}, which this "
              f"head has as that base had them; not built (the newest red: {first}). Label full-ci to build.",
              file=sys.stderr)
    return url


def run_helpers(root: Path = ROOT) -> int:
    failed = []
    for helper in HELPERS:
        command = ["cargo", "check", "--locked", "--release", *helper["args"]]
        print(f"::group::{helper['name']}: {' '.join(command)} (in {helper['dir']})", flush=True)
        env = {**os.environ, **helper["profile"]}
        status = subprocess.run(command, cwd=root / helper["dir"], env=env).returncode
        print("::endgroup::", flush=True)
        if status != 0:
            failed.append(helper["name"])
            print(f"::error title=nightly helper build::{helper['name']} does not build the way the Nightly "
                  f"builds it ({helper['script']}): cargo exited {status}", flush=True)
    if failed:
        return 1
    print(f"OK: {len(HELPERS)} Nightly Rust helpers build in release with the Nightly's features.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("route")
    r.add_argument("--base", required=True)
    r.add_argument("--rev", default="HEAD")
    k = sub.add_parser("keys")
    k.add_argument("--rev", default="HEAD")
    k.add_argument("--recipe-rev", help="workflow and driver revision, defaulting to --rev")
    b = sub.add_parser("base-red")
    b.add_argument("--rev", required=True)
    b.add_argument("--base-tip", required=True)
    sub.add_parser("helpers")
    args = parser.parse_args(argv)
    if args.command == "route":
        paths = git("diff", "--name-only", "--no-renames", args.base, args.rev).splitlines()
        for name, value in route(paths).items():
            print(f"{name}={'true' if value else 'false'}")
        return 0
    if args.command == "keys":
        print("keys=" + json.dumps(keys(args.rev, recipe_rev=args.recipe_rev), sort_keys=True, separators=(",", ":")))
        return 0
    if args.command == "base-red":
        try:
            url = base_red(args.rev, args.base_tip)
        except Exception as error:  # noqa: BLE001 - the skip fails open
            print(f"::warning title=nightly app compile::base-red read failed ({error!r}); building", file=sys.stderr)
            url = None
        if url:
            print(f"base_red={url}")
        return 0
    return run_helpers()


if __name__ == "__main__":
    sys.exit(main())
