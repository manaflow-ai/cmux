#!/usr/bin/env python3
"""Repository-owned CMUX workload profile registry and semantic runner."""
from __future__ import annotations

import argparse
import fcntl
import glob
import hashlib
import json
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
REGISTRY_PATH = ROOT / "scripts/ci/cmux-workload-profiles.json"
RESULT_DOCUMENT_TYPE = "cmux-workload-result"
RESULT_SCHEMA_VERSION = 1
MAX_RESULT_BYTES = 64 * 1024
OID_RE = re.compile(r"^[0-9a-f]{40}$")
PROFILE_RE = re.compile(r"^cmux\.[a-z0-9][a-z0-9.-]{1,80}$")
PARAM_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
STAGE_RE = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
RESULTS = {"passed", "failed", "timed_out", "ambiguous"}
STATE_CLASSES = {
    "cold",
    "dependency-warm",
    "compiler-warm",
    "exact-product-reuse",
    "resident-hot",
}
ENVIRONMENT_CLASSES = {
    "isolated-portable",
    "isolated-build",
    "isolated-console-test",
}


class ProfileError(RuntimeError):
    pass


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def sha256_tree(root: Path) -> tuple[str, int]:
    """Hash a self-contained product tree by path, type, mode, bytes, and link target."""
    if not root.is_dir() or root.is_symlink():
        raise ProfileError("runtime input product root must be a real directory")
    root_resolved = root.resolve(strict=True)
    digest = hashlib.sha256()
    total_bytes = 0
    entries = [root, *root.rglob("*")]
    for path in sorted(entries, key=lambda item: item.relative_to(root).as_posix()):
        rel = path.relative_to(root).as_posix().encode("utf-8")
        metadata = path.lstat()
        is_link = path.is_symlink()
        mode = 0 if is_link else stat.S_IMODE(metadata.st_mode)
        if is_link:
            try:
                path.resolve(strict=True).relative_to(root_resolved)
            except (FileNotFoundError, RuntimeError, ValueError) as error:
                raise ProfileError(
                    f"runtime product symlink escapes or dangles: {path}"
                ) from error
            kind = b"L"
            payload = os.readlink(path).encode("utf-8")
            digest.update(kind + b"\0" + rel + b"\0" + f"{mode:o}".encode() + b"\0" + payload + b"\n")
        elif path.is_dir():
            digest.update(b"D\0" + rel + b"\0" + f"{mode:o}".encode() + b"\n")
        elif path.is_file():
            digest.update(b"F\0" + rel + b"\0" + f"{mode:o}".encode() + b"\0")
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    total_bytes += len(chunk)
                    digest.update(chunk)
            digest.update(b"\n")
        else:
            raise ProfileError(f"unsupported runtime product entry: {path}")
    return "sha256:" + digest.hexdigest(), total_bytes


def exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ProfileError(f"{label} has unknown or missing fields")


def load_registry() -> dict[str, Any]:
    try:
        value = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ProfileError("workload profile registry is unavailable or invalid") from error
    validate_registry(value)
    return value


