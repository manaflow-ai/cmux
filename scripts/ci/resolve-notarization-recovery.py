#!/usr/bin/env python3
"""Validate and resolve one downloaded nightly notarization recovery artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import tarfile
from typing import Any, Mapping


CHANNELS = {
    "nightly": {"prefix": "cmux-nightly-macos", "release_tag": "nightly", "app": "cmux NIGHTLY.app"},
    "rc": {"prefix": "cmux-rc-macos", "release_tag": "rc", "app": "cmux RC.app"},
}
VARIANTS = {"arm64", "x86_64", "universal"}
HEX_SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
SHA = re.compile(r"[0-9a-fA-F]{40}\Z")
SUBMISSION_ID = re.compile(r"[A-Za-z0-9._-]+\Z")
BUILD = re.compile(r"[0-9]+\Z")


def _required(manifest: Mapping[str, Any], keys: tuple[str, ...]) -> None:
    missing = [key for key in keys if not manifest.get(key)]
    if missing:
        raise ValueError(f"recovery manifest missing: {', '.join(missing)}")


def validate_manifest(
    manifest: Mapping[str, Any],
    source_run_id: str,
    source_head_sha: str,
    channel: str,
    variant: str,
    run_attempt: str | None = None,
    *,
    strict: bool = False,
) -> dict[str, Any]:
    """Validate identity and canonical names, returning a plain manifest copy.

    ``strict`` is used by automatic recovery and requires the current schema
    and publication metadata. Manual verification keeps those historical
    fields optional so retained older artifacts can still be inspected.
    """
    if channel not in CHANNELS or variant not in VARIANTS:
        raise ValueError("unsupported recovery channel or variant")
    if not re.fullmatch(r"[0-9]+\Z", str(source_run_id)):
        raise ValueError("invalid recovery source run id")
    if not SHA.fullmatch(str(source_head_sha)):
        raise ValueError("invalid recovery source head SHA")
    manifest = dict(manifest)
    core = (
        "source_run_id", "head_sha", "channel", "variant", "release_tag", "dmg_prefix",
        "build", "dmg_path", "app_path", "state_path", "log_path", "app_archive_path",
        "immutable_path", "dmg_sha256", "submission_id",
    )
    _required(manifest, core)
    if str(manifest["source_run_id"]) != str(source_run_id):
        raise ValueError("recovery source run mismatch")
    if str(manifest["head_sha"]).lower() != str(source_head_sha).lower():
        raise ValueError("recovery head SHA mismatch")
    if manifest["channel"] != channel or manifest["variant"] != variant:
        raise ValueError("recovery channel or variant mismatch")
    identity = CHANNELS[channel]
    if manifest["release_tag"] != identity["release_tag"]:
        raise ValueError("recovery release tag does not match channel")
    if manifest["dmg_prefix"] != identity["prefix"]:
        raise ValueError("recovery DMG prefix does not match channel")
    if not BUILD.fullmatch(str(manifest["build"])):
        raise ValueError("invalid recovery build number")
    expected_dmg = f"{identity['prefix']}-{variant}.dmg"
    expected_immutable = f"{identity['prefix']}-{variant}-{manifest['build']}.dmg"
    if Path(str(manifest["dmg_path"])).name != expected_dmg:
        raise ValueError("recovery DMG name does not match channel and variant")
    if Path(str(manifest["immutable_path"])).name != expected_immutable:
        raise ValueError("recovery immutable DMG name does not match build")
    if Path(str(manifest["app_path"])).name != identity["app"]:
        raise ValueError("recovery app name does not match channel")
    app_parts = PurePosixPath(str(manifest["app_path"]))
    if app_parts.parts[:1] != ("cmux-nightly-notarization-recovery-app",):
        raise ValueError("recovery app path is not in the extracted app directory")
    if manifest["app_archive_path"] != "cmux-nightly-notarization-recovery-app.tar.gz":
        raise ValueError("recovery app archive name is not canonical")
    if manifest["state_path"] != f"{expected_dmg}.notarization.state":
        raise ValueError("recovery state path is not canonical")
    if manifest["log_path"] != f"{expected_dmg}.notarization.log":
        raise ValueError("recovery log path is not canonical")
    if not HEX_SHA256.fullmatch(str(manifest["dmg_sha256"])):
        raise ValueError("invalid recovery DMG SHA-256")
    if not SUBMISSION_ID.fullmatch(str(manifest["submission_id"])):
        raise ValueError("invalid recovery submission id")
    short_sha = str(manifest.get("short_sha", ""))
    if not re.fullmatch(r"[0-9a-fA-F]{7}", short_sha) or not str(manifest["head_sha"]).lower().startswith(short_sha.lower()):
        raise ValueError("invalid recovery short SHA")
    if "schema" in manifest and manifest["schema"] != 1:
        raise ValueError("unsupported recovery manifest schema")
    if strict and manifest.get("schema") != 1:
        raise ValueError("automatic recovery requires manifest schema 1")
    if strict and run_attempt is None:
        raise ValueError("automatic recovery requires source run attempt")
    if "source_run_attempt" in manifest:
        if not re.fullmatch(r"[0-9]+\Z", str(manifest["source_run_attempt"])):
            raise ValueError("invalid recovery source run attempt")
        if run_attempt is not None and str(manifest["source_run_attempt"]) != str(run_attempt):
            raise ValueError("recovery run attempt mismatch")
    elif strict:
        raise ValueError("automatic recovery requires source run attempt")
    if "should_publish" in manifest and not isinstance(manifest["should_publish"], bool):
        raise ValueError("invalid recovery should_publish value")
    if strict and manifest.get("should_publish") is not True:
        raise ValueError("automatic recovery requires should_publish=true")
    return manifest


def safe_path(root: Path, value: str, key: str, *, directory: bool = False) -> Path:
    relative = PurePosixPath(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe recovery path for {key}")
    path = (root / Path(*relative.parts)).resolve()
    if root not in path.parents:
        raise ValueError(f"recovery path escapes artifact for {key}")
    if directory and not path.is_dir():
        raise ValueError(f"recovery directory is missing for {key}")
    if not directory and not path.is_file():
        raise ValueError(f"recovery file is missing for {key}")
    return path


def _under(path: PurePosixPath, root: PurePosixPath) -> bool:
    return path == root or root in path.parents


def extract_app_archive(root: Path, archive_path: Path, app_relative: str) -> None:
    """Safely extract the signed app, allowing links that stay inside the app."""
    app_rel = PurePosixPath(app_relative)
    app_root = PurePosixPath(app_rel.parts[-1])
    destination = root / Path(*app_rel.parts[:-1])
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("recovery app archive is empty")
        for member in members:
            rel = PurePosixPath(member.name)
            if rel.is_absolute() or not rel.parts or rel.parts[0] != app_root.name or ".." in rel.parts:
                raise ValueError(f"unsafe recovery archive member: {member.name}")
            if member.issym() or member.islnk():
                target = PurePosixPath(posixpath.normpath(str(rel.parent / member.linkname)))
                if target.is_absolute() or not _under(target, app_root):
                    raise ValueError(f"unsafe recovery archive link: {member.name}")
        if {PurePosixPath(member.name).parts[0] for member in members} != {app_root.name}:
            raise ValueError("recovery app archive contains multiple roots")
        archive.extractall(destination)
    app_path = root / Path(*app_rel.parts)
    if not (app_path / "Contents").is_dir():
        raise ValueError("recovered app archive did not produce an app bundle")


def resolve_files(manifest: Mapping[str, Any], manifest_path: Path, *, extract_app: bool = False) -> dict[str, Path | str]:
    root = manifest_path.parent.resolve()
    files = {key: safe_path(root, str(manifest[key]), key) for key in ("state_path", "dmg_path", "log_path", "app_archive_path")}
    if extract_app:
        extract_app_archive(root, files["app_archive_path"], str(manifest["app_path"]))
    app = safe_path(root, str(manifest["app_path"]), "app_path", directory=True)
    if not (app / "Contents").is_dir():
        raise ValueError("recovery app is not a bundle")
    digest = hashlib.sha256()
    with files["dmg_path"].open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest().lower() != str(manifest["dmg_sha256"]).lower():
        raise ValueError("recovery DMG SHA-256 mismatch")
    state = {}
    for line in files["state_path"].read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or not key or key in state:
            raise ValueError("invalid or duplicate notarization state line")
        state[key] = value
    if state.get("submission_id") != manifest["submission_id"] or state.get("dmg_sha256", "").lower() != str(manifest["dmg_sha256"]).lower():
        raise ValueError("notarization state does not match recovery manifest")
    if state.get("submit_exit", "0") != "0":
        raise ValueError("notarization submit exited nonzero")
    values = {
        "STATE_FILE": files["state_path"], "DMG_RELEASE": files["dmg_path"],
        "EVIDENCE_FILE": files["log_path"], "APP_PATH": app,
        "IMMUTABLE_NAME": Path(str(manifest["immutable_path"])).name,
        "ALIAS_NAME": f"{manifest['dmg_prefix']}-{manifest['variant']}.dmg",
        "DMG_PREFIX": manifest["dmg_prefix"], "RELEASE_TAG": manifest["release_tag"],
        "BUILD": manifest["build"],
    }
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("source_run_id")
    parser.add_argument("source_head_sha")
    parser.add_argument("channel", choices=tuple(CHANNELS))
    parser.add_argument("variant", choices=tuple(VARIANTS))
    parser.add_argument(
        "--source-run-attempt", "--run-attempt", dest="run_attempt",
        help="exact GitHub Actions run attempt that created the recovery artifact",
    )
    parser.add_argument("--metadata-only", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument(
        "--published", action="store_true",
        help="require strict current-schema metadata marked for publication",
    )
    parser.add_argument("--extract-app", action="store_true")
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    strict = args.strict or args.published
    if args.published and manifest.get("should_publish") is not True:
        raise ValueError("published recovery requires should_publish=true")
    validated = validate_manifest(
        manifest,
        args.source_run_id,
        args.source_head_sha,
        args.channel,
        args.variant,
        args.run_attempt,
        strict=strict,
    )
    if args.metadata_only:
        for key in ("source_run_id", "source_run_attempt", "head_sha", "channel", "variant", "release_tag", "dmg_prefix", "build", "should_publish"):
            if key in validated:
                print(f"{key}={validated[key]}")
        return 0
    values = resolve_files(validated, manifest_path, extract_app=args.extract_app)
    for key, value in values.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, tarfile.TarError) as error:
        raise SystemExit(str(error))
