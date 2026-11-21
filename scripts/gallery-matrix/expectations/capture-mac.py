#!/usr/bin/env python3
"""The Mac capture adapter of the visual expectation gate: real light and dark stills of each
design/visual-expectations/mac/*.json state, through the fleet route `cmux-ci capture`, laid out for gate.ts.

    capture-mac.py --expectations design/visual-expectations --sha SHA --out CAPTURES [--pr N] [--surfaces a,b]
                   [--cmux CHECKOUT] [--dry-run]

For each capture of each mac surface it runs

    cmux-ci capture SHA --state FILE --mac [--pr N]

one state per run (pr-capture takes one --state; the fleet build of SHA is made once and reused from
~/.cache/pr-capture/builds/SHA.json by every later run). FILE is the capture's `stateFile` as it is at SHA
(`git show SHA:PATH` from the cmux checkout, so the state matches the commit captured), plus one appended step,
`debug.commit_boundary` recorded to a file, whose `macos` field names the OS the stills were drawn on. A
`stateFile` of the form scene:NAME, tour:NAME or builtin:NAME is passed through as is (no OS probe).

pr-capture writes its files to PR_CAPTURE_CACHE/SHA8/STATE/ (light.png, dark.png, result.json, rpc-NN.json); the
adapter points PR_CAPTURE_CACHE at a folder of its own under --out (its builds/ and apps/ linked to the shared
cache, so a build is never made twice), so it reads exactly what that run wrote, and copies the stills to

    OUT/mac/<surface id>/<state>-<scheme>.png
    OUT/mac/<surface id>/<state>-<scheme>.json   {"scale": S, "keep": []}  or  {"scale": S, "keep": [], "error": WHY}
    OUT/mac/renderer.json                         {"id": "macOS <version>; fleet capture slot @<S>x"}

S is the state's displayScale (1 unless the state asks for 2: the capture minis' displays are 1x, and a 2x
capture leases a whole mini with a virtual Retina display). Native keep regions are fixed boxes in points, so the
sidecar's keep is always empty. A state that did not capture gets a sidecar with its error and no PNG, which the
gate reports as missing (or new). The renderer id leaves out the mini's name (a private term) and the app's
build SHA (the thing under test: it would make every PR read as a renderer change).

Exit 0 when every state captured, 1 when any did not, 2 on bad input. Runs nothing on this host but git and
`cmux-ci`: the build and the app run on the fleet (a lane VM takes the controller route, a ci-step on a display
worker); never on an agent host.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

PASS_THROUGH = re.compile(r"(scene|tour|builtin):[a-z0-9][a-z0-9-]{0,63}")
ID = re.compile(r"^[a-z0-9][a-z0-9.-]*$")
SCHEMES = ("light", "dark")
CAPTURE_TIMEOUT = 60 * 60  # a cold build plus the slot wait; pr-capture bounds its own steps
PROBE_STEP = {
    "title": "Renderer id (macOS version) for the visual expectation gate",
    "rpc": {"method": "debug.commit_boundary", "params": {}},
    "record": "file",
    "wait": 0.2,
    "cite": "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugCommitBoundary.swift",
}


class InputError(Exception):
    pass


def log(message: str) -> None:
    print(f"capture-mac: {message}", file=sys.stderr, flush=True)


def git(repo: Path, *args: str, text: bool = True) -> Any:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=text, timeout=300)
    if done.returncode != 0:
        err = done.stderr if text else done.stderr.decode(errors="replace")
        raise InputError(f"git {' '.join(args)}: {err.strip()[-400:]}")
    return done.stdout


def load_surfaces(root: Path, only: set[str] | None) -> list[dict]:
    """The mac surfaces under root/mac, checked the way expectations.ts validateSurface checks them (the fields
    this adapter reads)."""
    folder = root / "mac"
    if not folder.is_dir():
        raise InputError(f"{folder}: no mac expectations")
    surfaces = []
    for file in sorted(folder.glob("*.json")):
        try:
            data = json.loads(file.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise InputError(f"{file}: {error}") from None
        sid = data.get("id") if isinstance(data, dict) else None
        if not isinstance(sid, str) or not ID.match(sid) or file.name != f"{sid}.json":
            raise InputError(f"{file}: id must be an id and the file must be named <id>.json")
        if data.get("platform", "mac") != "mac":
            raise InputError(f"{file}: platform {data.get('platform')} sits under mac/")
        schemes = data.get("schemes", list(SCHEMES))
        if not isinstance(schemes, list) or not schemes or any(s not in SCHEMES for s in schemes):
            raise InputError(f"{file}: schemes must be light and/or dark")
        captures = data.get("captures")
        if not isinstance(captures, list) or not captures:
            raise InputError(f"{file}: captures must list at least one state")
        seen = set()
        for i, c in enumerate(captures):
            if not isinstance(c, dict) or not isinstance(c.get("state"), str) or not ID.match(c["state"]):
                raise InputError(f"{file}: captures[{i}].state must be an id")
            if c["state"] in seen:
                raise InputError(f"{file}: captures[{i}].state {c['state']} repeats")
            seen.add(c["state"])
            if not isinstance(c.get("stateFile"), str) or not c["stateFile"]:
                raise InputError(f"{file}: captures[{i}] needs stateFile on mac")
        if only is None or sid in only:
            surfaces.append({"id": sid, "schemes": schemes, "captures": captures})
    if only:
        missing = only - {s["id"] for s in surfaces}
        if missing:
            raise InputError(f"--surfaces names no mac surface: {', '.join(sorted(missing))}")
    return surfaces


def state_argument(repo: Path, sha: str, state_file: str, work: Path) -> tuple[str, int, bool]:
    """(the --state argument, its display scale, whether it carries the OS probe) for one capture's stateFile at
    SHA. A steps file is written into WORK with the probe step appended."""
    if PASS_THROUGH.fullmatch(state_file):
        return state_file, 1, False
    if state_file.startswith("/") or ".." in Path(state_file).parts or not state_file.endswith(".json"):
        raise InputError(f"stateFile {state_file!r}: a repo-relative .json path, or scene:/tour:/builtin:NAME")
    raw = git(repo, "show", f"{sha}:{state_file}")
    try:
        data = json.loads(raw)
    except ValueError as error:
        raise InputError(f"{state_file} at {sha[:12]}: {error}") from None
    if not isinstance(data, dict) or not isinstance(data.get("steps"), list) or not data["steps"]:
        raise InputError(f"{state_file} at {sha[:12]}: a state needs a steps list")
    data["steps"] = [*data["steps"], PROBE_STEP]
    scale = data.get("displayScale", 1)
    body = json.dumps(data, indent=2, sort_keys=True).encode()
    out = work / f"{hashlib.sha256(body).hexdigest()[:16]}.json"
    out.write_bytes(body)
    return str(out), 2 if scale == 2 else 1, True


def pr_capture_folder(cache: Path, sha: str, state_arg: str, scale: int) -> Path:
    """Where pr-capture puts a run's files (pr-capture resolve_state / main: CACHE/SHA8/NAME)."""
    match = PASS_THROUGH.fullmatch(state_arg)
    if match:
        kind, name = state_arg.split(":", 1)
        folder = f"{kind}-{name}"
    else:
        folder = "steps-" + hashlib.sha256(Path(state_arg).read_bytes()).hexdigest()[:10]
    folder = folder[:60]
    if scale == 2:
        folder = f"{folder[:57]}-2x"
    return cache / sha[:8] / folder


