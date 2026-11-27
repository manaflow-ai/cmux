#!/usr/bin/env python3
"""Keep the herdr-derived agent screen-detection plugin pinned to upstream herdr.

The plugin under cmux-tui/bindings/examples/rust-agent-screen-detection vendors
herdr's agent-detection manifests (Apache-2.0) and adapts its detector engine.
HERDR_UPSTREAM.toml records the upstream revision, the upstream bytes of every
vendored manifest, and the upstream engine sources the port follows.
HERDR_PATCHES.toml lists the documented cmux edits to vendored manifests.

  sync  --herdr CHECKOUT --rev REV   copy the manifests at REV (git show, never
                                     checkout), reapply local patches or fail,
                                     rewrite SHA256SUMS and the pin
  check                              offline: vendored bytes match SHA256SUMS
                                     and the pin
  drift --herdr CHECKOUT --rev REV   report manifests and tracked engine files
                                     that changed upstream since the pin; exit 1
                                     on drift, with a markdown summary

Python standard library only. Run it with `python3 -I`.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PLUGIN_DIR = REPO_ROOT / "cmux-tui/bindings/examples/rust-agent-screen-detection"
PIN_NAME = "HERDR_UPSTREAM.toml"
PATCHES_NAME = "HERDR_PATCHES.toml"
SUMS_NAME = "SHA256SUMS"
UPSTREAM_REPOSITORY = "https://github.com/ogulcancelik/herdr"
UPSTREAM_MANIFEST_DIR = "src/detect/manifests"
# Upstream engine sources the Rust port follows. A change here needs a human
# review of src/{manifest,detect,process,scanner}.rs, never a byte copy.
TRACKED_ENGINE_FILES = (
    "src/detect/manifest.rs",
    "src/detect/mod.rs",
    "src/detect/manifest_update.rs",
    "src/pane/agent_detection.rs",
    "src/pane/osc.rs",
    # Ported into src/background_agent.rs, src/process.rs and
    # src/process/launchers.rs (950d012c and the process identity fixes).
    "src/pane/background_agent.rs",
    "src/platform/linux.rs",
    "src/platform/macos.rs",
)
# Apache-2.0 4(b): a vendored file that cmux changed says so on its first line.
PATCH_NOTICE = "# Modified by Manaflow (cmux): {reason}\n"
ENGINE_VERSION_FILE = "src/detect/manifest_update.rs"
ENGINE_VERSION_RE = re.compile(r"MANIFEST_ENGINE_VERSION:\s*u32\s*=\s*(\d+)\s*;")
MANIFEST_VERSION_RE = re.compile(r'^version\s*=\s*"([^"]+)"\s*$', re.M)
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
REV_RE = re.compile(r"^[0-9a-f]{40}$")


class SyncError(Exception):
    """A failure the caller must act on. The message says what to do."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest_version(data: bytes) -> str:
    match = MANIFEST_VERSION_RE.search(data.decode("utf-8"))
    return match.group(1) if match else ""


def toml_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\t", "\\t")
    return f'"{escaped}"'


# ---- local patches ---------------------------------------------------------


@dataclass
class Patch:
    file: str
    reason: str
    edits: list[tuple[str, str]] = field(default_factory=list)


def load_patches(plugin_dir: Path) -> dict[str, Patch]:
    path = plugin_dir / PATCHES_NAME
    if not path.exists():
        return {}
    document = tomllib.loads(path.read_text(encoding="utf-8"))
    patches: dict[str, Patch] = {}
    for entry in document.get("patch", []):
        file = entry.get("file", "")
        reason = entry.get("reason", "").strip()
        edits = [(edit.get("find", ""), edit.get("replace", "")) for edit in entry.get("edit", [])]
        if not file or not reason or not edits:
            raise SyncError(f"{PATCHES_NAME}: every [[patch]] needs file, reason and at least one [[patch.edit]]")
        if file in patches:
            raise SyncError(f"{PATCHES_NAME}: {file} is patched twice; merge the entries")
        for find, _ in edits:
            if not find:
                raise SyncError(f"{PATCHES_NAME}: {file} has an edit with an empty find")
        patches[file] = Patch(file, reason, edits)
    return patches


def edit_pattern(find: str) -> re.Pattern[str]:
    """`find` as a whole token: a word character at either end must not run
    into a neighbouring word character, so `priority = 100` never matches
    inside `priority = 1000`."""
    left = r"(?<!\w)" if re.match(r"\w", find[0]) else ""
    right = r"(?!\w)" if re.match(r"\w", find[-1]) else ""
    return re.compile(left + re.escape(find) + right)


