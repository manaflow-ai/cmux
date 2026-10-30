#!/usr/bin/env python3
"""The restore journey's update to another build: build B put in place of the running app's copy, as
an update installs it, between the updater's relaunch path and the relaunch.

`restore-journey.py --variants update --update-to STAGED_APP_B` (restore-journey-slot.sh
`--update-to JOB_B`) seeds its state on build A, quits through the updater's relaunch hook
(`debug.updater {action: "relaunch"}`, what Sparkle runs before it relaunches into an update) and
then, before the relaunch, calls `install` here. Sparkle itself cannot install B on a capture slot:
its feed needs an archive signed with the channel's update key, and a DEV build from a PR head has
none. So the swap does what Sparkle's installer does to the bundle, and nothing more:

- B goes to the very path of the installed copy (the slot's clone), so every process and file that
  names the app by its path finds B there, and the old copy's still-running helpers (the app's
  daemon, its terminal hosts, acpmux) keep running from the replaced files, as after a real update;
- B keeps the installed app's identity: its bundle id (a capture clone's `.capslot<N>` id), the
  environment the clone carries (capture-host's lease folders in LSEnvironment) and its tag, so the
  build's own names (control socket, daemon session, acpmux home: build_names.py) are the ones A's
  state was saved under. A real update keeps all three; a B that shipped another tag is noted;
- B is staged next to the copy and moved in by rename, then the old copy is removed, so the path
  never holds half a bundle; it is ad-hoc signed, as capture-host signs every clone;
- UserDefaults, the app's state folders and the daemon are left alone.

  python3 -I scripts/cmux-next/tests/test_rj_update.py
"""
import os, plistlib, re, shutil, subprocess

import build_names


def info_of(app):
    """The app's Info.plist, {} when it has none or it cannot be read."""
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}
    return info if isinstance(info, dict) else {}


def commit_of(app):
    """The commit a build names: Info.plist CMUXCommit or CMUXGitSHA, else the capture-commit file
    restore-journey-slot.sh writes beside a staged build (as capture-host reads it); None if none."""
    info = info_of(app)
    for key in ("CMUXCommit", "CMUXGitSHA"):
        value = str(info.get(key) or "").strip().lower()
        if re.fullmatch(r"[0-9a-f]{7,40}", value):
            return value
    try:
        with open(os.path.join(os.path.dirname(os.path.realpath(app)), "capture-commit")) as f:
            value = f.read().strip().lower()
    except OSError:
        return None
    return value if re.fullmatch(r"[0-9a-f]{7,40}", value) else None


def updated_info(installed, original, new):
    """B's Info.plist as it is installed in place of a copy: `new` (B's own), with the identity of
    `installed` (the running copy's plist): its CFBundleIdentifier, the LSEnvironment entries the copy
    has that its own build `original` (A's staged plist) did not ship (capture-host's clone edits),
    and its CMUX_TAG (or none, when the copy names its tag by its path). Returns (info, notes)."""
    info = dict(new)
    notes = []
    if installed.get("CFBundleIdentifier"):
        # A clone's own id differs from its build's by design; B shipping another id than A did is worth a note.
        if original and new.get("CFBundleIdentifier") != original.get("CFBundleIdentifier"):
            notes.append(f"bundle id {new.get('CFBundleIdentifier')} -> {installed['CFBundleIdentifier']} (the installed copy's; A shipped {original.get('CFBundleIdentifier')})")
        info["CFBundleIdentifier"] = installed["CFBundleIdentifier"]
    env = dict(new.get("LSEnvironment") or {})
    shipped = dict(original.get("LSEnvironment") or {})
    for key, value in (installed.get("LSEnvironment") or {}).items():
        if shipped.get(key) != value:
            env[key] = value
    kept_tag = (installed.get("LSEnvironment") or {}).get("CMUX_TAG")
    if env.get("CMUX_TAG") != kept_tag:
        notes.append(f"tag {env.get('CMUX_TAG')!r} -> {kept_tag!r} (the installed copy's)")
        if kept_tag is None:
            env.pop("CMUX_TAG", None)
        else:
            env["CMUX_TAG"] = kept_tag
    if env:
        info["LSEnvironment"] = env
    else:
        info.pop("LSEnvironment", None)
    return info, notes