def validate_registry(registry: dict[str, Any]) -> None:
    exact_keys(
        registry,
        {"schema_version", "repository", "result_contract", "profiles"},
        "registry",
    )
    if (
        registry["schema_version"] != 1
        or registry["repository"] != "manaflow-ai/cmux"
        or registry["result_contract"] != "cmux-workload-result/v1"
    ):
        raise ProfileError("workload profile registry identity is invalid")
    profiles = registry["profiles"]
    if not isinstance(profiles, list) or not profiles:
        raise ProfileError("registry must contain profiles")
    seen: set[str] = set()
    for profile in profiles:
        if not isinstance(profile, dict):
            raise ProfileError("profile must be an object")
        exact_keys(
            profile,
            {
                "id",
                "generation",
                "entrypoint",
                "semantic_scope",
                "platform",
                "expected_result_class",
                "semantic_validator",
                "timeout",
                "resource_class",
                "network_class",
                "environment_class",
                "benchmark_state_classes",
                "parameters",
                "runtime_inputs",
                "artifacts",
            },
            "profile",
        )
        profile_id = profile["id"]
        if (
            not isinstance(profile_id, str)
            or PROFILE_RE.fullmatch(profile_id) is None
            or profile_id in seen
        ):
            raise ProfileError("profile id is invalid or duplicated")
        seen.add(profile_id)
        if type(profile["generation"]) is not int or profile["generation"] < 1:
            raise ProfileError(f"{profile_id}: generation must be a positive integer")
        entrypoint = profile["entrypoint"]
        if (
            not isinstance(entrypoint, str)
            or entrypoint.startswith("/")
            or ".." in Path(entrypoint).parts
            or not entrypoint.startswith("scripts/")
            or not (ROOT / entrypoint).is_file()
        ):
            raise ProfileError(f"{profile_id}: entrypoint is invalid")
        platform_spec = profile["platform"]
        if not isinstance(platform_spec, dict):
            raise ProfileError(f"{profile_id}: platform must be an object")
        exact_keys(
            platform_spec,
            {"os", "architectures", "requirements"},
            f"{profile_id}: platform",
        )
        if platform_spec["os"] not in {"linux", "macos"}:
            raise ProfileError(f"{profile_id}: unsupported platform os")
        if (
            not isinstance(platform_spec["architectures"], list)
            or not platform_spec["architectures"]
            or not all(isinstance(v, str) and v for v in platform_spec["architectures"])
        ):
            raise ProfileError(f"{profile_id}: architectures are invalid")
        timeout = profile["timeout"]
        if not isinstance(timeout, dict):
            raise ProfileError(f"{profile_id}: timeout must be an object")
        exact_keys(timeout, {"class", "seconds"}, f"{profile_id}: timeout")
        if (
            not isinstance(timeout["class"], str)
            or type(timeout["seconds"]) is not int
            or timeout["seconds"] <= 0
        ):
            raise ProfileError(f"{profile_id}: timeout is invalid")
        if profile["environment_class"] not in ENVIRONMENT_CLASSES:
            raise ProfileError(f"{profile_id}: environment class is invalid")
        states = profile["benchmark_state_classes"]
        if (
            not isinstance(states, list)
            or not states
            or len(set(states)) != len(states)
            or any(state not in STATE_CLASSES for state in states)
        ):
            raise ProfileError(f"{profile_id}: benchmark state classes are invalid")
        parameters = profile["parameters"]
        if not isinstance(parameters, dict):
            raise ProfileError(f"{profile_id}: parameters must be an object")
        for name, spec in parameters.items():
            if PARAM_RE.fullmatch(name) is None or not isinstance(spec, dict):
                raise ProfileError(f"{profile_id}: parameter is invalid")
            exact_keys(
                spec,
                {"type", "minimum", "maximum", "required"},
                f"{profile_id}: parameter {name}",
            )
            if (
                spec["type"] != "integer"
                or type(spec["minimum"]) is not int
                or type(spec["maximum"]) is not int
                or spec["minimum"] > spec["maximum"]
                or type(spec["required"]) is not bool
            ):
                raise ProfileError(f"{profile_id}: parameter {name} is invalid")
        if not isinstance(profile["runtime_inputs"], list):
            raise ProfileError(f"{profile_id}: runtime inputs are invalid")
        for item in profile["runtime_inputs"]:
            exact_keys(
                item,
                {"name", "env", "class", "identity", "required"},
                f"{profile_id}: runtime input",
            )
            if (
                not isinstance(item["name"], str)
                or not isinstance(item["env"], str)
                or not item["env"].startswith("CMUX_")
                or not isinstance(item["class"], str)
                or item["identity"] not in {"file-sha256", "parent-tree-sha256"}
                or type(item["required"]) is not bool
            ):
                raise ProfileError(f"{profile_id}: runtime input is invalid")
        if not isinstance(profile["artifacts"], list):
            raise ProfileError(f"{profile_id}: artifacts are invalid")
        for item in profile["artifacts"]:
            exact_keys(item, {"class", "glob", "required"}, f"{profile_id}: artifact")
            if (
                not isinstance(item["class"], str)
                or not isinstance(item["glob"], str)
                or type(item["required"]) is not bool
            ):
                raise ProfileError(f"{profile_id}: artifact is invalid")
        for name in (
            "semantic_scope",
            "expected_result_class",
            "semantic_validator",
            "resource_class",
            "network_class",
        ):
            if not isinstance(profile[name], str) or not profile[name]:
                raise ProfileError(f"{profile_id}: {name} is invalid")


def profile_by_id(registry: dict[str, Any], profile_id: str) -> dict[str, Any]:
    for profile in registry["profiles"]:
        if profile["id"] == profile_id:
            return profile
    raise ProfileError(f"unknown profile: {profile_id}")


def git_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GIT_")
    }
    environment["LC_ALL"] = "C"
    return environment


def git_text(*arguments: str) -> str:
    completed = subprocess.run(
        ["/usr/bin/git", *arguments],
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
        env=git_environment(),
    )
    if completed.returncode != 0:
        raise ProfileError(f"git {' '.join(arguments)} failed")
    return completed.stdout.strip()


def source_identity(expected_commit: str | None, expected_tree: str | None) -> dict[str, str]:
    commit = git_text("rev-parse", "HEAD^{commit}")
    tree = git_text("rev-parse", "HEAD^{tree}")
    if OID_RE.fullmatch(commit) is None or OID_RE.fullmatch(tree) is None:
        raise ProfileError("checkout source identity is invalid")
    if expected_commit is not None and commit != expected_commit:
        raise ProfileError("checkout commit differs from frozen request")
    if expected_tree is not None and tree != expected_tree:
        raise ProfileError("checkout tree differs from frozen request")
    tracked_dirty = subprocess.run(
        ["/usr/bin/git", "diff", "--quiet", "HEAD", "--"],
        cwd=ROOT,
        check=False,
        env=git_environment(),
    ).returncode
    index_dirty = subprocess.run(
        ["/usr/bin/git", "diff", "--cached", "--quiet", "HEAD", "--"],
        cwd=ROOT,
        check=False,
        env=git_environment(),
    ).returncode
    if tracked_dirty != 0 or index_dirty != 0:
        raise ProfileError("checkout has tracked source changes")
    untracked = git_text(
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--ignore-submodules=dirty",
    )
    if untracked:
        raise ProfileError("checkout has non-ignored source changes")
    submodules = git_text("submodule", "status", "--recursive")
    for line in submodules.splitlines():
        if not line:
            continue
        marker = line[0]
        # '-' is an unmaterialized gitlink and cannot contribute worktree bytes.
        # '+' and 'U' mean the checked-out gitlink identity already differs from
        # the frozen superproject tree.
        if marker in {"+", "U"}:
            raise ProfileError(
                "checkout submodule identity differs from the frozen source"
            )
        if marker == "-":
            continue
        if len(line) < 43 or line[41] != " ":
            raise ProfileError("checkout submodule status is malformed")
        submodule_path = line[42:].split(" (", 1)[0]
        if not submodule_path or Path(submodule_path).is_absolute() or ".." in Path(submodule_path).parts:
            raise ProfileError("checkout submodule path is invalid")
        dirty_submodule = git_text(
            "-C",
            submodule_path,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        )
        if dirty_submodule:
            raise ProfileError("checkout submodule worktree differs from the frozen source")
    return {"repository": "manaflow-ai/cmux", "commit": commit, "tree": tree}