def find_key(value: Any, key: str) -> str | None:
    if isinstance(value, dict):
        if isinstance(value.get(key), str):
            return value[key]
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            if isinstance(item, str) and item.startswith(f"{key}: "):
                return item[len(key) + 2:]
            found = find_key(item, key)
            if found:
                return found
    return None


def macos_version(folder: Path) -> str | None:
    """The `macos` field of the probe step's answer, from its rpc-NN.json (or the step record)."""
    for file in sorted(folder.glob("rpc-*.json"), reverse=True):
        try:
            found = find_key(json.loads(file.read_text(encoding="utf-8")), "macos")
        except (OSError, ValueError):
            continue
        if found:
            return found
    try:
        result = json.loads((folder / "result.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    for step in result.get("steps", []):
        if step.get("rpc") == PROBE_STEP["rpc"]["method"]:
            return find_key(step.get("result") or step.get("answer"), "macos")
    return None


def write_sidecar(png: Path, scale: int, error: str | None = None) -> None:
    data: dict[str, Any] = {"scale": scale, "keep": []}
    if error:
        data["error"] = error[-500:]
    png.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def run_capture(cmd: list[str], env: dict[str, str]) -> tuple[int, str]:
    log("running: " + " ".join(cmd))
    try:
        done = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              timeout=CAPTURE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return 124, f"cmux-ci capture ran past {CAPTURE_TIMEOUT} s"
    sys.stderr.write(done.stderr)
    if done.stdout:
        sys.stdout.write(done.stdout)  # with --pr: the Markdown for the PR body
    tail = [line for line in done.stderr.splitlines() if line.strip()][-3:]
    return done.returncode, " | ".join(tail)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--expectations", required=True, type=Path, help="design/visual-expectations")
    ap.add_argument("--sha", required=True, help="the commit to capture (full SHA or unique prefix)")
    ap.add_argument("--out", required=True, type=Path, help="the CAPTURES root gate.ts reads")
    ap.add_argument("--pr", type=int, help="also upload each state's stills to this PR's pr-media (pr-capture --pr)")
    ap.add_argument("--surfaces", help="comma-separated surface ids (default: every mac surface)")
    ap.add_argument("--cmux", type=Path, help="cmux checkout holding SHA (default: the one this script is in)")
    ap.add_argument("--cmux-ci", default=os.environ.get("CMUX_CI", "cmux-ci"), help="the cmux-ci command")
    ap.add_argument("--dry-run", action="store_true", help="resolve every state and print the commands; run nothing")
    a = ap.parse_args(argv)
    try:
        repo = a.cmux or Path(__file__).resolve().parents[3]
        sha = git(repo, "rev-parse", "--verify", f"{a.sha}^{{commit}}").strip()
        only = {s for s in a.surfaces.split(",") if s} if a.surfaces else None
        surfaces = load_surfaces(a.expectations, only)
        a.out.mkdir(parents=True, exist_ok=True)
        cache = (a.out / ".pr-capture").resolve()
        work = Path(tempfile.mkdtemp(prefix="capture-mac-", dir=a.out))
        plan = []
        for surface in surfaces:
            for capture in surface["captures"]:
                state_arg, scale, probed = state_argument(repo, sha, capture["stateFile"], work)
                cmd = [a.cmux_ci, "capture", sha, "--state", state_arg, "--mac", "--cmux", str(repo)]
                if a.pr:
                    cmd += ["--pr", str(a.pr)]
                plan.append((surface, capture, state_arg, scale, probed, cmd))
    except InputError as error:
        log(str(error))
        return 2
    env = {**os.environ, "PR_CAPTURE_CACHE": str(cache)}
    if not a.dry_run:
        # Stills land in OUT's own cache; build receipts and app records stay shared with every other
        # capture on this host, so a SHA another capture built (or this adapter's first state built) is reused.
        shared = Path(os.environ.get("PR_CAPTURE_CACHE") or Path.home() / ".cache" / "pr-capture")
        cache.mkdir(parents=True, exist_ok=True)
        for name in ("builds", "apps"):
            (shared / name).mkdir(parents=True, exist_ok=True)
            link = cache / name
            if not link.is_symlink() and not link.exists():
                link.symlink_to(shared / name, target_is_directory=True)
    failed, versions, scales = 0, set(), set()
    for surface, capture, state_arg, scale, probed, cmd in plan:
        dest = a.out / "mac" / surface["id"]
        folder = pr_capture_folder(cache, sha, state_arg, scale)
        if a.dry_run:
            print(f"PR_CAPTURE_CACHE={cache} {' '.join(cmd)}")
            print(f"  reads {folder}/{{light,dark}}.png -> " +
                  " ".join(str(dest / f"{capture['state']}-{s}.png") for s in surface["schemes"]))
            continue
        dest.mkdir(parents=True, exist_ok=True)
        if folder.exists():
            shutil.rmtree(folder)  # ours (under OUT): never read an earlier run's stills
        code, tail = run_capture(cmd, env)
        error = None if code == 0 else f"cmux-ci capture exited {code}: {tail}"
        scales.add(scale)
        if probed and folder.is_dir():
            version = macos_version(folder)
            if version:
                versions.add(version)
        for scheme in surface["schemes"]:
            png = dest / f"{capture['state']}-{scheme}.png"
            still = folder / f"{scheme}.png"
            png.unlink(missing_ok=True)
            if error is None and still.is_file():
                shutil.copyfile(still, png)
                write_sidecar(png, scale)
                log(f"{surface['id']}/{capture['state']} {scheme}: {png} ({png.stat().st_size} bytes)")
            else:
                write_sidecar(png, scale, error or f"no {scheme}.png in {folder}")
                failed += 1
                log(f"{surface['id']}/{capture['state']} {scheme}: not captured ({error or 'no still'})")
    if a.dry_run:
        return 0
    if versions or scales:
        os_part = "macOS " + " | ".join(sorted(versions)) if versions else "macOS unknown"
        if len(versions) > 1:
            log(f"the states ran on different macOS versions: {sorted(versions)}")
        scale_part = "/".join(f"@{s}x" for s in sorted(scales))
        renderer = {"id": f"{os_part}; fleet capture slot {scale_part}"}
        (a.out / "mac").mkdir(parents=True, exist_ok=True)
        (a.out / "mac" / "renderer.json").write_text(json.dumps(renderer) + "\n", encoding="utf-8")
        log(f"renderer: {renderer['id']}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