def apply_patch(upstream: bytes, patch: Patch) -> bytes:
    text = upstream.decode("utf-8")
    for index, (find, replace) in enumerate(patch.edits, start=1):
        pattern = edit_pattern(find)
        count = len(pattern.findall(text))
        if count != 1:
            raise SyncError(
                f"local patch for {patch.file} no longer applies: edit {index} matches "
                f"{count} times upstream (needs exactly 1). Check whether upstream now covers "
                f"the reason ({patch.reason!r}); drop the patch if it does, else rewrite the edit."
            )
        text = pattern.sub(lambda _: replace, text, count=1)
    return (PATCH_NOTICE.format(reason=" ".join(patch.reason.split())) + text).encode("utf-8")


# ---- pin file --------------------------------------------------------------


@dataclass
class ManifestPin:
    file: str
    version: str
    upstream_sha256: str
    vendored_sha256: str
    patch_reason: str = ""


@dataclass
class Pin:
    repository: str
    revision: str
    herdr_version: str
    engine_version: int
    synced: str
    manifests: list[ManifestPin]
    engine: dict[str, str]


def render_pin(pin: Pin) -> str:
    lines = [
        "# herdr upstream pin for the agent screen-detection plugin.",
        "# Written by scripts/cmux-next/herdr-sync.py sync; verified offline by",
        "# `python3 -I scripts/cmux-next/herdr-sync.py check`. Do not edit by hand.",
        "# upstream_sha256 is the byte hash of the manifest at `revision`.",
        "# vendored_sha256 differs only for a file with a documented local patch",
        f"# ({PATCHES_NAME}). engine lists the upstream sources the Rust port follows.",
        "",
        "[upstream]",
        f"repository = {toml_string(pin.repository)}",
        f"revision = {toml_string(pin.revision)}",
        f"herdr_version = {toml_string(pin.herdr_version)}",
        f"engine_version = {pin.engine_version}",
        f"synced = {toml_string(pin.synced)}",
        f"manifest_dir = {toml_string(UPSTREAM_MANIFEST_DIR)}",
    ]
    for manifest in sorted(pin.manifests, key=lambda item: item.file):
        lines += [
            "",
            "[[manifest]]",
            f"file = {toml_string(manifest.file)}",
            f"version = {toml_string(manifest.version)}",
            f"upstream_sha256 = {toml_string(manifest.upstream_sha256)}",
            f"vendored_sha256 = {toml_string(manifest.vendored_sha256)}",
            f"local_patch = {'true' if manifest.patch_reason else 'false'}",
        ]
        if manifest.patch_reason:
            lines.append(f"patch_reason = {toml_string(manifest.patch_reason)}")
    for path in sorted(pin.engine):
        lines += ["", "[[engine]]", f"path = {toml_string(path)}", f"sha256 = {toml_string(pin.engine[path])}"]
    return "\n".join(lines) + "\n"


def load_pin(plugin_dir: Path) -> Pin:
    path = plugin_dir / PIN_NAME
    if not path.exists():
        raise SyncError(f"{path} is missing; run `herdr-sync.py sync` to create it")
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        raise SyncError(f"{path}: {error}") from error
    upstream = document.get("upstream", {})
    try:
        manifests = [
            ManifestPin(
                file=item["file"],
                version=item["version"],
                upstream_sha256=item["upstream_sha256"],
                vendored_sha256=item["vendored_sha256"],
                patch_reason=item.get("patch_reason", "") if item.get("local_patch") else "",
            )
            for item in document.get("manifest", [])
        ]
        engine = {item["path"]: item["sha256"] for item in document.get("engine", [])}
        return Pin(
            repository=upstream["repository"],
            revision=upstream["revision"],
            herdr_version=upstream["herdr_version"],
            engine_version=int(upstream["engine_version"]),
            synced=upstream["synced"],
            manifests=manifests,
            engine=engine,
        )
    except (KeyError, TypeError, ValueError) as error:
        raise SyncError(f"{path}: missing or malformed field {error}") from error


def render_sums(files: dict[str, bytes]) -> str:
    return "".join(f"{sha256(data)}  {name}\n" for name, data in sorted(files.items()))


def parse_sums(text: str) -> dict[str, str]:
    sums: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        digest, separator, name = line.partition("  ")
        if not separator or not SHA_RE.match(digest) or not name or "/" in name:
            raise SyncError(f"{SUMS_NAME} line {number} is not `<sha256>  <file>`: {line!r}")
        sums[name] = digest
    return sums