class CheckoutMutationLease:
    def __init__(self, profile: dict[str, Any]):
        self.fd: int | None = None
        if profile["environment_class"] != "isolated-build":
            return
        raw = git_text("rev-parse", "--git-common-dir")
        common = Path(raw)
        if not common.is_absolute():
            common = ROOT / common
        common = common.resolve(strict=True)
        if not common.is_dir():
            raise ProfileError("checkout metadata directory is unavailable")
        lock_path = common / "cmux-workload-isolated-build.lock"
        try:
            descriptor = os.open(
                lock_path,
                os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
            )
        except OSError as error:
            raise ProfileError("checkout mutation lease is unavailable") from error
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size != 0
            ):
                raise ProfileError("checkout mutation lease file is unsafe")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ProfileError("checkout mutation lease is busy") from error
            self.fd = descriptor
        except Exception:
            os.close(descriptor)
            raise

    def __enter__(self) -> "CheckoutMutationLease":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        del exc_type, exc, traceback
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            self.fd = None


def normalized_os() -> str:
    name = platform.system().lower()
    return "macos" if name == "darwin" else name


def normalized_arch() -> str:
    value = platform.machine().lower()
    if value == "aarch64":
        return "arm64"
    if value in {"amd64", "x64"}:
        return "x86_64"
    return value


def validate_platform(profile: dict[str, Any]) -> None:
    required = profile["platform"]
    actual_os = normalized_os()
    actual_arch = normalized_arch()
    if actual_os != required["os"]:
        raise ProfileError(
            f"{profile['id']} requires {required['os']}; current platform is {actual_os}"
        )
    if actual_arch not in required["architectures"]:
        raise ProfileError(f"{profile['id']} does not admit architecture {actual_arch}")


def parse_parameters(profile: dict[str, Any], values: list[str]) -> dict[str, int]:
    raw: dict[str, str] = {}
    for value in values:
        if "=" not in value:
            raise ProfileError("profile parameters use name=value")
        name, data = value.split("=", 1)
        if name in raw:
            raise ProfileError(f"duplicate profile parameter: {name}")
        raw[name] = data
    expected = profile["parameters"]
    unknown = set(raw) - set(expected)
    if unknown:
        raise ProfileError(f"unknown profile parameter: {sorted(unknown)[0]}")
    parsed: dict[str, int] = {}
    for name, spec in expected.items():
        if name not in raw:
            if spec["required"]:
                raise ProfileError(f"missing required profile parameter: {name}")
            continue
        try:
            number = int(raw[name], 10)
        except ValueError as error:
            raise ProfileError(f"profile parameter {name} must be an integer") from error
        if not spec["minimum"] <= number <= spec["maximum"]:
            raise ProfileError(
                f"profile parameter {name} must be between "
                f"{spec['minimum']} and {spec['maximum']}"
            )
        parsed[name] = number
    return parsed


def prepare_state_root(
    raw: str | None, state_class: str
) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    temporary: tempfile.TemporaryDirectory[str] | None = None
    if raw is None:
        if state_class != "cold":
            raise ProfileError("warm benchmark state requires --state-root")
        temporary = tempfile.TemporaryDirectory(prefix="cmux-workload-")
        path = Path(temporary.name)
    else:
        path = Path(raw)
        if not path.is_absolute():
            raise ProfileError("state root must be absolute")
        path.mkdir(parents=True, exist_ok=True)
        resolved = path.resolve(strict=True)
        info = path.stat(follow_symlinks=False)
        if (
            resolved != path
            or not path.is_dir()
            or path.is_symlink()
            or info.st_uid != os.geteuid()
        ):
            raise ProfileError("state root must be one canonical current-user directory")
        path.chmod(0o700)
        if state_class == "cold" and any(path.iterdir()):
            raise ProfileError("cold benchmark state root must start empty")
    return path, temporary


def stage_event(action: str, stage: str) -> None:
    if action not in {"start", "end"} or STAGE_RE.fullmatch(stage) is None:
        raise ProfileError("invalid stage event")
    path_raw = os.environ.get("CMUX_WORKLOAD_STAGE_LOG")
    token = os.environ.get("CMUX_WORKLOAD_STAGE_TOKEN")
    if not path_raw or not token:
        raise ProfileError("stage events require an active workload runner")
    event = {
        "action": action,
        "stage": stage,
        "time_unix_millis": time.time_ns() // 1_000_000,
        "token": token,
    }
    with Path(path_raw).open("a", encoding="utf-8") as output:
        output.write(canonical_bytes(event).decode("utf-8") + "\n")


def read_stage_timings(path: Path, token: str, fallback: float) -> list[dict[str, Any]]:
    pairs: dict[str, list[int]] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if (
                not isinstance(event, dict)
                or event.get("token") != token
                or event.get("action") not in {"start", "end"}
                or not isinstance(event.get("stage"), str)
                or STAGE_RE.fullmatch(event["stage"]) is None
                or type(event.get("time_unix_millis")) is not int
            ):
                continue
            slot = pairs.setdefault(event["stage"], [])
            if event["action"] == "start" and not slot:
                slot.append(event["time_unix_millis"])
            elif event["action"] == "end" and len(slot) == 1:
                slot.append(event["time_unix_millis"])
    timings: list[dict[str, Any]] = []
    for stage, values in sorted(pairs.items()):
        if len(values) == 2 and values[1] >= values[0]:
            timings.append(
                {"stage": stage, "seconds": round((values[1] - values[0]) / 1000.0, 3)}
            )
    return timings or [{"stage": "execute", "seconds": round(fallback, 3)}]


