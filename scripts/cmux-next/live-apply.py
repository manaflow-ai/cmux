#!/usr/bin/env python3
"""Apply this checkout's change to the running cmux NEXT, check it, and print one JSON verdict.

    live-apply.py [--repo DIR] [--base REF] [--probe CMD] [--probe-seconds S] [--no-rollback] [--dry-run]

The agent's loop (hq#7149, `cmux live apply`): edit, run this, read the verdict, edit again, with
no full build and no person. It sorts the working tree against BASE with live_apply.py (the rules
try-pr.sh uses: tracked edits and untracked files both count), takes the cheapest rung that covers
every file, applies it to the running app, runs the probe and rolls back when the probe does not
pass. The last line on stdout is the verdict, everything else goes to stderr:

  {"rung": "R0", "applied": true, "probe": "pass", "seconds": 41.2, "rolled_back": false, ...}

  rung         R0 (web bundles: web-overlay.sh builds this checkout's bundles and swaps them in;
               every open page reloads, same process), or null when no rung here covers the change
  applied      whether the change reached the app
  probe        pass, fail, error (it never answered 0 or 1 before the deadline) or none (no --probe)
  seconds      from the start to the verdict; `phases` splits it (classify, build_swap, probe,
               rollback)
  rolled_back  the probe did not pass, so the previous overlay generation (or the bundled pages)
               is back; --no-rollback keeps the change in place
  verdict      live_apply.py's: no-app, ios-only, web-live, swift-live, daemon, rebuild
  needs        why no rung applied it (a Swift, daemon or rebuild change takes a dev build today:
               try-pr.sh names it), else null

Exit 0: applied and the probe passed (or nothing in the app changed, or no --probe). 1: the probe
did not pass. 3: no rung here takes the change. 4: the bundles did not build (nothing changed in the
app). 2: usage.

--repo names the checkout to apply (default: this one); its own web-overlay.sh builds and installs
its bundles. BASE is the commit the running app was built from (its CMUXCommit), by default the merge base of
HEAD and origin/feat-cmux-next. Web bundles talk to the app over the page bridge, so they should
come from a tree close to that commit (web-overlay.sh).

--probe CMD runs with bash and reads the change in the real app (its control socket, its screen):
exit 0 when the change shows, anything else when it does not yet. It is asked again until it
passes or --probe-seconds (default 30) runs out, since pages reload a moment after the swap. It
gets CMUX_LIVE_APPLY_GENERATION (the overlay generation now installed) in its environment, and the
web overlay's own variables (CMUX_NEXT_CONFIG_FILE, CMUX_WEB_OVERLAY_DIR) pass through to it and to
web-overlay.sh, so a side instance or a fresh-home app is targeted the same way.

Swift function bodies (R2) go live once the app's loader takes them (live-apply-nightly, hq#7149
L3); until then a swift-live verdict reports `needs` with no apply. The ladder is in hq#7149.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]  # --repo replaces it
sys.path.insert(0, str(HERE))
import live_apply  # noqa: E402

SURFACES = ("agent-pane", "pages", "webviews-app")
NEEDS = {
    "swift-live": "Swift inside function bodies or new files: live once the app's Swift loader takes it "
                  "(hq#7149 R2), a dev build until then (try-pr.sh --build)",
    "daemon": "the daemon or CLI changes: a dev build (try-pr.sh --build)",
    "rebuild": "the app needs a new binary: a dev build (try-pr.sh --build)",
}


def log(message: str) -> None:
    print(f"live-apply: {message}", file=sys.stderr, flush=True)


def git(*args: str, env: dict | None = None) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def working_tree() -> str:
    """The working tree as a tree object (tracked edits and untracked files, .gitignore honoured),
    through a scratch index so the checkout's own index and stash are untouched."""
    with tempfile.TemporaryDirectory(prefix="live-apply-index.") as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(scratch, "index"))
        git("read-tree", "HEAD", env=env)
        git("add", "-A", env=env)
        return git("write-tree", env=env)


