#!/usr/bin/env python3
"""Verify a published cmux-tui raw-artifact manifest.

The raw-artifact lane is separate from npm and PyPI publication.  This check
is used after R2 uploads to prove that the immutable manifest (and, on main,
the rolling ``latest`` manifest) points at the exact build and contains every
artifact required by the public installers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote


SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40,64}$")
GITHUB_REPOSITORY_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
GITHUB_ATTESTATION_RE = re.compile(
    r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$"
)
GITHUB_RELEASE_RE = re.compile(
    r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/tag/[^/?#]+$"
)
MACHINE_SOURCE_REPOSITORY = "https://github.com/manaflow-ai/cmux"
MACHINE_TARGETS = (
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
)
MACHINE_ARTIFACT_KEYS = ("chatmux-relay", "cmux-tui")
MAX_MANIFEST_BYTES = 1 << 20
# Raw binaries are intentionally bounded. This prevents a malformed public
# manifest from turning the post-publish verifier into an unbounded download.
MAX_ARTIFACT_BYTES = 512 << 20


class ManifestError(ValueError):
    """The manifest does not satisfy the raw-artifact contract."""


def _validate_machine_manifest(
    document: dict[str, Any], *, source: str, expected_commit: str
) -> None:
    """Validate the strict dual-binary Chatmux machine manifest."""

    expected_keys = {
        "schemaVersion",
        "sourceRepository",
        "sourceCommit",
        "version",
        "workflowRunUrl",
        "releaseUrl",
        "artifacts",
    }
    unexpected = sorted(set(document) - expected_keys)
    missing = sorted(expected_keys - set(document))
    if missing or unexpected:
        details: list[str] = []
        if missing:
            details.append(f"missing={missing}")
        if unexpected:
            details.append(f"unexpected={unexpected}")
        raise ManifestError(f"{source} machine manifest shape mismatch: {', '.join(details)}")
    if document.get("schemaVersion") != 1:
        raise ManifestError(f"{source} machine manifest schemaVersion must be 1")
    if document.get("sourceRepository") != MACHINE_SOURCE_REPOSITORY:
        raise ManifestError(f"{source} machine manifest sourceRepository is not cmux")
    source_commit = document.get("sourceCommit")
    if (
        not isinstance(source_commit, str)
        or COMMIT_RE.fullmatch(source_commit) is None
        or source_commit.lower() != expected_commit.lower()
    ):
        raise ManifestError(f"{source} machine manifest sourceCommit mismatch")
    expected_version = f"0.0.0-r2.sha-{expected_commit}"
    if document.get("version") != expected_version:
        raise ManifestError(
            f"{source} machine manifest version mismatch: expected {expected_version}"
        )
    workflow_url = document.get("workflowRunUrl")
    if (
        not isinstance(workflow_url, str)
        or GITHUB_ATTESTATION_RE.fullmatch(workflow_url) is None
        or not workflow_url.startswith(MACHINE_SOURCE_REPOSITORY + "/actions/runs/")
    ):
        raise ManifestError(f"{source} machine manifest workflowRunUrl is invalid")
    release_url = document.get("releaseUrl")
    expected_release = (
        f"{MACHINE_SOURCE_REPOSITORY}/releases/tag/chatmux-relay-r2-{expected_commit}"
    )
    if release_url != expected_release:
        raise ManifestError(f"{source} machine manifest releaseUrl is invalid")

    artifacts = document.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(MACHINE_TARGETS):
        actual = sorted(artifacts) if isinstance(artifacts, dict) else type(artifacts).__name__
        raise ManifestError(
            f"{source} machine manifest target set mismatch: expected {list(MACHINE_TARGETS)}, got {actual}"
        )
    for target in MACHINE_TARGETS:
        target_artifacts = artifacts[target]
        if not isinstance(target_artifacts, dict) or set(target_artifacts) != set(MACHINE_ARTIFACT_KEYS):
            actual = sorted(target_artifacts) if isinstance(target_artifacts, dict) else type(target_artifacts).__name__
            raise ManifestError(
                f"{source} machine manifest artifact keys for {target} mismatch: "
                f"expected {list(MACHINE_ARTIFACT_KEYS)}, got {actual}"
            )
        for artifact_kind in MACHINE_ARTIFACT_KEYS:
            record = target_artifacts[artifact_kind]
            if not isinstance(record, dict) or set(record) != {"name", "url", "sha256", "size"}:
                actual = sorted(record) if isinstance(record, dict) else type(record).__name__
                raise ManifestError(
                    f"{source} machine manifest record for {target}/{artifact_kind} is invalid: {actual}"
                )
            expected_name = f"{artifact_kind}-{target}"
            name = record["name"]
            if name != expected_name:
                raise ManifestError(
                    f"{source} machine manifest name mismatch for {target}/{artifact_kind}"
                )
            expected_url = f"https://files.cmux.com/chatmux-relay/{expected_commit}/{expected_name}"
            if record["url"] != expected_url:
                raise ManifestError(
                    f"{source} machine manifest URL mismatch for {target}/{artifact_kind}"
                )
            if not isinstance(record["sha256"], str) or not SHA256_RE.fullmatch(record["sha256"]):
                raise ManifestError(
                    f"{source} machine manifest SHA-256 is invalid for {target}/{artifact_kind}"
                )
            if isinstance(record["size"], bool) or not isinstance(record["size"], int) or record["size"] <= 0:
                raise ManifestError(
                    f"{source} machine manifest size is invalid for {target}/{artifact_kind}"
                )


def _verify_machine_binary_digests(
    document: dict[str, Any],
    *,
    source: str,
    artifact_base_url: str | None,
    artifact_directory: Path | None,
) -> None:
    if artifact_base_url is not None and artifact_directory is not None:
        raise ManifestError("choose one artifact base URL or artifact directory")
    if artifact_base_url is None and artifact_directory is None:
        return
    artifacts = document["artifacts"]
    assert isinstance(artifacts, dict)
    for target in MACHINE_TARGETS:
        target_artifacts = artifacts[target]
        assert isinstance(target_artifacts, dict)
        for artifact_kind in MACHINE_ARTIFACT_KEYS:
            record = target_artifacts[artifact_kind]
            assert isinstance(record, dict)
            name = record["name"]
            expected_digest = record["sha256"]
            expected_size = record["size"]
            assert isinstance(name, str)
            assert isinstance(expected_digest, str)
            assert isinstance(expected_size, int)
            if artifact_directory is not None:
                payload = _read_file(artifact_directory / name, max_bytes=MAX_ARTIFACT_BYTES)
            else:
                assert artifact_base_url is not None
                payload = _read_url(
                    f"{artifact_base_url.rstrip('/')}/{quote(name, safe='')}",
                    max_bytes=MAX_ARTIFACT_BYTES,
                )
            if len(payload) != expected_size:
                raise ManifestError(
                    f"{source} size mismatch for {name}: expected {expected_size}, got {len(payload)}"
                )
            actual_digest = hashlib.sha256(payload).hexdigest()
            if actual_digest.lower() != expected_digest.lower():
                raise ManifestError(
                    f"{source} digest mismatch for {name}: expected {expected_digest}, got {actual_digest}"
                )


def _decode_manifest(payload: bytes, source: str) -> dict[str, Any]:
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"{source} is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise ManifestError(f"{source} must contain a JSON object")
    return document


def _validate_manifest(
    document: dict[str, Any],
    *,
    source: str,
    expected_commit: str,
    required_artifacts: Iterable[str],
    exact_artifacts: Iterable[str] = (),
    forbidden_artifacts: Iterable[str] = (),
    required_dependency_artifacts: Iterable[str] = (),
    require_provenance: bool = False,
) -> None:
    commit = document.get("commit")
    if commit != expected_commit:
        raise ManifestError(
            f"{source} commit mismatch: expected {expected_commit}, got {commit!r}"
        )

    if require_provenance:
        source_repository = document.get("sourceRepository")
        source_commit = document.get("sourceCommit")
        attestation_url = document.get("attestationUrl")
        release_url = document.get("releaseUrl")
        if (
            not isinstance(source_repository, str)
            or GITHUB_REPOSITORY_RE.fullmatch(source_repository) is None
        ):
            raise ManifestError(f"{source} has an invalid sourceRepository")
        if (
            not isinstance(source_commit, str)
            or COMMIT_RE.fullmatch(source_commit) is None
            or source_commit.lower() != expected_commit.lower()
        ):
            raise ManifestError(f"{source} sourceCommit does not match expected commit")
        if (
            not isinstance(attestation_url, str)
            or GITHUB_ATTESTATION_RE.fullmatch(attestation_url) is None
            or not attestation_url.startswith(source_repository + "/actions/runs/")
        ):
            raise ManifestError(f"{source} has an invalid attestationUrl")
        if release_url is not None and (
            not isinstance(release_url, str)
            or GITHUB_RELEASE_RE.fullmatch(release_url) is None
            or not release_url.startswith(source_repository + "/releases/tag/")
        ):
            raise ManifestError(f"{source} has an invalid releaseUrl")

    binaries = document.get("binaries")
    if not isinstance(binaries, dict):
        raise ManifestError(f"{source} must contain a binaries object")

    artifact_names: set[str] = set()

    for artifact, digest in binaries.items():
        if not isinstance(artifact, str) or not isinstance(digest, str):
            raise ManifestError(f"{source} contains a malformed binary digest")
        if not artifact or artifact in {".", ".."} or "/" in artifact or "\\" in artifact:
            raise ManifestError(f"{source} contains an unsafe artifact name: {artifact!r}")
        if not SHA256_RE.fullmatch(digest):
            raise ManifestError(f"{source} has invalid SHA-256 for artifact {artifact}")
        artifact_names.add(artifact)

    expected = set(exact_artifacts)
    if expected and artifact_names != expected:
        missing = sorted(expected - artifact_names)
        unexpected = sorted(artifact_names - expected)
        details: list[str] = []
        if missing:
            details.append(f"missing={missing}")
        if unexpected:
            details.append(f"unexpected={unexpected}")
        raise ManifestError(f"{source} artifact set mismatch: {', '.join(details)}")

    for artifact in required_artifacts:
        digest = binaries.get(artifact)
        if digest is None:
            raise ManifestError(f"{source} missing required artifact {artifact}")

    forbidden = set(forbidden_artifacts)
    present_forbidden = sorted(forbidden & artifact_names)
    if present_forbidden:
        raise ManifestError(
            f"{source} contains forbidden artifact(s): {', '.join(present_forbidden)}"
        )

    dependency_names = set(required_dependency_artifacts)
    if not dependency_names:
        return
    dependencies = document.get("dependencies")
    if not isinstance(dependencies, dict):
        raise ManifestError(f"{source} must contain dependency metadata")
    cmux_tui = dependencies.get("cmux-tui")
    if not isinstance(cmux_tui, dict) or cmux_tui.get("commit") != expected_commit:
        raise ManifestError(f"{source} cmux-tui dependency commit mismatch")
    manifest_url = cmux_tui.get("manifest")
    if (
        not isinstance(manifest_url, str)
        or not manifest_url.startswith("https://files.cmux.com/")
        or not manifest_url.endswith(f"/cmux-tui/{expected_commit}/manifest.json")
    ):
        raise ManifestError(f"{source} has an invalid cmux-tui dependency manifest URL")
    dependency_binaries = cmux_tui.get("binaries")
    if not isinstance(dependency_binaries, dict):
        raise ManifestError(f"{source} must contain cmux-tui dependency binaries")
    actual_dependency_names = set(dependency_binaries)
    if actual_dependency_names != dependency_names:
        missing = sorted(dependency_names - actual_dependency_names)
        unexpected = sorted(actual_dependency_names - dependency_names)
        details: list[str] = []
        if missing:
            details.append(f"missing={missing}")
        if unexpected:
            details.append(f"unexpected={unexpected}")
        raise ManifestError(
            f"{source} cmux-tui dependency artifact set mismatch: {', '.join(details)}"
        )
    for artifact, reference in dependency_binaries.items():
        if not isinstance(artifact, str) or not artifact or "/" in artifact or "\\" in artifact:
            raise ManifestError(f"{source} has an unsafe cmux-tui dependency name")
        if not isinstance(reference, dict):
            raise ManifestError(f"{source} has malformed cmux-tui dependency {artifact}")
        url = reference.get("url")
        digest = reference.get("sha256")
        if (
            not isinstance(url, str)
            or not url.startswith("https://files.cmux.com/")
            or not url.endswith(f"/cmux-tui/{expected_commit}/{artifact}")
        ):
            raise ManifestError(f"{source} has an invalid cmux-tui dependency URL for {artifact}")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise ManifestError(f"{source} has invalid cmux-tui SHA-256 for {artifact}")


def _read_url(url: str, *, max_bytes: int = MAX_MANIFEST_BYTES) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Cache-Control": "no-cache",
            "User-Agent": "cmux-tui-manifest-verifier/1 (https://github.com/manaflow-ai/cmux)",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            content_length = getattr(response, "headers", {}).get("Content-Length")
            if content_length is not None:
                try:
                    if int(content_length) > max_bytes:
                        raise ManifestError(
                            f"{url} exceeds the {max_bytes}-byte size limit"
                        )
                except ValueError:
                    raise ManifestError(f"{url} has an invalid Content-Length")
            chunks: list[bytes] = []
            size = 0
            while True:
                chunk = response.read(min(64 * 1024, max_bytes - size + 1))
                if not chunk:
                    break
                size += len(chunk)
                if size > max_bytes:
                    raise ManifestError(
                        f"{url} exceeds the {max_bytes}-byte size limit"
                    )
                chunks.append(chunk)
            return b"".join(chunks)
    except (OSError, urllib.error.URLError) as error:
        raise ManifestError(f"could not fetch {url}: {error}") from error


def _read_file(path: Path, *, max_bytes: int = MAX_ARTIFACT_BYTES) -> bytes:
    try:
        size = path.stat().st_size
        if size > max_bytes:
            raise ManifestError(f"{path} exceeds the {max_bytes}-byte size limit")
        return path.read_bytes()
    except ManifestError:
        raise
    except OSError as error:
        raise ManifestError(f"could not read {path}: {error}") from error


def _verify_binary_digests(
    document: dict[str, Any],
    *,
    source: str,
    artifact_base_url: str | None,
    artifact_directory: Path | None,
    required_dependency_artifacts: Iterable[str] = (),
    dependency_artifact_directory: Path | None = None,
) -> None:
    """Download/read every listed binary and compare its SHA-256 digest."""

    if artifact_base_url is not None and artifact_directory is not None:
        raise ManifestError("choose one artifact base URL or artifact directory")
    if dependency_artifact_directory is not None and artifact_directory is None:
        raise ManifestError("dependency artifact directory requires an artifact directory")
    if artifact_base_url is None and artifact_directory is None:
        return

    binaries = document["binaries"]
    assert isinstance(binaries, dict)
    for artifact, expected in binaries.items():
        if artifact_base_url is not None:
            base = artifact_base_url.rstrip("/")
            payload = _read_url(f"{base}/{quote(artifact, safe='')}", max_bytes=MAX_ARTIFACT_BYTES)
        else:
            assert artifact_directory is not None
            payload = _read_file(artifact_directory / artifact)
        actual = hashlib.sha256(payload).hexdigest()
        if actual.lower() != str(expected).lower():
            raise ManifestError(
                f"{source} digest mismatch for {artifact}: expected {expected}, got {actual}"
            )

    dependency_names = set(required_dependency_artifacts)
    if not dependency_names:
        return
    dependencies = document["dependencies"]
    assert isinstance(dependencies, dict)
    cmux_tui = dependencies["cmux-tui"]
    assert isinstance(cmux_tui, dict)
    dependency_binaries = cmux_tui["binaries"]
    assert isinstance(dependency_binaries, dict)
    for artifact in dependency_names:
        reference = dependency_binaries[artifact]
        assert isinstance(reference, dict)
        expected = reference["sha256"]
        assert isinstance(expected, str)
        if dependency_artifact_directory is not None:
            payload = _read_file(dependency_artifact_directory / artifact)
        else:
            url = reference["url"]
            assert isinstance(url, str)
            payload = _read_url(url, max_bytes=MAX_ARTIFACT_BYTES)
        actual = hashlib.sha256(payload).hexdigest()
        if actual.lower() != expected.lower():
            raise ManifestError(
                f"{source} cmux-tui dependency digest mismatch for {artifact}: "
                f"expected {expected}, got {actual}"
            )


# Keep this name patchable in the unit tests and consistent with the other
# small network-verification helpers in cmux-tui.
urlopen = urllib.request.urlopen


def verify_manifest(
    url: str,
    *,
    expected_commit: str,
    required_artifacts: Iterable[str],
    exact_artifacts: Iterable[str] = (),
    forbidden_artifacts: Iterable[str] = (),
    artifact_base_url: str | None = None,
    required_dependency_artifacts: Iterable[str] = (),
    require_provenance: bool = False,
    machine_manifest: bool = False,
) -> None:
    """Fetch and validate one published manifest from a public URL."""

    document = _decode_manifest(_read_url(url), url)
    if machine_manifest:
        if any((required_artifacts, exact_artifacts, forbidden_artifacts, required_dependency_artifacts)):
            raise ManifestError("machine manifest cannot use generic artifact requirements")
        _validate_machine_manifest(document, source=url, expected_commit=expected_commit)
        _verify_machine_binary_digests(
            document,
            source=url,
            artifact_base_url=artifact_base_url,
            artifact_directory=None,
        )
    else:
        _validate_manifest(
            document,
            source=url,
            expected_commit=expected_commit,
            required_artifacts=required_artifacts,
            exact_artifacts=exact_artifacts,
            forbidden_artifacts=forbidden_artifacts,
            required_dependency_artifacts=required_dependency_artifacts,
            require_provenance=require_provenance,
        )
        _verify_binary_digests(
            document,
            source=url,
            artifact_base_url=artifact_base_url,
            artifact_directory=None,
            required_dependency_artifacts=required_dependency_artifacts,
        )


def verify_manifest_file(
    path: Path,
    *,
    expected_commit: str,
    required_artifacts: Iterable[str],
    exact_artifacts: Iterable[str] = (),
    forbidden_artifacts: Iterable[str] = (),
    artifact_directory: Path | None = None,
    required_dependency_artifacts: Iterable[str] = (),
    dependency_artifact_directory: Path | None = None,
    require_provenance: bool = False,
    machine_manifest: bool = False,
) -> None:
    """Validate the manifest generated before any R2 upload occurs."""

    payload = _read_file(path, max_bytes=MAX_MANIFEST_BYTES)
    document = _decode_manifest(payload, str(path))
    if machine_manifest:
        if any((required_artifacts, exact_artifacts, forbidden_artifacts, required_dependency_artifacts)):
            raise ManifestError("machine manifest cannot use generic artifact requirements")
        if dependency_artifact_directory is not None:
            raise ManifestError("machine manifest cannot use a dependency artifact directory")
        _validate_machine_manifest(document, source=str(path), expected_commit=expected_commit)
        _verify_machine_binary_digests(
            document,
            source=str(path),
            artifact_base_url=None,
            artifact_directory=artifact_directory,
        )
    else:
        _validate_manifest(
            document,
            source=str(path),
            expected_commit=expected_commit,
            required_artifacts=required_artifacts,
            exact_artifacts=exact_artifacts,
            forbidden_artifacts=forbidden_artifacts,
            required_dependency_artifacts=required_dependency_artifacts,
            require_provenance=require_provenance,
        )
        _verify_binary_digests(
            document,
            source=str(path),
            artifact_base_url=None,
            artifact_directory=artifact_directory,
            required_dependency_artifacts=required_dependency_artifacts,
            dependency_artifact_directory=dependency_artifact_directory,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify a cmux-tui raw-artifact manifest after publication."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest-url", help="Public manifest URL to fetch")
    source.add_argument(
        "--manifest-file",
        type=Path,
        help="Manifest generated locally before upload",
    )
    parser.add_argument(
        "--expected-commit",
        required=True,
        help="Exact commit SHA recorded in the manifest",
    )
    parser.add_argument(
        "--require-artifact",
        action="append",
        dest="required_artifacts",
        default=[],
        help="Artifact name that must have a valid SHA-256 digest (repeatable)",
    )
    parser.add_argument(
        "--exact-artifact",
        action="append",
        dest="exact_artifacts",
        default=[],
        help="Require the manifest artifact set to contain exactly these names (repeatable)",
    )
    parser.add_argument(
        "--forbid-artifact",
        action="append",
        dest="forbidden_artifacts",
        default=[],
        help="Reject a manifest that contains this artifact name (repeatable)",
    )
    parser.add_argument(
        "--require-dependency-artifact",
        action="append",
        dest="required_dependency_artifacts",
        default=[],
        help="Require an exact cmux-tui dependency artifact (repeatable)",
    )
    parser.add_argument(
        "--require-provenance",
        action="store_true",
        help="Require source-build repository, commit, attestation, and release metadata",
    )
    parser.add_argument(
        "--machine-manifest",
        action="store_true",
        help="Require the strict dual-binary Chatmux machine manifest schema",
    )
    parser.add_argument(
        "--dependency-artifact-directory",
        type=Path,
        help="Read and hash cmux-tui dependency binaries from this local directory",
    )
    artifact_source = parser.add_mutually_exclusive_group()
    artifact_source.add_argument(
        "--artifact-base-url",
        help="Download and hash every binary from this published object prefix",
    )
    artifact_source.add_argument(
        "--artifact-directory",
        type=Path,
        help="Read and hash every binary from this local directory",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.manifest_url:
            verify_manifest(
                args.manifest_url,
                expected_commit=args.expected_commit,
                required_artifacts=args.required_artifacts,
                exact_artifacts=args.exact_artifacts,
                forbidden_artifacts=args.forbidden_artifacts,
                artifact_base_url=args.artifact_base_url,
                required_dependency_artifacts=args.required_dependency_artifacts,
                require_provenance=args.require_provenance,
                machine_manifest=args.machine_manifest,
            )
            source = args.manifest_url
        else:
            assert args.manifest_file is not None
            verify_manifest_file(
                args.manifest_file,
                expected_commit=args.expected_commit,
                required_artifacts=args.required_artifacts,
                exact_artifacts=args.exact_artifacts,
                forbidden_artifacts=args.forbidden_artifacts,
                artifact_directory=args.artifact_directory,
                required_dependency_artifacts=args.required_dependency_artifacts,
                dependency_artifact_directory=args.dependency_artifact_directory,
                require_provenance=args.require_provenance,
                machine_manifest=args.machine_manifest,
            )
            source = str(args.manifest_file)
    except ManifestError as error:
        print(f"manifest verification failed: {error}", file=sys.stderr)
        return 1

    print(f"Verified cmux-tui manifest: {source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