def memory_bytes() -> int | None:
    if normalized_os() == "macos":
        completed = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "hw.memsize"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout.strip().isdigit():
            return int(completed.stdout.strip())
        return None
    if normalized_os() == "linux":
        try:
            return int(os.sysconf("SC_PHYS_PAGES")) * int(os.sysconf("SC_PAGE_SIZE"))
        except (ValueError, OSError):
            return None
    return None


def _toolchain_environment(state_root: Path) -> dict[str, str]:
    home = state_root / "home"
    environment = {
        "HOME": str(home),
        "TMPDIR": str(state_root / "tmp"),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "CARGO_HOME": str(home / ".cargo"),
        "RUSTUP_HOME": str(home / ".rustup"),
        "PATH": (
            f"{home / '.cargo' / 'bin'}:"
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ),
        "LC_ALL": "C",
        "LANG": "C",
    }
    for candidate in (state_root / "xcode.env", state_root / "profile.env"):
        if not candidate.is_file() or candidate.is_symlink():
            continue
        for line in candidate.read_text(encoding="utf-8").splitlines():
            if line.startswith("DEVELOPER_DIR="):
                value = line.removeprefix("DEVELOPER_DIR=")
                path = Path(value)
                if path.is_absolute() and path.is_dir():
                    environment["DEVELOPER_DIR"] = value
    return environment


def command_text(argv: list[str], environment: dict[str, str]) -> str | None:
    completed = subprocess.run(
        argv,
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
        env=environment,
    )
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value[:4096] if value else None


def toolchain_summary(profile: dict[str, Any], state_root: Path) -> dict[str, Any]:
    observations: dict[str, str] = {"python": platform.python_version()}
    environment = _toolchain_environment(state_root)
    git = command_text(["/usr/bin/git", "--version"], environment)
    if git:
        observations["git"] = git
    if profile["platform"]["os"] == "macos":
        for key, argv in (
            ("xcode", ["/usr/bin/xcodebuild", "-version"]),
            ("macos_sdk", ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]),
            ("swift", ["/usr/bin/xcrun", "swiftc", "--version"]),
            ("cargo", ["cargo", "--version"]),
            ("rustc", ["rustc", "--version"]),
        ):
            value = command_text(argv, environment)
            if value:
                observations[key] = value
    else:
        value = command_text(["/bin/bash", "--version"], environment)
        if value:
            observations["bash"] = value.splitlines()[0]
    return {
        "identity": sha256_bytes(canonical_bytes(observations)),
        "observations": observations,
    }


def runtime_inputs(profile: dict[str, Any]) -> list[dict[str, Any]]:
    identities: list[dict[str, Any]] = []
    for spec in profile["runtime_inputs"]:
        raw = os.environ.get(spec["env"])
        if not raw:
            if spec["required"]:
                raise ProfileError(f"required runtime input is missing: {spec['name']}")
            continue
        path = Path(raw)
        if not path.is_absolute():
            raise ProfileError(f"runtime input {spec['name']} must be an absolute path")
        resolved = path.resolve(strict=True)
        if resolved != path or not path.is_file() or path.is_symlink():
            raise ProfileError(
                f"runtime input {spec['name']} must be a canonical regular file"
            )
        if spec["identity"] == "file-sha256":
            identity, byte_count = sha256_file(path), path.stat().st_size
        else:
            identity, byte_count = sha256_tree(path.parent)
        identities.append(
            {
                "name": spec["name"],
                "class": spec["class"],
                "identity": spec["identity"],
                "sha256": identity,
                "bytes": byte_count,
            }
        )
    return identities


def collect_artifacts(
    profile: dict[str, Any], state_root: Path
) -> tuple[list[dict[str, Any]], list[str]]:
    artifacts: list[dict[str, Any]] = []
    missing: list[str] = []
    for spec in profile["artifacts"]:
        pattern = spec["glob"].replace("{state_root}", str(state_root)).replace(
            "{repo_root}", str(ROOT)
        )
        matches = [
            Path(value)
            for value in sorted(glob.glob(pattern, recursive=True))
            if Path(value).is_file() and not Path(value).is_symlink()
        ]
        if spec["required"] and not matches:
            missing.append(spec["class"])
        for path in matches:
            artifacts.append(
                {
                    "class": spec["class"],
                    "path_class": "repository_output",
                    "sha256": sha256_file(path),
                    "bytes": path.stat().st_size,
                }
            )
    return artifacts, missing


def semantic_key(
    source: dict[str, str],
    profile: dict[str, Any],
    parameters: dict[str, int],
    inputs: list[dict[str, Any]],
) -> str:
    value = {
        "source": {"repository": source["repository"], "tree": source["tree"]},
        "profile": {"id": profile["id"], "generation": profile["generation"]},
        "semantic_validator": profile["semantic_validator"],
        "environment_class": profile["environment_class"],
        "parameters": parameters,
        "runtime_inputs": [
            {
                "name": item["name"],
                "class": item["class"],
                "identity": item["identity"],
                "sha256": item["sha256"],
            }
            for item in inputs
        ],
    }
    return sha256_bytes(canonical_bytes(value))


def context_key(semantic: str, state_class: str, toolchain: str) -> str:
    return sha256_bytes(
        canonical_bytes(
            {
                "semantic_key": semantic,
                "state_class": state_class,
                "toolchain_identity": toolchain,
            }
        )
    )