def overlay_paths() -> tuple[Path, Path]:
    """The overlay folder and web-dev.json, resolved as web-overlay.sh resolves them."""
    config = Path(os.environ.get("CMUX_NEXT_CONFIG_FILE") or Path.home() / ".config/cmux/cmux-next.json")
    overlay = Path(os.environ.get("CMUX_WEB_OVERLAY_DIR")
                   or Path.home() / "Library/Application Support/cmux-next/web-overlay")
    return overlay, config.parent / "web-dev.json"


def overlay_state() -> dict:
    """What a rollback puts back: each surface's generation link, the manifest and web-dev.json.
    The generations those links name are copied aside (`.keep-<pid>-<gen>`, a name web-overlay.sh
    never prunes): an install keeps only its two newest, so after a rollback the next install can
    delete the generation a second rollback needs."""
    overlay, web_dev = overlay_paths()
    links = {name: os.readlink(overlay / name) if (overlay / name).is_symlink() else None for name in SURFACES}
    kept = {}
    for target in links.values():
        gen = target.split("/", 1)[0] if target else None
        if gen and gen not in kept and (overlay / gen).is_dir():
            kept[gen] = overlay / f".keep-{os.getpid()}-{gen}"
            shutil.rmtree(kept[gen], ignore_errors=True)
            shutil.copytree(overlay / gen, kept[gen], symlinks=True)
    manifest = overlay / "manifest.json"
    return {"links": links, "kept": kept, "manifest": manifest.read_text() if manifest.is_file() else None,
            "web_dev": web_dev.read_bytes() if web_dev.is_file() else None}


def drop_kept(state: dict) -> None:
    for path in state["kept"].values():
        shutil.rmtree(path, ignore_errors=True)


def generation() -> str | None:
    overlay, _ = overlay_paths()
    try:
        return json.loads((overlay / "manifest.json").read_text()).get("stamp")
    except (OSError, ValueError):
        return None


def restore(state: dict) -> None:
    """Puts STATE back the way web-overlay.sh installs: each link renamed over in one step, then the
    manifest (the app reloads on it, so it gets a new stamp), then web-dev.json."""
    overlay, web_dev = overlay_paths()
    for gen, copy in state["kept"].items():
        if not (overlay / gen).is_dir() and copy.is_dir():
            os.replace(copy, overlay / gen)  # the install pruned it: the copy taken before goes back
    # Every target first, so a rollback that cannot finish leaves every surface where it was.
    gone = [str(overlay / t) for t in state["links"].values() if t is not None and not (overlay / t).exists()]
    if gone:
        raise RuntimeError(f"{', '.join(gone)} gone: every surface stays on the new generation")
    for name, target in state["links"].items():
        path = overlay / name
        if target is None:
            if path.is_symlink():
                path.unlink()
            continue
        temp = overlay / f".{name}.rollback"
        if temp.is_symlink() or temp.exists():
            temp.unlink()
        os.symlink(target, temp)
        os.replace(temp, path)
    manifest = overlay / "manifest.json"
    if state["manifest"] is not None:
        data = json.loads(state["manifest"])
        data["rolled_back_at"] = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        write_atomic(manifest, json.dumps(data) + "\n")
    elif manifest.exists():
        manifest.unlink()
    if state["web_dev"] is None:
        if web_dev.exists():
            web_dev.unlink()
    else:
        write_atomic(web_dev, state["web_dev"].decode())


def write_atomic(path: Path, text: str) -> None:
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    os.replace(temp, path)


