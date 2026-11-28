"""Install a binary-only ACP Registry agent the way a person does, for acp-registry-conformance.sh.

    python3 -I acp_registry_install.py REGISTRY ID DEST

An agent that starts through npx or uvx prints nothing: cmux starts it itself. One that ships only an archive for this
platform gets it downloaded (HTTPS, 512 MiB cap), its sha256 checked when the registry names one, unpacked into DEST,
and the folder holding its program printed, for PATH. Any failure prints to stderr and nothing to stdout, so the agent
then fails its launch case the way cmux would fail to start it.
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

MAX_BYTES = 512 << 20


def platform_key() -> str | None:
    os_name = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    arch = {"x86_64": "x86_64", "AMD64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(platform.machine())
    return f"{os_name}-{arch}" if os_name and arch else None


def fetch(url: str, dest: Path) -> str:
    if not url.startswith("https://"):
        raise ValueError(f"not https: {url}")
    digest, size = hashlib.sha256(), 0
    request = urllib.request.Request(url, headers={"User-Agent": "acp-registry-conformance"})
    with urllib.request.urlopen(request, timeout=120) as response, dest.open("wb") as f:
        while chunk := response.read(1 << 20):
            size += len(chunk)
            if size > MAX_BYTES:
                raise ValueError(f"archive over {MAX_BYTES} bytes")
            digest.update(chunk)
            f.write(chunk)
    return digest.hexdigest()


def inside(root: Path, name: str) -> bool:
    return (root / name).resolve().is_relative_to(root.resolve())


def data_or_skip(member: tarfile.TarInfo, path: str) -> tarfile.TarInfo | None:
    """The `data` filter, except a link it refuses is left out rather than failing the whole archive.

    Cortex Code's archive carries a bundled venv whose `bin/python3.12` links to an absolute path; a person's `tar x`
    unpacks it and the agent never uses it. Every other refusal (a path outside DEST, a device file) still fails.
    """
    try:
        return tarfile.data_filter(member, path)
    except (tarfile.AbsoluteLinkError, tarfile.LinkOutsideDestinationError):
        print(f"skipped link {member.name} -> {member.linkname}", file=sys.stderr)
        return None


def unpack(archive: Path, url: str, dest: Path, cmd: str) -> None:
    lower = url.lower().split("?", 1)[0]
    if lower.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            if not all(inside(dest, n) for n in z.namelist()):
                raise ValueError("archive names a path outside its folder")
            z.extractall(dest)
            for info in z.infolist():  # zip keeps the mode in the upper bits
                mode = info.external_attr >> 16
                if mode:
                    os.chmod(dest / info.filename, mode & 0o777)
    elif any(lower.endswith(s) for s in (".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar")):
        with tarfile.open(archive) as t:
            t.extractall(dest, filter=data_or_skip)
    else:  # a bare program, saved as the program the registry names (muse's URL ends in `download/`)
        target = dest / Path(cmd).name
        shutil.copyfile(archive, target)
        target.chmod(0o755)


def main(registry: str, agent_id: str, dest: str) -> int:
    agents = {a.get("id"): a for a in json.loads(Path(registry).read_text()).get("agents", [])}
    agent = agents.get(agent_id)
    if agent is None:
        return 0
    dist = agent.get("distribution") or {}
    if dist.get("npx") or dist.get("uvx"):
        return 0
    target = (dist.get("binary") or {}).get(platform_key() or "")
    if not target:
        print(f"{agent_id}: no archive for {platform_key()}", file=sys.stderr)
        return 0
    url, cmd = target.get("archive", ""), target.get("cmd", "")
    root = Path(dest)
    root.mkdir(parents=True, exist_ok=True)
    archive = root / ".archive"
    try:
        got = fetch(url, archive)
        want = target.get("sha256")
        if want and got != want:
            raise ValueError(f"sha256 {got} is not the registry's {want}")
        unpack(archive, url, root, cmd)
    except Exception as error:  # noqa: BLE001  any failure is the launch case's reason
        print(f"{agent_id}: install failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 0
    finally:
        archive.unlink(missing_ok=True)
    program = (root / cmd).resolve() if cmd else None
    if program is None or not program.is_file() or not program.is_relative_to(root.resolve()):
        print(f"{agent_id}: archive has no {cmd}", file=sys.stderr)
        return 0
    program.chmod(program.stat().st_mode | 0o755)
    print(program.parent)
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