def wait_child_unreaped(pid: int, timeout: float | None) -> int:
    """Wait for one direct child to exit without releasing its PID/PGID identity."""
    options = os.WEXITED | os.WNOWAIT
    previous_handler = None
    if timeout is not None:
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        if previous_timer[0] > 0 or previous_timer[1] > 0:
            raise ProfileError("workload runner cannot replace an active real-time timer")

        def timeout_handler(_signum: int, _frame: object) -> None:
            raise subprocess.TimeoutExpired("workload", timeout)

        previous_handler = signal.getsignal(signal.SIGALRM)
        signal.signal(signal.SIGALRM, timeout_handler)
        signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        status = os.waitid(os.P_PID, pid, options)
    finally:
        if timeout is not None:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
    if status is None:
        raise ProfileError("workload child exit status is unavailable")
    if status.si_code == os.CLD_EXITED:
        return status.si_status
    if status.si_code in {os.CLD_KILLED, os.CLD_DUMPED}:
        return -status.si_status
    raise ProfileError("workload child exit status is invalid")


def process_group_alive(pid: int, *, ignore_pid: int | None = None) -> bool:
    # Keep the exited group leader waitable while checking for descendants.
    # /bin/ps is available on both supported runner platforms and lets us ignore
    # that known zombie leader without releasing its PID/PGID for reuse.
    completed = subprocess.run(
        ["/bin/ps", "-axo", "pid=,pgid="],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        text=True,
        env={"LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"},
    )
    if completed.returncode != 0:
        return True
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            member_pid, group_id = (int(value) for value in fields)
        except ValueError:
            continue
        if group_id == pid and member_pid != ignore_pid:
            return True
    return False


def settle_process_group(
    pid: int, *, ignore_pid: int | None = None
) -> tuple[bool, str]:
    if not process_group_alive(pid, ignore_pid=ignore_pid):
        return True, "complete"
    # Any member other than the known exited leader is leaked descendant state.
    # Do not synchronize on wall-clock polling: force that residual group down
    # once and mark the semantic result ambiguous.
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        return True, "complete"
    return False, "forced"


