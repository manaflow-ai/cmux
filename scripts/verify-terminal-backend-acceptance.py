#!/usr/bin/env python3
"""Create and verify commit-bound terminal-backend acceptance manifests."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
from typing import Any, Sequence


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC_PATH = REPO_ROOT / "tests/terminal-backend/acceptance/spec.json"
SCHEMA_PATH = REPO_ROOT / "tests/terminal-backend/acceptance/manifest.schema.json"
IDENTITY_TOOL = REPO_ROOT / "scripts/terminal-backend-identity.py"
SCHEMA_VERSION = 1
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class AcceptanceError(RuntimeError):
    pass


def run(arguments: Sequence[str], *, cwd: pathlib.Path = REPO_ROOT) -> str:
    completed = subprocess.run(
        list(arguments),
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise AcceptanceError(f"command failed ({completed.returncode}): {arguments!r}: {detail}")
    return completed.stdout.strip()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def parse_timestamp(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} must be a non-empty date-time string")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise AcceptanceError(f"{label} is not a valid date-time: {value!r}") from error
    if parsed.tzinfo is None:
        raise AcceptanceError(f"{label} must include a timezone")
    return parsed


def expect_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} must be a non-empty string")
    return value


def expect_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise AcceptanceError(f"{label} keys differ from schema: {sorted(value)}")


def expect_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise AcceptanceError(f"{label} must be a lowercase SHA-256 digest")
    return value


def expect_commit(value: Any, label: str) -> str:
    if not isinstance(value, str) or COMMIT_PATTERN.fullmatch(value) is None:
        raise AcceptanceError(f"{label} must be a lowercase 40-character Git commit")
    return value


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"could not read JSON at {path}: {error}") from error
    if not isinstance(value, dict):
        raise AcceptanceError(f"expected a JSON object at {path}")
    return value


def atomic_write_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def git_commit() -> str:
    value = run(["git", "rev-parse", "HEAD"])
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        raise AcceptanceError(f"unexpected Git commit: {value!r}")
    return value


def git_status() -> str:
    return run(["git", "status", "--porcelain=v1", "--untracked-files=all"])


def submodule_state(*, require_clean: bool) -> dict[str, str]:
    output = run(["git", "submodule", "status", "--recursive"])
    result: dict[str, str] = {}
    for line in output.splitlines():
        if not line:
            continue
        marker = line[0]
        fields = line[1:].split()
        if len(fields) < 2:
            raise AcceptanceError(f"could not parse submodule status: {line!r}")
        commit, relative = fields[0], fields[1]
        if marker != " ":
            raise AcceptanceError(f"submodule {relative} is not at the recorded commit: {line}")
        path = REPO_ROOT / relative
        if require_clean:
            dirty = run(
                ["git", "status", "--porcelain=v1", "--untracked-files=all"],
                cwd=path,
            )
            if dirty:
                raise AcceptanceError(f"submodule {relative} is dirty:\n{dirty}")
        result[relative] = commit
    return result


def assert_clean_source() -> tuple[str, dict[str, str]]:
    status = git_status()
    if status:
        raise AcceptanceError(f"source worktree is dirty:\n{status}")
    return git_commit(), submodule_state(require_clean=True)


def ensure_outside_source(path: pathlib.Path) -> pathlib.Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(REPO_ROOT.resolve())
    except ValueError:
        return resolved
    raise AcceptanceError(f"artifact root must be outside the source worktree: {resolved}")


def locate_tagged_app(tag: str, explicit: pathlib.Path | None) -> pathlib.Path:
    if explicit is not None:
        candidates = [explicit.expanduser().resolve()]
    else:
        root = (
            pathlib.Path.home()
            / "Library/Developer/Xcode/DerivedData"
            / f"cmux-{tag}/Build/Products/Debug"
        )
        candidates = sorted(root.glob("*.app"))
    candidates = [candidate for candidate in candidates if candidate.is_dir()]
    if len(candidates) != 1:
        raise AcceptanceError(
            f"expected one tagged app for {tag!r}, found {len(candidates)}; pass --app"
        )
    return candidates[0]


def app_identity(app: pathlib.Path) -> tuple[str, pathlib.Path, str, str]:
    plist_path = app / "Contents/Info.plist"
    try:
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise AcceptanceError(f"could not read app Info.plist: {error}") from error
    bundle_id = plist.get("CFBundleIdentifier")
    executable_name = plist.get("CFBundleExecutable")
    source_commit = plist.get("CMUXSourceCommit")
    source_dirty = plist.get("CMUXSourceDirty")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise AcceptanceError("tagged app has no bundle identifier")
    if not isinstance(executable_name, str) or not executable_name:
        raise AcceptanceError("tagged app has no executable name")
    if not isinstance(source_commit, str) or COMMIT_PATTERN.fullmatch(source_commit) is None:
        raise AcceptanceError("tagged app has no valid CMUXSourceCommit")
    if source_dirty not in {"YES", "NO"}:
        raise AcceptanceError("tagged app has no valid CMUXSourceDirty")
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file():
        raise AcceptanceError(f"tagged app executable is missing: {executable}")
    return bundle_id, executable, source_commit, source_dirty


def app_executables(app: pathlib.Path, swift_executable: pathlib.Path) -> list[dict[str, str]]:
    candidates = [
        ("swift-host", swift_executable),
        ("terminal-backend", app / "Contents/Resources/bin/cmux-terminal-backend"),
        ("renderer-worker", app / "Contents/Resources/bin/cmux-terminal-renderer"),
    ]
    result: list[dict[str, str]] = []
    for role, path in candidates:
        if not path.is_file() or not os.access(path, os.X_OK):
            raise AcceptanceError(f"tagged app {role} executable is missing: {path}")
        result.append(
            {
                "role": role,
                "path": str(path.relative_to(app)),
                "sha256": sha256_file(path),
            }
        )
    return result


def process_executable(pid: int) -> pathlib.Path:
    if pid <= 0:
        raise AcceptanceError("process PID must be positive")
    system = platform.system()
    if system == "Darwin":
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidpath = library.proc_pidpath
        proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        length = proc_pidpath(pid, buffer, len(buffer))
        if length <= 0:
            error = ctypes.get_errno()
            raise AcceptanceError(f"could not resolve executable for PID {pid}: errno {error}")
        return pathlib.Path(os.fsdecode(buffer.raw[:length])).resolve()
    if system == "Linux":
        try:
            return pathlib.Path(os.readlink(f"/proc/{pid}/exe")).resolve()
        except OSError as error:
            raise AcceptanceError(f"could not resolve executable for PID {pid}: {error}") from error
    raise AcceptanceError(f"process executable lookup is unsupported on {system}")


def process_started_at(pid: int) -> str:
    raw = run(["ps", "-p", str(pid), "-o", "lstart="])
    try:
        parsed = dt.datetime.strptime(" ".join(raw.split()), "%a %b %d %H:%M:%S %Y")
    except ValueError as error:
        raise AcceptanceError(f"could not parse start time for PID {pid}: {raw!r}") from error
    local_timezone = dt.datetime.now().astimezone().tzinfo
    return parsed.replace(tzinfo=local_timezone).astimezone(dt.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def backend_socket(bundle_id: str) -> str:
    identity = load_identity(bundle_id)
    return f"/tmp/cmux-tui-{os.getuid()}/{identity['socketFileName']}"


def load_identity(bundle_id: str) -> dict[str, str]:
    try:
        value = json.loads(run([sys.executable, str(IDENTITY_TOOL), "--bundle-id", bundle_id]))
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"identity tool returned invalid JSON: {error}") from error
    if not isinstance(value, dict) or not isinstance(value.get("socketFileName"), str):
        raise AcceptanceError("identity tool omitted socketFileName")
    return value


def role_value(value: str | None, environment_name: str) -> str:
    return value or os.environ.get(environment_name) or "unassigned"


def load_spec() -> dict[str, Any]:
    schema = load_json(SCHEMA_PATH)
    schema_version = schema.get("properties", {}).get("schema_version", {}).get("const")
    if schema_version != SCHEMA_VERSION:
        raise AcceptanceError("acceptance manifest schema version does not match the tool")
    spec = load_json(SPEC_PATH)
    criteria = spec.get("criteria")
    if spec.get("schema_version") != SCHEMA_VERSION or not isinstance(criteria, list):
        raise AcceptanceError("acceptance spec has an unsupported shape")
    identifiers: set[str] = set()
    for criterion in criteria:
        if not isinstance(criterion, dict) or not isinstance(criterion.get("id"), str):
            raise AcceptanceError("acceptance spec contains an invalid criterion")
        expect_keys(
            criterion,
            {"id", "priority", "observable", "pass_condition", "required_artifact_kinds"},
            f"criterion {criterion['id']}",
        )
        identifier = criterion["id"]
        if identifier in identifiers:
            raise AcceptanceError(f"duplicate acceptance criterion {identifier}")
        identifiers.add(identifier)
        if criterion["priority"] not in {"P0", "P1"}:
            raise AcceptanceError(f"criterion {identifier} has an invalid priority")
        expect_string(criterion["observable"], f"criterion {identifier} observable")
        expect_string(criterion["pass_condition"], f"criterion {identifier} pass condition")
        kinds = criterion["required_artifact_kinds"]
        if (
            not isinstance(kinds, list)
            or not kinds
            or any(not isinstance(kind, str) or not kind for kind in kinds)
            or len(set(kinds)) != len(kinds)
        ):
            raise AcceptanceError(f"criterion {identifier} has invalid required artifact kinds")
    return spec


def capture(arguments: argparse.Namespace) -> pathlib.Path:
    commit, submodules = assert_clean_source()
    root = ensure_outside_source(arguments.artifact_root)
    app = locate_tagged_app(arguments.tag, arguments.app)
    bundle_id, executable, app_commit, app_dirty = app_identity(app)
    if app_commit != commit:
        raise AcceptanceError(f"tagged app was built from {app_commit}, expected clean HEAD {commit}")
    if app_dirty != "NO":
        raise AcceptanceError("tagged app was built from a dirty source snapshot")
    executables = app_executables(app, executable)
    spec = load_spec()
    run_root = root / "terminal-backend" / commit
    manifest_path = run_root / "manifest.json"
    if manifest_path.exists() and not arguments.replace:
        raise AcceptanceError(f"manifest already exists: {manifest_path}; pass --replace")
    checks = [
        {
            "id": criterion["id"],
            "priority": criterion["priority"],
            "status": "fail",
            "commands": [],
            "assertions": ["evidence has not been captured"],
            "artifacts": [],
        }
        for criterion in spec["criteria"]
    ]
    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "criteria_sha256": sha256_file(SPEC_PATH),
        "source": {"commit": commit, "clean": True, "submodules": submodules},
        "build": {
            "tag": arguments.tag,
            "bundle_id": bundle_id,
            "app_path": str(app),
            "info_plist_sha256": sha256_file(app / "Contents/Info.plist"),
            "executables": executables,
            "debug_socket": arguments.debug_socket or f"/tmp/cmux-debug-{arguments.tag}.sock",
            "backend_socket": arguments.backend_socket or backend_socket(bundle_id),
        },
        "environment": {
            "os_build": run(["sw_vers", "-buildVersion"]),
            "hardware_model": run(["sysctl", "-n", "hw.model"]),
            "captured_at": utc_now(),
        },
        "protocol": {
            "client_range": [arguments.protocol_min, arguments.protocol_max],
            "daemon_range": [arguments.protocol_min, arguments.protocol_max],
            "negotiated": arguments.protocol_max,
            "capabilities": [],
        },
        "roles": {
            "acceptance_author": role_value(
                arguments.acceptance_author, "CMUX_ACCEPTANCE_AUTHOR"
            ),
            "implementer": role_value(arguments.implementer, "CMUX_IMPLEMENTER"),
            "interaction_profiler": role_value(
                arguments.interaction_profiler, "CMUX_INTERACTION_PROFILER"
            ),
            "artifact_verifier": role_value(
                arguments.artifact_verifier, "CMUX_ARTIFACT_VERIFIER"
            ),
        },
        "processes": [],
        "checks": checks,
    }
    validate_shape(manifest, spec)
    atomic_write_json(manifest_path, manifest)
    return manifest_path


def check_by_id(manifest: dict[str, Any], identifier: str) -> dict[str, Any]:
    checks = manifest.get("checks")
    if not isinstance(checks, list):
        raise AcceptanceError("manifest checks must be an array")
    matches = [check for check in checks if isinstance(check, dict) and check.get("id") == identifier]
    if len(matches) != 1:
        raise AcceptanceError(f"manifest must contain exactly one {identifier} check")
    return matches[0]


def resolve_artifact(run_root: pathlib.Path, relative: str) -> pathlib.Path:
    path = (run_root / relative).resolve()
    try:
        path.relative_to(run_root.resolve())
    except ValueError as error:
        raise AcceptanceError(f"artifact escapes the evidence directory: {relative}") from error
    if not path.is_file():
        raise AcceptanceError(f"artifact is missing: {path}")
    return path


def parse_json_array(raw: str, label: str) -> list[Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"invalid {label} JSON: {error}") from error
    if not isinstance(value, list):
        raise AcceptanceError(f"{label} must be a JSON array")
    return value


def record(arguments: argparse.Namespace) -> pathlib.Path:
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit = manifest.get("source", {}).get("commit")
    before_commit, before_submodules = assert_clean_source()
    if expected_commit != before_commit:
        raise AcceptanceError(
            f"manifest belongs to {expected_commit}, current source is {before_commit}"
        )
    if manifest.get("source", {}).get("submodules") != before_submodules:
        raise AcceptanceError("submodule commits changed since capture")
    check = check_by_id(manifest, arguments.id)
    commands = [parse_json_array(raw, "command") for raw in arguments.command_json]
    for command in commands:
        if not command or any(not isinstance(item, str) for item in command):
            raise AcceptanceError("every command must be a non-empty string array")
    run_root = manifest_path.parent
    artifacts: list[dict[str, Any]] = []
    for raw in arguments.artifact_json:
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as error:
            raise AcceptanceError(f"invalid artifact JSON: {error}") from error
        if not isinstance(value, dict):
            raise AcceptanceError("artifact must be a JSON object")
        kind = value.get("kind")
        relative = value.get("path")
        pids = value.get("pids", [])
        if not isinstance(kind, str) or not kind:
            raise AcceptanceError("artifact kind must be a non-empty string")
        if not isinstance(relative, str) or not relative:
            raise AcceptanceError("artifact path must be a non-empty string")
        if not isinstance(pids, list) or any(not isinstance(pid, int) or pid <= 0 for pid in pids):
            raise AcceptanceError("artifact pids must be positive integers")
        path = resolve_artifact(run_root, relative)
        artifacts.append(
            {
                "kind": kind,
                "path": relative,
                "sha256": sha256_file(path),
                "captured_at": value.get("captured_at") or utc_now(),
                "pids": sorted(set(pids)),
            }
        )
    after_commit, after_submodules = assert_clean_source()
    if (after_commit, after_submodules) != (before_commit, before_submodules):
        raise AcceptanceError("source changed while evidence was recorded")
    check["status"] = arguments.status
    check["commands"] = commands
    check["assertions"] = arguments.assertion
    check["artifacts"] = artifacts
    atomic_write_json(manifest_path, manifest)
    return manifest_path


def bind_process(arguments: argparse.Namespace) -> pathlib.Path:
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit = manifest["source"]["commit"]
    before_commit, before_submodules = assert_clean_source()
    if expected_commit != before_commit:
        raise AcceptanceError(
            f"manifest belongs to {expected_commit}, current source is {before_commit}"
        )
    if manifest["source"]["submodules"] != before_submodules:
        raise AcceptanceError("submodule commits changed since capture")
    started_at = process_started_at(arguments.pid)
    executable = process_executable(arguments.pid)
    executable_hash = sha256_file(executable)
    packaged = {
        item["role"]: item["sha256"]
        for item in manifest["build"]["executables"]
        if isinstance(item, dict)
    }
    if arguments.build_role is not None:
        expected_hash = packaged.get(arguments.build_role)
        if expected_hash is None:
            raise AcceptanceError(f"unknown packaged executable role {arguments.build_role!r}")
        if executable_hash != expected_hash:
            raise AcceptanceError(
                f"PID {arguments.pid} executable does not match packaged {arguments.build_role}"
            )
    if process_started_at(arguments.pid) != started_at:
        raise AcceptanceError(f"PID {arguments.pid} changed identity while it was recorded")
    entry = {
        "role": arguments.role,
        "build_role": arguments.build_role,
        "pid": arguments.pid,
        "started_at": started_at,
        "executable_path": str(executable),
        "executable_sha256": executable_hash,
    }
    processes = manifest["processes"]
    identity = (arguments.pid, started_at)
    existing = [
        process
        for process in processes
        if (process.get("pid"), process.get("started_at")) == identity
    ]
    if existing:
        if len(existing) != 1 or existing[0] != entry:
            raise AcceptanceError(f"PID {arguments.pid} is already bound with different identity")
    else:
        processes.append(entry)
    after_commit, after_submodules = assert_clean_source()
    if (after_commit, after_submodules) != (before_commit, before_submodules):
        raise AcceptanceError("source changed while process identity was recorded")
    atomic_write_json(manifest_path, manifest)
    return manifest_path


def expect_type(value: Any, expected: type, label: str) -> None:
    if not isinstance(value, expected):
        raise AcceptanceError(f"{label} must be {expected.__name__}")


def validate_shape(manifest: dict[str, Any], spec: dict[str, Any]) -> None:
    required_top = {
        "schema_version",
        "criteria_sha256",
        "source",
        "build",
        "environment",
        "protocol",
        "roles",
        "processes",
        "checks",
    }
    expect_keys(manifest, required_top, "manifest top-level")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise AcceptanceError("unsupported manifest schema version")
    if manifest["criteria_sha256"] != sha256_file(SPEC_PATH):
        raise AcceptanceError("acceptance criteria changed after capture")
    for name in ("source", "build", "environment", "protocol", "roles"):
        expect_type(manifest[name], dict, name)
    expect_type(manifest["processes"], list, "processes")
    expect_type(manifest["checks"], list, "checks")

    source = manifest["source"]
    expect_keys(source, {"commit", "clean", "submodules"}, "source")
    expect_commit(source["commit"], "source commit")
    if source["clean"] is not True:
        raise AcceptanceError("source clean must be true")
    expect_type(source["submodules"], dict, "source submodules")
    for path, commit in source["submodules"].items():
        expect_string(path, "submodule path")
        expect_commit(commit, f"submodule {path} commit")

    build = manifest["build"]
    expect_keys(
        build,
        {
            "tag",
            "bundle_id",
            "app_path",
            "info_plist_sha256",
            "executables",
            "debug_socket",
            "backend_socket",
        },
        "build",
    )
    for field in ("tag", "bundle_id", "app_path", "debug_socket", "backend_socket"):
        expect_string(build[field], f"build {field}")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}", build["tag"]) is None:
        raise AcceptanceError("build tag contains unsafe characters")
    if not pathlib.Path(build["app_path"]).is_absolute():
        raise AcceptanceError("build app_path must be absolute")
    expect_sha256(build["info_plist_sha256"], "build info_plist_sha256")
    for field in ("debug_socket", "backend_socket"):
        if not pathlib.Path(build[field]).is_absolute():
            raise AcceptanceError(f"build {field} must be absolute")
    expect_type(build["executables"], list, "build executables")
    expected_build_roles = ["swift-host", "terminal-backend", "renderer-worker"]
    actual_build_roles: list[str] = []
    for index, executable in enumerate(build["executables"]):
        if not isinstance(executable, dict):
            raise AcceptanceError(f"build executable {index} must be an object")
        expect_keys(executable, {"role", "path", "sha256"}, f"build executable {index}")
        actual_build_roles.append(expect_string(executable["role"], f"build executable {index} role"))
        relative = expect_string(executable["path"], f"build executable {index} path")
        if pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
            raise AcceptanceError(f"build executable {index} path must stay inside the app")
        expect_sha256(executable["sha256"], f"build executable {index} hash")
    if actual_build_roles != expected_build_roles:
        raise AcceptanceError(
            f"build executable roles must be exactly {expected_build_roles}, got {actual_build_roles}"
        )

    environment = manifest["environment"]
    expect_keys(environment, {"os_build", "hardware_model", "captured_at"}, "environment")
    expect_string(environment["os_build"], "environment os_build")
    expect_string(environment["hardware_model"], "environment hardware_model")
    parse_timestamp(environment["captured_at"], "environment captured_at")

    protocol = manifest["protocol"]
    expect_keys(
        protocol,
        {"client_range", "daemon_range", "negotiated", "capabilities"},
        "protocol",
    )
    ranges: dict[str, tuple[int, int]] = {}
    for name in ("client_range", "daemon_range"):
        value = protocol[name]
        if (
            not isinstance(value, list)
            or len(value) != 2
            or any(not isinstance(item, int) or isinstance(item, bool) or item < 1 for item in value)
            or value[0] > value[1]
        ):
            raise AcceptanceError(f"protocol {name} must be an ascending positive integer pair")
        ranges[name] = (value[0], value[1])
    negotiated = protocol["negotiated"]
    if not isinstance(negotiated, int) or isinstance(negotiated, bool) or negotiated < 1:
        raise AcceptanceError("protocol negotiated must be a positive integer")
    if not all(lower <= negotiated <= upper for lower, upper in ranges.values()):
        raise AcceptanceError("protocol negotiated is outside one of the advertised ranges")
    capabilities = protocol["capabilities"]
    if (
        not isinstance(capabilities, list)
        or any(not isinstance(capability, str) or not capability for capability in capabilities)
        or len(set(capabilities)) != len(capabilities)
    ):
        raise AcceptanceError("protocol capabilities must be unique non-empty strings")

    roles = manifest["roles"]
    role_names = {
        "acceptance_author",
        "implementer",
        "interaction_profiler",
        "artifact_verifier",
    }
    expect_keys(roles, role_names, "roles")
    for name in role_names:
        expect_string(roles[name], f"role {name}")

    process_identities: set[tuple[int, str]] = set()
    for index, process in enumerate(manifest["processes"]):
        if not isinstance(process, dict):
            raise AcceptanceError(f"process {index} must be an object")
        expect_keys(
            process,
            {"role", "build_role", "pid", "started_at", "executable_path", "executable_sha256"},
            f"process {index}",
        )
        expect_string(process["role"], f"process {index} role")
        if process["build_role"] is not None and process["build_role"] not in expected_build_roles:
            raise AcceptanceError(f"process {index} has an unknown build role")
        pid = process["pid"]
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            raise AcceptanceError(f"process {index} PID must be a positive integer")
        started_at = expect_string(process["started_at"], f"process {index} started_at")
        parse_timestamp(started_at, f"process {index} started_at")
        executable_path = expect_string(
            process["executable_path"], f"process {index} executable_path"
        )
        if not pathlib.Path(executable_path).is_absolute():
            raise AcceptanceError(f"process {index} executable_path must be absolute")
        expect_sha256(process["executable_sha256"], f"process {index} executable hash")
        identity = (pid, started_at)
        if identity in process_identities:
            raise AcceptanceError(f"process {index} duplicates PID/start identity {identity}")
        process_identities.add(identity)

    expected_ids = [criterion["id"] for criterion in spec["criteria"]]
    actual_ids = [check.get("id") for check in manifest["checks"] if isinstance(check, dict)]
    if actual_ids != expected_ids:
        raise AcceptanceError("manifest criteria do not exactly match spec order")
    for criterion, check in zip(spec["criteria"], manifest["checks"], strict=True):
        if not isinstance(check, dict):
            raise AcceptanceError(f"check {criterion['id']} must be an object")
        expect_keys(
            check,
            {"id", "priority", "status", "commands", "assertions", "artifacts"},
            f"check {criterion['id']}",
        )
        if check["priority"] != criterion["priority"] or check["status"] not in {"pass", "fail"}:
            raise AcceptanceError(f"check {criterion['id']} has invalid priority or status")
        expect_type(check["commands"], list, f"{criterion['id']} commands")
        expect_type(check["assertions"], list, f"{criterion['id']} assertions")
        expect_type(check["artifacts"], list, f"{criterion['id']} artifacts")
        for command in check["commands"]:
            if not isinstance(command, list) or not command or any(
                not isinstance(item, str) for item in command
            ):
                raise AcceptanceError(f"check {criterion['id']} contains an invalid command")
        if any(not isinstance(assertion, str) or not assertion for assertion in check["assertions"]):
            raise AcceptanceError(f"check {criterion['id']} contains an invalid assertion")
        for artifact_index, artifact in enumerate(check["artifacts"]):
            if not isinstance(artifact, dict):
                raise AcceptanceError(
                    f"check {criterion['id']} artifact {artifact_index} must be an object"
                )
            expect_keys(
                artifact,
                {"kind", "path", "sha256", "captured_at", "pids"},
                f"check {criterion['id']} artifact {artifact_index}",
            )
            expect_string(
                artifact["kind"], f"check {criterion['id']} artifact {artifact_index} kind"
            )
            relative = expect_string(
                artifact["path"], f"check {criterion['id']} artifact {artifact_index} path"
            )
            if pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
                raise AcceptanceError(
                    f"check {criterion['id']} artifact {artifact_index} path must stay inside evidence"
                )
            expect_sha256(
                artifact["sha256"], f"check {criterion['id']} artifact {artifact_index} hash"
            )
            parse_timestamp(
                artifact["captured_at"],
                f"check {criterion['id']} artifact {artifact_index} captured_at",
            )
            pids = artifact["pids"]
            if (
                not isinstance(pids, list)
                or any(not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0 for pid in pids)
                or pids != sorted(set(pids))
            ):
                raise AcceptanceError(
                    f"check {criterion['id']} artifact {artifact_index} PIDs must be sorted unique positive integers"
                )


def verify(arguments: argparse.Namespace) -> None:
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    source = manifest["source"]
    if source.get("clean") is not True:
        raise AcceptanceError("manifest was not captured from clean source")
    if arguments.require_final_head:
        commit, submodules = assert_clean_source()
        if source.get("commit") != commit:
            raise AcceptanceError(f"manifest commit {source.get('commit')} is not HEAD {commit}")
        if source.get("submodules") != submodules:
            raise AcceptanceError("manifest submodule commits are not current")
    build = manifest["build"]
    app = pathlib.Path(build.get("app_path", ""))
    bundle_id, _, app_commit, app_dirty = app_identity(app)
    if bundle_id != build.get("bundle_id"):
        raise AcceptanceError("tagged app bundle identifier changed after capture")
    if app_commit != source["commit"] or app_dirty != "NO":
        raise AcceptanceError("tagged app source identity no longer matches clean manifest source")
    if sha256_file(app / "Contents/Info.plist") != build["info_plist_sha256"]:
        raise AcceptanceError("tagged app Info.plist changed after capture")
    packaged_hashes: dict[str, str] = {}
    for item in build["executables"]:
        path = (app / item["path"]).resolve()
        try:
            path.relative_to(app.resolve())
        except ValueError as error:
            raise AcceptanceError(f"packaged executable escapes app: {item['path']}") from error
        if not path.is_file() or sha256_file(path) != item["sha256"]:
            raise AcceptanceError(f"packaged {item['role']} executable changed after capture")
        packaged_hashes[item["role"]] = item["sha256"]
    roles = manifest["roles"]
    role_values = [
        roles.get("acceptance_author"),
        roles.get("implementer"),
        roles.get("interaction_profiler"),
        roles.get("artifact_verifier"),
    ]
    if any(not isinstance(value, str) or not value or value == "unassigned" for value in role_values):
        raise AcceptanceError("all acceptance roles must be assigned")
    if len(set(role_values)) != len(role_values):
        raise AcceptanceError("all acceptance roles must differ")
    known_pids: set[int] = set()
    bound_build_roles: set[str] = set()
    for process in manifest["processes"]:
        known_pids.add(process["pid"])
        build_role = process["build_role"]
        if build_role is not None:
            if process["executable_sha256"] != packaged_hashes[build_role]:
                raise AcceptanceError(
                    f"recorded PID {process['pid']} does not match packaged {build_role} hash"
                )
            bound_build_roles.add(build_role)
    if arguments.require_all_p0:
        missing_roles = set(packaged_hashes) - bound_build_roles
        if missing_roles:
            raise AcceptanceError(
                f"P0 verification lacks process identities for: {sorted(missing_roles)}"
            )
    run_root = manifest_path.parent
    criteria_by_id = {criterion["id"]: criterion for criterion in spec["criteria"]}
    failed: list[str] = []
    for check in manifest["checks"]:
        identifier = check["id"]
        criterion = criteria_by_id[identifier]
        artifact_kinds: set[str] = set()
        for artifact in check["artifacts"]:
            if not isinstance(artifact, dict):
                raise AcceptanceError(f"check {identifier} has a non-object artifact")
            path = resolve_artifact(run_root, artifact.get("path", ""))
            if sha256_file(path) != artifact.get("sha256"):
                raise AcceptanceError(f"artifact hash changed: {artifact.get('path')}")
            unknown_pids = set(artifact["pids"]) - known_pids
            if unknown_pids:
                raise AcceptanceError(
                    f"artifact {artifact['path']} cites unbound PIDs: {sorted(unknown_pids)}"
                )
            artifact_kinds.add(artifact.get("kind"))
        if check["status"] == "pass":
            missing = set(criterion["required_artifact_kinds"]) - artifact_kinds
            if missing:
                raise AcceptanceError(
                    f"passing check {identifier} lacks required artifact kinds: {sorted(missing)}"
                )
            if not check["commands"] or not check["assertions"]:
                raise AcceptanceError(f"passing check {identifier} needs commands and assertions")
        elif criterion["priority"] == "P0":
            failed.append(identifier)
    if arguments.require_all_p0 and failed:
        raise AcceptanceError(f"P0 acceptance checks failed: {', '.join(failed)}")


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    subparsers = argument_parser.add_subparsers(dest="operation", required=True)

    capture_parser = subparsers.add_parser("capture", help="initialize commit-bound evidence")
    capture_parser.add_argument("--tag", required=True)
    capture_parser.add_argument("--artifact-root", type=pathlib.Path, required=True)
    capture_parser.add_argument("--app", type=pathlib.Path)
    capture_parser.add_argument("--debug-socket")
    capture_parser.add_argument("--backend-socket")
    capture_parser.add_argument("--protocol-min", type=int, default=8)
    capture_parser.add_argument("--protocol-max", type=int, default=8)
    capture_parser.add_argument("--acceptance-author")
    capture_parser.add_argument("--implementer")
    capture_parser.add_argument("--interaction-profiler")
    capture_parser.add_argument("--artifact-verifier")
    capture_parser.add_argument("--replace", action="store_true")

    record_parser = subparsers.add_parser("record", help="record one check's evidence")
    record_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    record_parser.add_argument("--id", required=True)
    record_parser.add_argument("--status", choices=("pass", "fail"), required=True)
    record_parser.add_argument("--command-json", action="append", default=[])
    record_parser.add_argument("--assertion", action="append", default=[])
    record_parser.add_argument("--artifact-json", action="append", default=[])

    process_parser = subparsers.add_parser(
        "bind-process", help="bind a live process identity to packaged binaries"
    )
    process_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    process_parser.add_argument("--role", required=True)
    process_parser.add_argument(
        "--build-role", choices=("swift-host", "terminal-backend", "renderer-worker")
    )
    process_parser.add_argument("--pid", type=int, required=True)

    verify_parser = subparsers.add_parser("verify", help="verify evidence and source binding")
    verify_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    verify_parser.add_argument("--require-final-head", action="store_true")
    verify_parser.add_argument("--require-all-p0", action="store_true")
    return argument_parser


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.operation == "capture":
            path = capture(arguments)
            print(path)
        elif arguments.operation == "record":
            path = record(arguments)
            print(path)
        elif arguments.operation == "bind-process":
            path = bind_process(arguments)
            print(path)
        else:
            verify(arguments)
            print("terminal backend acceptance manifest verified")
    except AcceptanceError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