def run_probe(command: str, seconds: float) -> tuple[str, dict]:
    """("pass" | "fail" | "error", detail): asked until it exits 0 or SECONDS runs out. The last
    answer decides: 1 is fail (the app answered and the change is not there), anything else error."""
    env = dict(os.environ, CMUX_LIVE_APPLY_GENERATION=generation() or "")
    deadline, tries, last = time.monotonic() + seconds, 0, None
    while True:
        tries += 1
        left = max(1.0, deadline - time.monotonic())
        try:
            done = subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True, timeout=left)
            last = {"exit": done.returncode, "out": done.stdout.strip()[-600:], "err": done.stderr.strip()[-600:]}
        except subprocess.TimeoutExpired:
            last = {"exit": None, "out": "", "err": f"timed out after {left:.0f}s"}
        if last["exit"] == 0:
            return "pass", dict(last, tries=tries)
        if time.monotonic() >= deadline:
            return ("fail" if last["exit"] == 1 else "error"), dict(last, tries=tries)
        time.sleep(0.5)  # the page reloads a moment after the swap


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="the running app's commit (default: merge base with origin/feat-cmux-next)")
    parser.add_argument("--probe", help="bash command: exit 0 when the change shows in the app")
    parser.add_argument("--probe-seconds", type=float, default=30.0)
    parser.add_argument("--no-rollback", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="classify only")
    parser.add_argument("--repo", type=Path, help="the checkout to apply (default: this one)")
    args = parser.parse_args(argv)
    global ROOT
    if args.repo:
        ROOT = args.repo.resolve()

    started = time.monotonic()
    phases: dict[str, float] = {}
    result = {"rung": None, "applied": False, "probe": "none", "seconds": 0.0, "rolled_back": False,
              "verdict": None, "needs": None, "base": None, "generation": None, "probe_detail": None,
              "phases": phases, "files": {}, "reasons": {}}

    def done(code: int) -> int:
        result["seconds"] = round(time.monotonic() - started, 2)
        print(json.dumps(result))
        return code

    base = args.base or git("merge-base", "HEAD", "origin/feat-cmux-next")
    result["base"] = git("rev-parse", base)
    sorted_change = live_apply.classify_range(str(ROOT), result["base"], working_tree())
    verdict = sorted_change["verdict"]
    result.update(verdict=verdict, files=sorted_change["files"], reasons=sorted_change["reasons"])
    phases["classify"] = round(time.monotonic() - started, 2)
    log(f"{verdict} against {result['base'][:12]}")
    if verdict in ("no-app", "ios-only"):
        return done(0)
    if verdict != "web-live":
        result["needs"] = NEEDS[verdict]
        return done(3)
    result["rung"] = "R0"
    if args.dry_run:
        return done(0)

    before = overlay_state()
    try:
        return apply_and_probe(args, result, phases, before, done)
    finally:
        drop_kept(before)  # every way out, an interrupted build or probe included


def apply_and_probe(args, result: dict, phases: dict, before: dict, done) -> int:
    t = time.monotonic()
    built = subprocess.run([str(ROOT / "scripts/cmux-next/web-overlay.sh"), "build"], stdout=sys.stderr, stderr=sys.stderr)
    phases["build_swap"] = round(time.monotonic() - t, 2)
    if built.returncode != 0:
        result["needs"] = f"web-overlay.sh build exited {built.returncode}"
        return done(4)
    result["applied"], result["generation"] = True, generation()
    if not args.probe:
        return done(0)

    t = time.monotonic()
    result["probe"], result["probe_detail"] = run_probe(args.probe, args.probe_seconds)
    phases["probe"] = round(time.monotonic() - t, 2)
    if result["probe"] == "pass":
        return done(0)
    if not args.no_rollback:
        t = time.monotonic()
        try:
            restore(before)
            result["rolled_back"] = True
            log(f"probe {result['probe']}: rolled back to {(before['links'].get('pages') or 'the bundled pages')}")
        except (OSError, RuntimeError, ValueError) as error:
            result["needs"] = f"rollback incomplete: {error}"
            log(result["needs"])
        phases["rollback"] = round(time.monotonic() - t, 2)
    return done(1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # a harness timeout still runs the finally
    sys.exit(main())
