#!/usr/bin/env python3
"""Pick the runner for cmux-next-media.yml's tour: an owned Mac's session or gui runner, or none.

The tour launches cmux-next and screenshots it, so it needs a logged-in
console session that can come to the front and be captured. Blacksmith's
macOS sessions sit at a locked screen (e2e_runner_pool.py on main has the
runs), so the tour never falls back to Blacksmith: with no owned gui runner it
does not run, and the comment says why.

The label is the gui runner of the owned pool for the pull request lane's
Xcode pin (pr_runner_pool.gui_label(), `glaeda-gui-<class>-xcode-<version>`),
one per mini, the runner that holds the mini's console session. The tour
needs the logged-in session but not the console gui token, so where the pool's
session label (pr_runner_pool.session_label(), `glaeda-session-<class>-xcode-<version>`,
glaeda#1530) has runners in CI_OWNED_POOL_SLOTS it takes that instead and runs
beside a console GUI job. Each mini's console gui runner carries it too, and
with `guiRunners` 2 a session runner carries only it. Until the slots name a
session count the tour keeps the gui label: a label no runner carries would
leave it queued for good. Workflows
never name an owned label (tests/test_ci_self_hosted_guard.sh), so it reaches
runs-on only as this script's output.

With --paths-file (the changed paths, read on Linux by the route job), a change
the Mac tour would not capture takes no Mac: no UI paths, or only webview code,
whose look the gallery advisory run checks in Linux Chromium (path_map.py). A
missing or unreadable file, or a path map that fails to load, leaves the pick
as it was, so the tour never skips for want of the paths. --force-mac (the
`media-tour-mac` label) tours on a Mac whatever changed.

Rules, in order: a change with nothing to tour gets nothing; a fork head gets nothing (owned Macs run trusted code only);
CI_PR_POOL_OWNED must be 1; the first owned pool class whose gui label has
machines in CI_OWNED_POOL_SLOTS wins, its session label first.

Writes `runs_on` (a label, or "") and `reason` to $GITHUB_OUTPUT, and prints them.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool  # noqa: E402

MEDIA = Path(__file__).resolve().parents[1] / "cmux-next" / "media"


def scope_reason(paths: list[str] | None) -> str | None:
    """Why the change needs no Mac tour, or None when it does (or the paths are unknown)."""
    if paths is None:
        return None
    try:
        sys.path.insert(0, str(MEDIA))
        import path_map  # noqa: PLC0415 - a broken map must not fail the route
        mapping = path_map.map_paths(paths)
    except Exception as error:  # noqa: BLE001
        print(f"path map unavailable ({error}); picking a Mac", file=sys.stderr)
        return None
    if mapping["is_ui"]:
        return None
    if mapping["gallery"]:
        return (f"only webview code changed ({len(mapping['gallery'])} path(s)), which the gallery advisory "
                "run checks in Linux Chromium on the pull request (its artifact holds any captures); add the "
                "media-tour-mac label, then re-add media-tour, to tour it on a Mac")
    return "no UI paths changed"


def read_paths(path: Path | None) -> list[str] | None:
    if path is None:
        return None
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return None


def pick(*, same_repo: bool, owned: str | None, owned_slots: str | None,
         pr_xcode_app: str | None) -> tuple[str, str]:
    """(label, reason); the label is "" when the tour should not run."""
    if not same_repo:
        return "", "a fork head never runs on an owned Mac"
    if (owned or "").strip() != "1":
        return "", "owned Macs are off (CI_PR_POOL_OWNED is not 1)"
    pools = pr_runner_pool.owned_pools(pr_xcode_app)
    if not pools:
        return "", f"no owned pool for the lane's Xcode pin ({pr_xcode_app or 'unset'})"
    slots = pr_runner_pool.slots(owned_slots, pr_xcode_app)
    for pool in pools:
        session = pr_runner_pool.session_label(pool)
        if session and slots.get(session, 0) > 0:
            return session, f"{slots[session]} session runner(s) on {pool}"
        gui = pr_runner_pool.gui_label(pool)
        if gui and slots.get(gui, 0) > 0:
            return gui, f"{slots[gui]} gui runner(s) on {pool}"
    return "", "no owned pool has session or gui runners in CI_OWNED_POOL_SLOTS"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--same-repo", required=True, choices=("true", "false"))
    parser.add_argument("--paths-file", type=Path, help="newline-delimited changed paths, when known")
    parser.add_argument("--force-mac", action="store_true", help="tour on a Mac whatever changed")
    args = parser.parse_args(argv)
    skip = None if args.force_mac else scope_reason(read_paths(args.paths_file))
    if skip:
        label, reason = "", skip
    else:
        label, reason = pick(
            same_repo=args.same_repo == "true",
            owned=os.environ.get("POOL_OWNED"),
            owned_slots=os.environ.get("OWNED_SLOTS"),
            pr_xcode_app=os.environ.get("PR_XCODE_APP"),
        )
    lines = [f"runs_on={label}", f"reason={reason}"]
    print("\n".join(lines))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