# ---- upstream access (a local herdr checkout, read only) -------------------


def git(checkout: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(checkout), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise SyncError(f"git {' '.join(args)} failed in {checkout}: {message}")
    return result.stdout


def resolve_rev(checkout: Path, rev: str) -> str:
    return git(checkout, "rev-parse", "--verify", f"{rev}^{{commit}}").decode().strip()


def show(checkout: Path, rev: str, path: str) -> bytes:
    return git(checkout, "show", f"{rev}:{path}")


def upstream_manifests(checkout: Path, rev: str) -> dict[str, bytes]:
    listing = git(checkout, "ls-tree", "--name-only", f"{rev}:{UPSTREAM_MANIFEST_DIR}").decode()
    names = sorted(name for name in listing.splitlines() if name.endswith(".toml"))
    if not names:
        raise SyncError(f"no manifests under {UPSTREAM_MANIFEST_DIR} at {rev}")
    return {name: show(checkout, rev, f"{UPSTREAM_MANIFEST_DIR}/{name}") for name in names}


REMOVED = "removed"


def upstream_engine(checkout: Path, rev: str, allow_missing: bool = False) -> dict[str, str]:
    """sha256 of each tracked file; `REMOVED` for one upstream no longer has
    (only when `allow_missing`: drift reports it, sync refuses to pin it)."""
    present = set(git(checkout, "ls-tree", "-r", "--name-only", rev, "--", *TRACKED_ENGINE_FILES).decode().splitlines())
    hashes: dict[str, str] = {}
    for path in TRACKED_ENGINE_FILES:
        if path in present:
            hashes[path] = sha256(show(checkout, rev, path))
        elif allow_missing:
            hashes[path] = REMOVED
        else:
            raise SyncError(f"tracked engine file {path} is missing at {rev}; update TRACKED_ENGINE_FILES")
    return hashes


def upstream_version(checkout: Path, rev: str) -> str:
    cargo = tomllib.loads(show(checkout, rev, "Cargo.toml").decode("utf-8"))
    return str(cargo.get("package", {}).get("version", ""))


def upstream_engine_version(checkout: Path, rev: str) -> int:
    match = ENGINE_VERSION_RE.search(show(checkout, rev, ENGINE_VERSION_FILE).decode("utf-8"))
    if not match:
        raise SyncError(f"MANIFEST_ENGINE_VERSION not found in {ENGINE_VERSION_FILE} at {rev}")
    return int(match.group(1))


# ---- commands --------------------------------------------------------------


def sync(plugin_dir: Path, checkout: Path, rev: str, synced: str) -> list[str]:
    revision = resolve_rev(checkout, rev)
    upstream = upstream_manifests(checkout, revision)
    patches = load_patches(plugin_dir)
    unknown = sorted(set(patches) - set(upstream))
    if unknown:
        raise SyncError(f"{PATCHES_NAME} patches files that upstream no longer ships: {', '.join(unknown)}")

    vendored: dict[str, bytes] = {}
    pins: list[ManifestPin] = []
    for name, data in upstream.items():
        patch = patches.get(name)
        local = apply_patch(data, patch) if patch else data
        vendored[name] = local
        pins.append(
            ManifestPin(
                file=name,
                version=manifest_version(local),
                upstream_sha256=sha256(data),
                vendored_sha256=sha256(local),
                patch_reason=patch.reason if patch else "",
            )
        )

    manifest_dir = plugin_dir / "manifests"
    notes: list[str] = []
    for existing in sorted(manifest_dir.glob("*.toml")):
        if existing.name not in vendored:
            existing.unlink()
            notes.append(f"removed {existing.name}: upstream no longer ships it; drop it from src/manifest.rs")
    for name, data in vendored.items():
        target = manifest_dir / name
        previous = target.read_bytes() if target.exists() else None
        if previous is None:
            notes.append(f"added {name}: register it in src/manifest.rs BUNDLED_MANIFESTS")
        elif previous != data:
            notes.append(f"updated {name} ({manifest_version(previous)} -> {manifest_version(data)})")
        target.write_bytes(data)
    (manifest_dir / SUMS_NAME).write_text(render_sums(vendored), encoding="utf-8")
    pin = Pin(
        repository=UPSTREAM_REPOSITORY,
        revision=revision,
        herdr_version=upstream_version(checkout, revision),
        engine_version=upstream_engine_version(checkout, revision),
        synced=synced,
        manifests=pins,
        engine=upstream_engine(checkout, revision),
    )
    (plugin_dir / PIN_NAME).write_text(render_pin(pin), encoding="utf-8")
    return notes


def check(plugin_dir: Path) -> list[str]:
    """Return every offline inconsistency. An empty list means the tree is clean."""
    problems: list[str] = []
    try:
        pin = load_pin(plugin_dir)
        patches = load_patches(plugin_dir)
        sums = parse_sums((plugin_dir / "manifests" / SUMS_NAME).read_text(encoding="utf-8"))
    except (SyncError, OSError) as error:
        return [str(error)]

    if not REV_RE.match(pin.revision):
        problems.append(f"{PIN_NAME}: revision {pin.revision!r} is not a 40-character commit id")
    for path in TRACKED_ENGINE_FILES:
        if not SHA_RE.match(pin.engine.get(path, "")):
            problems.append(f"{PIN_NAME}: engine file {path} has no sha256")

    vendored = {path.name: path.read_bytes() for path in (plugin_dir / "manifests").glob("*.toml")}
    pinned = {manifest.file: manifest for manifest in pin.manifests}
    for name in sorted(set(vendored) | set(sums) | set(pinned)):
        data = vendored.get(name)
        if data is None:
            problems.append(f"{name}: listed in {SUMS_NAME} or {PIN_NAME} but not vendored")
            continue
        actual = sha256(data)
        if sums.get(name) != actual:
            problems.append(f"{name}: {SUMS_NAME} records {sums.get(name)}, file is {actual}")
        entry = pinned.get(name)
        if entry is None:
            problems.append(f"{name}: not in {PIN_NAME}; vendor it with `herdr-sync.py sync`")
            continue
        if entry.vendored_sha256 != actual:
            problems.append(f"{name}: {PIN_NAME} records vendored {entry.vendored_sha256}, file is {actual}")
        if entry.version != manifest_version(data):
            problems.append(f"{name}: {PIN_NAME} records version {entry.version}, file has {manifest_version(data)}")
        patch = patches.get(name)
        if entry.patch_reason:
            if patch is None:
                problems.append(f"{name}: {PIN_NAME} marks a local patch that {PATCHES_NAME} does not document")
            elif patch.reason != entry.patch_reason:
                problems.append(f"{name}: patch reason differs between {PIN_NAME} and {PATCHES_NAME}; rerun sync")
            elif actual == entry.upstream_sha256:
                problems.append(f"{name}: marked as patched but equals the upstream bytes")
            else:
                text = data.decode("utf-8")
                if not text.startswith(PATCH_NOTICE.format(reason=" ".join(patch.reason.split()))):
                    problems.append(f"{name}: a patched file must start with its Manaflow change notice; rerun sync")
                for find, replace in patch.edits:
                    if len(edit_pattern(replace).findall(text)) < 1:
                        problems.append(f"{name}: a documented patch edit is not present in the vendored file")
                        break
        else:
            if patch is not None:
                problems.append(f"{name}: {PATCHES_NAME} patches it but {PIN_NAME} does not; rerun sync")
            if actual != entry.upstream_sha256:
                problems.append(
                    f"{name}: differs from upstream {pin.revision[:12]} without a documented local patch; "
                    f"restore it with `herdr-sync.py sync` or document the edit in {PATCHES_NAME}"
                )
    return problems


@dataclass
class Drift:
    upstream_revision: str
    changed: list[tuple[str, str, str]]
    added: list[str]
    removed: list[str]
    engine_changed: list[str]
    commits: list[str]

    @property
    def any(self) -> bool:
        return bool(self.changed or self.added or self.removed or self.engine_changed)


def drift(plugin_dir: Path, checkout: Path, rev: str) -> tuple[Pin, Drift]:
    pin = load_pin(plugin_dir)
    revision = resolve_rev(checkout, rev)
    upstream = upstream_manifests(checkout, revision)
    pinned = {manifest.file: manifest for manifest in pin.manifests}
    changed = [
        (name, pinned[name].version, manifest_version(data))
        for name, data in upstream.items()
        if name in pinned and sha256(data) != pinned[name].upstream_sha256
    ]
    added = sorted(set(upstream) - set(pinned))
    removed = sorted(set(pinned) - set(upstream))
    engine_now = upstream_engine(checkout, revision, allow_missing=True)
    engine_changed = [
        f"{path} (removed upstream)" if engine_now[path] == REMOVED else path
        for path in TRACKED_ENGINE_FILES
        if engine_now[path] != pin.engine.get(path)
    ]
    commits: list[str] = []
    if changed or added or removed or engine_changed:
        paths = [UPSTREAM_MANIFEST_DIR, *TRACKED_ENGINE_FILES]
        try:
            log = git(checkout, "log", "--format=%h %s", f"{pin.revision}..{revision}", "--", *paths)
            commits = log.decode("utf-8", "replace").splitlines()
        except SyncError:
            # A shallow clone does not hold the pinned commit; the summary
            # links the compare view instead.
            commits = []
    return pin, Drift(revision, changed, added, removed, engine_changed, commits)


def plain(text: str) -> str:
    """Upstream text shown in the issue: no mentions, links or code spans."""
    return text.replace("`", "'").replace("@", "(at)").replace("<", "(").replace(">", ")")


def drift_markdown(pin: Pin, report: Drift) -> str:
    compare = f"{pin.repository}/compare/{pin.revision}...{report.upstream_revision}"
    lines = [
        "The scheduled herdr drift check found upstream changes that the cmux agent "
        "screen-detection plugin (`cmux-tui/bindings/examples/rust-agent-screen-detection`) "
        "has not taken.",
        "",
        f"- Pinned: `{pin.revision}` (herdr {pin.herdr_version}, synced {pin.synced})",
        f"- Upstream checked: `{report.upstream_revision}`",
        f"- Compare: {compare}",
        "",
    ]
    if report.changed or report.added or report.removed:
        lines.append("Manifests:")
        lines += [f"- `{plain(name)}` {plain(old)} -> {plain(new)}" for name, old, new in report.changed]
        lines += [f"- `{plain(name)}` added upstream" for name in report.added]
        lines += [f"- `{plain(name)}` removed upstream" for name in report.removed]
        lines.append("")
    if report.engine_changed:
        lines.append("Tracked engine sources (review and port by hand):")
        lines += [f"- `{path}`" for path in report.engine_changed]
        lines.append("")
    if report.commits:
        lines.append("Upstream commits on these paths:")
        lines += [f"- {plain(commit)}" for commit in report.commits]
        lines.append("")
    lines += [
        "To take the change: `python3 -I scripts/cmux-next/herdr-sync.py sync --herdr <checkout> "
        f"--rev {report.upstream_revision}`, port engine changes in the plugin's Rust sources, "
        "update the attribution notes, and run the plugin tests on a Testbox.",
    ]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--plugin-dir", type=Path, default=DEFAULT_PLUGIN_DIR)
    commands = parser.add_subparsers(dest="command", required=True)
    sync_parser = commands.add_parser("sync", help="vendor the manifests at a herdr revision")
    sync_parser.add_argument("--herdr", type=Path, required=True, help="a local herdr git checkout (read only)")
    sync_parser.add_argument("--rev", required=True)
    sync_parser.add_argument("--date", default=datetime.datetime.now(datetime.UTC).date().isoformat())
    commands.add_parser("check", help="offline: vendored bytes match SHA256SUMS and the pin")
    drift_parser = commands.add_parser("drift", help="report upstream changes since the pin")
    drift_parser.add_argument("--herdr", type=Path, required=True)
    drift_parser.add_argument("--rev", default="HEAD")
    drift_parser.add_argument("--summary-out", type=Path, help="write the markdown summary here")
    args = parser.parse_args(argv)

    try:
        if args.command == "sync":
            for note in sync(args.plugin_dir, args.herdr, args.rev, args.date):
                print(note)
            problems = check(args.plugin_dir)
            for problem in problems:
                print(f"herdr-sync: {problem}", file=sys.stderr)
            return 1 if problems else 0
        if args.command == "check":
            problems = check(args.plugin_dir)
            for problem in problems:
                print(f"herdr-sync check: {problem}", file=sys.stderr)
            if not problems:
                print("herdr-sync check: vendored manifests match SHA256SUMS and the pin")
            return 1 if problems else 0
        pin, report = drift(args.plugin_dir, args.herdr, args.rev)
        summary = drift_markdown(pin, report)
        if args.summary_out:
            args.summary_out.write_text(summary if report.any else "", encoding="utf-8")
        if report.any:
            print(summary, end="")
            return 1
        print(f"herdr-sync drift: none since {pin.revision[:12]} (upstream {report.upstream_revision[:12]})")
        return 0
    except SyncError as error:
        print(f"herdr-sync: {error}", file=sys.stderr)
        return 2
    except Exception as error:  # noqa: BLE001 - exit 1 means drift; anything else is a tool failure
        print(f"herdr-sync: unexpected {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