def _clone(src, dst):
    # APFS clone where it can (no copy cost), else a plain copy.
    if subprocess.run(["cp", "-cR", src, dst], capture_output=True).returncode != 0:
        shutil.rmtree(dst, ignore_errors=True)
        subprocess.run(["cp", "-R", src, dst], check=True)


def _place(bundle, new_src, original_src, installed, codesign):
    """B, with the identity of the `installed` plist, at `bundle`: staged beside it, signed, moved in by
    rename. A copy already at `bundle` is replaced; on any failure (an interrupt included) it is put back
    and nothing is left beside it. Returns (info, notes)."""
    stage, old = bundle + ".rj-update", bundle + ".rj-replaced"
    for path in (stage, old):
        shutil.rmtree(path, ignore_errors=True)
    had_copy = os.path.isdir(bundle)
    try:
        _clone(new_src, stage)
        info, notes = updated_info(installed, info_of(original_src) if original_src else {}, info_of(new_src))
        with open(os.path.join(stage, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        signed = subprocess.run([codesign, "--force", "--deep", "--sign", "-", stage], capture_output=True, text=True)
        if signed.returncode != 0:
            raise RuntimeError(f"codesign of {stage} failed: {(signed.stderr or signed.stdout).strip()[:300]}")
        if had_copy:
            os.rename(bundle, old)
        os.rename(stage, bundle)
    except BaseException:
        # SystemExit too (the journey's --max-seconds and signal handlers): the copy is never left missing.
        if had_copy and os.path.isdir(old) and not os.path.lexists(bundle):
            os.rename(old, bundle)
        shutil.rmtree(stage, ignore_errors=True)
        raise
    # The old copy's running helpers keep their open files; its path is gone, as after an update.
    shutil.rmtree(old, ignore_errors=True)
    return info, notes


def install(bundle, new_src, original_src, codesign="/usr/bin/codesign"):
    """Puts the build at `new_src` in place of the app copy at `bundle` (which must not be running),
    keeping the copy's identity (updated_info); `original_src` is the build the copy was made from.
    Returns a report: commits, names before and after, notes, and `identity` (the copy's plist before,
    for reinstall). Raises on any failure, leaving `bundle` as it was."""
    bundle = bundle.rstrip("/")
    if not os.path.isdir(bundle):
        raise RuntimeError(f"no installed copy at {bundle}")
    if not os.path.isdir(new_src):
        raise RuntimeError(f"no build to update to at {new_src}")
    installed = info_of(bundle)
    names_before = build_names.of_app(bundle)
    info, notes = _place(bundle, new_src, original_src, installed, codesign)
    return {
        "from_commit": commit_of(original_src) if original_src else None,
        "to_commit": commit_of(new_src),
        "to_version": [info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")],
        "names_before": names_before,
        "names_after": build_names.of_app(bundle),
        "notes": notes,
        "identity": installed,
    }


def reinstall(bundle, new_src, original_src, identity, codesign="/usr/bin/codesign"):
    """The updated copy again, when a later quit left `bundle` gone: B with the same `identity` (the
    report's), so its names stay A's. Returns the names it has."""
    bundle = bundle.rstrip("/")
    _place(bundle, new_src, original_src, identity, codesign)
    return build_names.of_app(bundle)


def different_builds(a, b):
    """True only when both commits are known and name different commits (a short and a full hash of
    one commit are the same build)."""
    a, b = (a or "").lower(), (b or "").lower()
    return bool(a) and bool(b) and not (a.startswith(b) or b.startswith(a))