def publish_result(result: dict[str, Any], path_raw: str | None) -> None:
    if result["result"] not in RESULTS:
        raise ProfileError("invalid semantic result")
    raw = canonical_bytes(result) + b"\n"
    if len(raw) > MAX_RESULT_BYTES:
        raise ProfileError("semantic result exceeds its fixed ceiling")
    if path_raw is None or path_raw == "-":
        sys.stdout.buffer.write(raw)
        return

    path = Path(path_raw)
    if not path.is_absolute():
        raise ProfileError("semantic result path must be absolute")
    parent = path.parent.resolve(strict=True)
    parent_fd = os.open(
        parent,
        os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    temporary = None
    descriptor = None
    try:
        held_parent = os.fstat(parent_fd)
        current_parent = os.stat(parent, follow_symlinks=False)
        user_owned = held_parent.st_uid == os.geteuid()
        trusted_sticky_tmp = (
            held_parent.st_uid == 0
            and bool(held_parent.st_mode & stat.S_ISVTX)
            and bool(held_parent.st_mode & stat.S_IWOTH)
        )
        if (
            not stat.S_ISDIR(held_parent.st_mode)
            or not (user_owned or trusted_sticky_tmp)
            or (held_parent.st_dev, held_parent.st_ino)
            != (current_parent.st_dev, current_parent.st_ino)
        ):
            raise ProfileError("semantic result parent identity is unsafe")
        for attempt in range(32):
            candidate = f".{path.name}.tmp-{os.getpid()}-{attempt}"
            try:
                descriptor = os.open(
                    candidate,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_CLOEXEC
                    | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=parent_fd,
                )
                temporary = candidate
                break
            except FileExistsError:
                continue
        if descriptor is None or temporary is None:
            raise ProfileError("semantic result staging namespace is exhausted")
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = None
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        current_parent = os.stat(parent, follow_symlinks=False)
        if (held_parent.st_dev, held_parent.st_ino) != (
            current_parent.st_dev,
            current_parent.st_ino,
        ):
            raise ProfileError("semantic result parent identity changed")
        os.replace(
            temporary,
            path.name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        temporary = None
        os.fsync(parent_fd)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        os.close(parent_fd)



def workload_environment(
    profile: dict[str, Any],
    state_root: Path,
    source: dict[str, str],
    parameters: dict[str, int],
    token: str,
) -> dict[str, str]:
    home = state_root / "home"
    temporary = state_root / "tmp"
    config = home / ".config"
    cargo_home = home / ".cargo"
    rustup_home = home / ".rustup"
    for path in (home, temporary, config, cargo_home, rustup_home):
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)

    environment = {
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "XDG_CONFIG_HOME": str(config),
        "CARGO_HOME": str(cargo_home),
        "RUSTUP_HOME": str(rustup_home),
        "PATH": (
            f"{cargo_home}/bin:"
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ),
        "LC_ALL": "C",
        "LANG": "C",
        "CI": "1",
        "GITHUB_ACTIONS": "1",
        "GITHUB_WORKSPACE": str(ROOT),
        "RUNNER_TEMP": str(state_root),
        "CMUX_CI_SKIP_XCODE_SELECT": "1",
        "CMUX_WORKLOAD_PROFILE_ID": profile["id"],
        "CMUX_WORKLOAD_PROFILE_GENERATION": str(profile["generation"]),
        "CMUX_WORKLOAD_ENVIRONMENT_CLASS": profile["environment_class"],
        "CMUX_WORKLOAD_STATE_ROOT": str(state_root),
        "CMUX_WORKLOAD_STAGE_LOG": str(state_root / ".cmux-workload-stages.jsonl"),
        "CMUX_WORKLOAD_STAGE_TOKEN": token,
        "CMUX_WORKLOAD_ATTEMPT_ID": str(max(1, int(token[:15], 16))),
        "CMUX_WORKLOAD_SOURCE_COMMIT": source["commit"],
        "CMUX_WORKLOAD_SOURCE_TREE": source["tree"],
    }
    for name, value in parameters.items():
        environment[f"CMUX_WORKLOAD_PARAM_{name.upper()}"] = str(value)
    for spec in profile["runtime_inputs"]:
        raw = os.environ.get(spec["env"])
        if raw:
            environment[spec["env"]] = raw
    return environment


def run_profile(args: argparse.Namespace) -> int:
    registry = load_registry()
    profile = profile_by_id(registry, args.profile)
    if args.generation is not None and args.generation != profile["generation"]:
        raise ProfileError(
            f"profile generation mismatch: requested {args.generation}, "
            f"current {profile['generation']}"
        )
    validate_platform(profile)
    source = source_identity(args.commit, args.tree)
    parameters = parse_parameters(profile, args.param)
    if args.state_class not in profile["benchmark_state_classes"]:
        raise ProfileError(
            f"{profile['id']} does not admit benchmark state {args.state_class}"
        )
    state_root, temporary = prepare_state_root(args.state_root, args.state_class)
    stage_log = state_root / ".cmux-workload-stages.jsonl"
    try:
        stage_log.unlink()
    except FileNotFoundError:
        pass
    token = hashlib.sha256(os.urandom(32)).hexdigest()
    inputs = runtime_inputs(profile)
    environment = workload_environment(
        profile,
        state_root,
        source,
        parameters,
        token,
    )
    environment["CMUX_WORKLOAD_STATE_CLASS"] = args.state_class

    started_ms = time.time_ns() // 1_000_000
    started_monotonic = time.monotonic()
    timed_out = False
    with CheckoutMutationLease(profile):
        child = subprocess.Popen(
            ["/bin/bash", str(ROOT / profile["entrypoint"])],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            env=environment,
            start_new_session=True,
        )
        try:
            exit_code = wait_child_unreaped(
                child.pid, profile["timeout"]["seconds"]
            )
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                exit_code = wait_child_unreaped(child.pid, 5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                wait_child_unreaped(child.pid, None)
                exit_code = 124
        elapsed = time.monotonic() - started_monotonic
        try:
            settled_cleanly, cleanup_state = settle_process_group(
                child.pid, ignore_pid=child.pid
            )
        finally:
            reaped_exit_code = child.wait()
        if exit_code != 124 and reaped_exit_code != exit_code:
            raise ProfileError("workload child exit status changed while reaping")
        source_after = source_identity(source["commit"], source["tree"])
        if source_after != source:
            raise ProfileError("checkout source identity changed during workload")
        inputs_after = runtime_inputs(profile)
        if canonical_bytes(inputs_after) != canonical_bytes(inputs):
            raise ProfileError("runtime input identity changed during workload")
    ended_ms = time.time_ns() // 1_000_000
    artifacts, missing_artifacts = collect_artifacts(profile, state_root)

    if not settled_cleanly:
        semantic_result = "ambiguous"
    elif timed_out:
        semantic_result = "timed_out"
    elif exit_code == 0 and not missing_artifacts:
        semantic_result = "passed"
    else:
        semantic_result = "failed"

    toolchain = toolchain_summary(profile, state_root)
    semantic = semantic_key(source, profile, parameters, inputs)
    result = {
        "document_type": RESULT_DOCUMENT_TYPE,
        "schema_version": RESULT_SCHEMA_VERSION,
        "source": source,
        "profile": {"id": profile["id"], "generation": profile["generation"]},
        "semantic_validator": profile["semantic_validator"],
        "environment_class": profile["environment_class"],
        "expected_result_class": profile["expected_result_class"],
        "result": semantic_result,
        "parameters": parameters,
        "runtime_input_identities": inputs,
        "artifact_identities": artifacts,
        "validation": {
            "missing_required_artifact_classes": missing_artifacts,
        },
        "stage_timings": read_stage_timings(stage_log, token, elapsed),
        "resource_summary": {
            "resource_class": profile["resource_class"],
            "cpu_count": os.cpu_count(),
            "memory_bytes": memory_bytes(),
            "architecture": normalized_arch(),
        },
        "toolchain": toolchain,
        "benchmark": {
            "state_class": args.state_class,
            "semantic_comparison_key": semantic,
            "comparison_context_key": context_key(
                semantic, args.state_class, toolchain["identity"]
            ),
        },
        "network_class": profile["network_class"],
        "timeout_class": profile["timeout"]["class"],
        "cleanup": {
            "state": cleanup_state,
            "process_group_settled": settled_cleanly,
        },
        "exit_code": exit_code,
        "started_at_unix_millis": started_ms,
        "ended_at_unix_millis": ended_ms,
    }
    publish_result(result, args.result)
    if temporary is not None:
        temporary.cleanup()
    return 0 if semantic_result == "passed" else 1


def plan_profile(args: argparse.Namespace) -> int:
    registry = load_registry()
    profile = profile_by_id(registry, args.profile)
    if args.generation is not None and args.generation != profile["generation"]:
        raise ProfileError("profile generation mismatch")
    source = source_identity(args.commit, args.tree)
    parameters = parse_parameters(profile, args.param)
    if args.state_class not in profile["benchmark_state_classes"]:
        raise ProfileError(
            f"{profile['id']} does not admit benchmark state {args.state_class}"
        )
    plan = {
        "document_type": "cmux-workload-plan",
        "schema_version": 1,
        "source": source,
        "profile": {"id": profile["id"], "generation": profile["generation"]},
        "semantic_scope": profile["semantic_scope"],
        "repository_entrypoint": profile["entrypoint"],
        "platform": profile["platform"],
        "expected_result_class": profile["expected_result_class"],
        "semantic_validator": profile["semantic_validator"],
        "environment_class": profile["environment_class"],
        "timeout": profile["timeout"],
        "resource_class": profile["resource_class"],
        "network_class": profile["network_class"],
        "benchmark_state_class": args.state_class,
        "parameters": parameters,
    }
    sys.stdout.buffer.write(canonical_bytes(plan) + b"\n")
    return 0


def validate_result_structure(value: dict[str, Any]) -> None:
    exact_keys(
        value,
        {
            "document_type",
            "schema_version",
            "source",
            "profile",
            "semantic_validator",
            "environment_class",
            "expected_result_class",
            "result",
            "parameters",
            "runtime_input_identities",
            "artifact_identities",
            "validation",
            "stage_timings",
            "resource_summary",
            "toolchain",
            "benchmark",
            "network_class",
            "timeout_class",
            "cleanup",
            "exit_code",
            "started_at_unix_millis",
            "ended_at_unix_millis",
        },
        "semantic result structure",
    )
    source = value["source"]
    profile = value["profile"]
    validation = value["validation"]
    benchmark = value["benchmark"]
    cleanup = value["cleanup"]
    toolchain = value["toolchain"]
    for item, fields, label in (
        (source, {"repository", "commit", "tree"}, "semantic result source structure"),
        (profile, {"id", "generation"}, "semantic result profile structure"),
        (
            validation,
            {"missing_required_artifact_classes"},
            "semantic result validation structure",
        ),
        (
            benchmark,
            {"state_class", "semantic_comparison_key", "comparison_context_key"},
            "semantic result benchmark structure",
        ),
        (
            cleanup,
            {"state", "process_group_settled"},
            "semantic result cleanup structure",
        ),
        (toolchain, {"identity", "observations"}, "semantic result toolchain structure"),
    ):
        if not isinstance(item, dict):
            raise ProfileError(f"{label} is invalid")
        exact_keys(item, fields, label)

    if (
        source["repository"] != "manaflow-ai/cmux"
        or not isinstance(source["commit"], str)
        or OID_RE.fullmatch(source["commit"]) is None
        or not isinstance(source["tree"], str)
        or OID_RE.fullmatch(source["tree"]) is None
    ):
        raise ProfileError("semantic result source structure is invalid")
    if (
        not isinstance(profile["id"], str)
        or PROFILE_RE.fullmatch(profile["id"]) is None
        or type(profile["generation"]) is not int
        or profile["generation"] < 1
    ):
        raise ProfileError("semantic result profile structure is invalid")
    missing = validation["missing_required_artifact_classes"]
    if not isinstance(missing, list) or not all(
        isinstance(item, str) and item for item in missing
    ):
        raise ProfileError("semantic result validation structure is invalid")
    digest_re = re.compile(r"^sha256:[0-9a-f]{64}$")
    if (
        benchmark["state_class"] not in STATE_CLASSES
        or not isinstance(benchmark["semantic_comparison_key"], str)
        or digest_re.fullmatch(benchmark["semantic_comparison_key"]) is None
        or not isinstance(benchmark["comparison_context_key"], str)
        or digest_re.fullmatch(benchmark["comparison_context_key"]) is None
    ):
        raise ProfileError("semantic result benchmark structure is invalid")
    if (
        cleanup["state"] not in {"complete", "forced", "incomplete"}
        or type(cleanup["process_group_settled"]) is not bool
    ):
        raise ProfileError("semantic result cleanup structure is invalid")
    if (
        not isinstance(toolchain["identity"], str)
        or digest_re.fullmatch(toolchain["identity"]) is None
        or not isinstance(toolchain["observations"], dict)
        or any(
            not isinstance(name, str)
            or not name
            or not isinstance(observation, str)
            for name, observation in toolchain["observations"].items()
        )
    ):
        raise ProfileError("semantic result toolchain structure is invalid")
    if toolchain["identity"] != sha256_bytes(
        canonical_bytes(toolchain["observations"])
    ):
        raise ProfileError("semantic result toolchain identity is inconsistent")
    if (
        not isinstance(value["parameters"], dict)
        or not isinstance(value["runtime_input_identities"], list)
        or not isinstance(value["artifact_identities"], list)
        or not isinstance(value["stage_timings"], list)
        or not isinstance(value["resource_summary"], dict)
        or not isinstance(value["semantic_validator"], str)
        or not value["semantic_validator"]
        or value["environment_class"] not in ENVIRONMENT_CLASSES
        or not isinstance(value["expected_result_class"], str)
        or not value["expected_result_class"]
        or not isinstance(value["network_class"], str)
        or not value["network_class"]
        or not isinstance(value["timeout_class"], str)
        or not value["timeout_class"]
        or type(value["exit_code"]) is not int
        or type(value["started_at_unix_millis"]) is not int
        or type(value["ended_at_unix_millis"]) is not int
    ):
        raise ProfileError("semantic result structure is invalid")

    parameters = value["parameters"]
    if any(
        not isinstance(name, str)
        or PARAM_RE.fullmatch(name) is None
        or type(parameter) is not int
        for name, parameter in parameters.items()
    ):
        raise ProfileError("semantic result parameters are invalid")

    runtime_inputs = value["runtime_input_identities"]
    seen_runtime_inputs: set[str] = set()
    for item in runtime_inputs:
        if not isinstance(item, dict):
            raise ProfileError("semantic result runtime input is invalid")
        exact_keys(
            item,
            {"name", "class", "identity", "sha256", "bytes"},
            "semantic result runtime input",
        )
        if (
            not isinstance(item["name"], str)
            or not item["name"]
            or item["name"] in seen_runtime_inputs
            or not isinstance(item["class"], str)
            or not item["class"]
            or item["identity"] not in {"file-sha256", "parent-tree-sha256"}
            or not isinstance(item["sha256"], str)
            or digest_re.fullmatch(item["sha256"]) is None
            or type(item["bytes"]) is not int
            or item["bytes"] < 0
        ):
            raise ProfileError("semantic result runtime input is invalid")
        seen_runtime_inputs.add(item["name"])

    for item in value["artifact_identities"]:
        if not isinstance(item, dict):
            raise ProfileError("semantic result artifact identity is invalid")
        exact_keys(
            item,
            {"class", "path_class", "sha256", "bytes"},
            "semantic result artifact identity",
        )
        if (
            not isinstance(item["class"], str)
            or not item["class"]
            or item["path_class"] != "repository_output"
            or not isinstance(item["sha256"], str)
            or digest_re.fullmatch(item["sha256"]) is None
            or type(item["bytes"]) is not int
            or item["bytes"] < 0
        ):
            raise ProfileError("semantic result artifact identity is invalid")

    resource = value["resource_summary"]
    exact_keys(
        resource,
        {"resource_class", "cpu_count", "memory_bytes", "architecture"},
        "semantic result resource summary",
    )
    if (
        not isinstance(resource["resource_class"], str)
        or not resource["resource_class"]
        or type(resource["cpu_count"]) is not int
        or resource["cpu_count"] <= 0
        or (
            resource["memory_bytes"] is not None
            and (type(resource["memory_bytes"]) is not int or resource["memory_bytes"] <= 0)
        )
        or not isinstance(resource["architecture"], str)
        or not resource["architecture"]
    ):
        raise ProfileError("semantic result resource summary is invalid")

    recomputed_semantic = semantic_key(
        source,
        {
            "id": profile["id"],
            "generation": profile["generation"],
            "semantic_validator": value["semantic_validator"],
            "environment_class": value["environment_class"],
        },
        parameters,
        runtime_inputs,
    )
    recomputed_context = context_key(
        recomputed_semantic,
        benchmark["state_class"],
        toolchain["identity"],
    )
    if (
        benchmark["semantic_comparison_key"] != recomputed_semantic
        or benchmark["comparison_context_key"] != recomputed_context
    ):
        raise ProfileError("semantic result comparison identity is inconsistent")


def load_result(path: str) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ProfileError(f"cannot read semantic result: {path}") from error
    if (
        not isinstance(value, dict)
        or value.get("document_type") != RESULT_DOCUMENT_TYPE
        or value.get("schema_version") != RESULT_SCHEMA_VERSION
        or value.get("result") not in RESULTS
    ):
        raise ProfileError("unsupported semantic result")
    validate_result_structure(value)
    return value


def compare_results(left_path: str, right_path: str) -> int:
    left = load_result(left_path)
    right = load_result(right_path)
    reasons: list[str] = []
    if left.get("benchmark", {}).get("semantic_comparison_key") != right.get(
        "benchmark", {}
    ).get("semantic_comparison_key"):
        reasons.append("semantic identity differs")
    if left.get("benchmark", {}).get("comparison_context_key") != right.get(
        "benchmark", {}
    ).get("comparison_context_key"):
        reasons.append("benchmark context differs")
    for name, value in (("left", left), ("right", right)):
        if value.get("result") != "passed":
            reasons.append(f"{name} result is not passed")
        if value.get("cleanup", {}).get("state") != "complete":
            reasons.append(f"{name} cleanup is not complete")
        if value.get("validation", {}).get("missing_required_artifact_classes"):
            reasons.append(f"{name} artifact validation is incomplete")
    output = {
        "document_type": "cmux-workload-comparison",
        "schema_version": 1,
        "comparable": not reasons,
        "reasons": reasons,
        "semantic_comparison_key": left.get("benchmark", {}).get(
            "semantic_comparison_key"
        ),
        "comparison_context_key": left.get("benchmark", {}).get(
            "comparison_context_key"
        ),
    }
    sys.stdout.buffer.write(canonical_bytes(output) + b"\n")
    return 0 if not reasons else 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate")
    commands.add_parser("list")
    describe = commands.add_parser("describe")
    describe.add_argument("profile")
    for name in ("plan", "run"):
        sub = commands.add_parser(name)
        sub.add_argument("profile")
        sub.add_argument("--generation", type=int)
        sub.add_argument("--commit")
        sub.add_argument("--tree")
        sub.add_argument("--state-class", default="cold")
        sub.add_argument("--param", action="append", default=[])
        if name == "run":
            sub.add_argument("--state-root")
            sub.add_argument("--result")
    compare = commands.add_parser("compare")
    compare.add_argument("left")
    compare.add_argument("right")
    stage = commands.add_parser("stage")
    stage.add_argument("action", choices=("start", "end"))
    stage.add_argument("stage")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "stage":
            stage_event(args.action, args.stage)
            return 0
        registry = load_registry()
        if args.command == "validate":
            return 0
        if args.command == "list":
            rows = [
                {
                    "id": p["id"],
                    "generation": p["generation"],
                    "platform": p["platform"]["os"],
                    "environment_class": p["environment_class"],
                    "entrypoint": p["entrypoint"],
                }
                for p in registry["profiles"]
            ]
            sys.stdout.buffer.write(canonical_bytes(rows) + b"\n")
            return 0
        if args.command == "describe":
            p = profile_by_id(registry, args.profile)
            value = dict(p)
            value["semantic_identity"] = f"{p['id']}@{p['generation']}"
            sys.stdout.buffer.write(canonical_bytes(value) + b"\n")
            return 0
        if args.command == "plan":
            return plan_profile(args)
        if args.command == "run":
            return run_profile(args)
        if args.command == "compare":
            return compare_results(args.left, args.right)
        raise AssertionError(args.command)
    except ProfileError as error:
        print(f"cmux workload profile refused: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
