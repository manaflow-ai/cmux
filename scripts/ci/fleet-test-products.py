#!/usr/bin/env python3
"""Put the test bundles a fleet job built for this commit where `swift test --skip-build` reads them.

    fleet-test-products.py PACKAGE_DIR [--sha SHA] [--pr N] [--wait SECONDS]

The controller's compile-checks phase test-products builds one package's tests for a commit and keeps the test
bundles, resource bundles and frameworks of PACKAGE_DIR/.build/arm64-apple-macosx/debug as its job's artifact. This
reads that check (the read submits it), fetches the artifact with the controller's own client (checked by sha256,
as fleet-scheme-app.sh does), and unpacks it into this checkout's PACKAGE_DIR/.build/arm64-apple-macosx/debug.

The bundles name the directory they were built in: `#filePath` fixtures and SwiftPM's Bundle.module accessor (the
resource bundle's build path, a string literal) both hold it. That directory does not exist here, so every file
that holds it gets it replaced by a path of the same length, /tmp/cmux-ftp-<n>..., made a symlink to this
checkout; the Mach-O files are then signed again (ad hoc), since the edit breaks their signature.

Exit 0: the products are in place and the caller runs `swift test --skip-build`. Anything else: nothing is in place
(the build directory is left as it was) and the caller builds on this Mac, as it does without this script.
Needs CMUX_CI_CONTROLLER (a fleet step's worker sets it) or CMUX_FLEET_CONTROLLER.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "manaflow-ai/cmux"
MANIFEST = ".cmux-test-products.json"
TRIPLE = "arm64-apple-macosx"
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def log(msg: str) -> None:
    print(f"fleet-test-products: {msg}", file=sys.stderr, flush=True)


def read_check(controller: str, sha: str, package: str, pr: int, wait: int) -> dict:
    """The test-products receipt of sha, waiting up to `wait` seconds for its verdict."""
    deadline = time.monotonic() + wait
    while True:
        left = max(0, int(deadline - time.monotonic()))
        query = {"repo": REPO, "phase": "test-products", "packages": package, "wait": str(min(left, 600))}
        if pr > 0:
            query["pr"] = str(pr)
        url = f"{controller}/compile-checks/v1/{sha}?{urllib.parse.urlencode(query)}"
        try:
            with urllib.request.urlopen(url, timeout=min(left, 600) + 60) as resp:
                rec = json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 429 and time.monotonic() < deadline:
                time.sleep(10)
                continue
            raise SystemExit(f"fleet-test-products: the controller answered {e.code} for {sha[:12]} (not a head it "
                             "trusts, or no check)")
        state = rec.get("state")
        if state not in ("queued", "running") or time.monotonic() >= deadline:
            return rec
        log(f"test-products check {rec.get('job_id', '?')} is {state}")


def fetch_client(controller: str, root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(f"{controller}/v1/client/manifest", timeout=30) as resp:
        files = json.load(resp)["files"]
    for name, digest in files.items():
        if "/" in name or name.startswith("."):
            raise SystemExit(f"fleet-test-products: bad client file name {name!r}")
        data = urllib.request.urlopen(f"{controller}/v1/client/files/{name}", timeout=30).read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f"fleet-test-products: client {name}: sha256 mismatch")
        (root / name).write_bytes(data)
    return root / "ci-client.py"


def safe_members(tar: tarfile.TarFile, entries: list[str]):
    allowed = set(entries) | {MANIFEST}
    for m in tar.getmembers():
        top = m.name.split("/", 1)[0]
        if m.name.startswith("/") or ".." in m.name.split("/") or top not in allowed:
            raise SystemExit(f"fleet-test-products: the archive holds {m.name!r}, outside its manifest")
        if m.issym() or m.islnk():
            target = m.linkname
            if target.startswith("/") or (m.islnk() and ".." in target.split("/")):
                raise SystemExit(f"fleet-test-products: {m.name!r} links outside the products ({target!r})")
        elif not (m.isfile() or m.isdir()):
            raise SystemExit(f"fleet-test-products: {m.name!r} is not a file, directory or link")
        yield m


def alias_for(src_root: str, checkout: Path) -> str:
    """A path as long as src_root, under /tmp, a symlink to checkout (made here)."""
    n = len(src_root)
    prefix = "/tmp/cmux-ftp-"
    if n < len(prefix) + 4:
        raise SystemExit(f"fleet-test-products: src_root {src_root!r} is too short to map")
    for _ in range(64):
        tail = os.urandom(32).hex()
        alias = (prefix + tail)[:n]
        if not os.path.lexists(alias):
            os.symlink(checkout, alias)
            return alias
    raise SystemExit("fleet-test-products: no free /tmp alias")


def relocate(root: Path, old: bytes, new: bytes) -> tuple[int, list[Path]]:
    """Replace old by new in every regular file under root; return the count and the Mach-O files edited."""
    edited, machos = 0, []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            p = Path(dirpath, f)
            if p.is_symlink() or not p.is_file():
                continue
            data = p.read_bytes()
            if old not in data:
                continue
            mode = p.stat().st_mode
            p.chmod(mode | 0o200)
            p.write_bytes(data.replace(old, new))
            p.chmod(mode)
            edited += 1
            if data[:4] in MACHO_MAGIC:
                machos.append(p)
    return edited, machos


def bundle_of(p: Path, root: Path) -> Path:
    """The outermost .xctest/.framework/.bundle holding p (codesign signs bundles whole), else p."""
    rel = p.relative_to(root).parts
    top = root / rel[0]
    return top if top.suffix in (".xctest", ".framework", ".bundle") else p


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--sha", default="")
    ap.add_argument("--pr", type=int, default=int(os.environ.get("CMUX_PR_NUMBER") or 0))
    ap.add_argument("--wait", type=int, default=int(os.environ.get("CMUX_TEST_PRODUCTS_WAIT_SECONDS") or 1800))
    a = ap.parse_args(argv)
    controller = (os.environ.get("CMUX_CI_CONTROLLER") or os.environ.get("CMUX_FLEET_CONTROLLER") or "").rstrip("/")
    if not controller:
        log("no controller (CMUX_CI_CONTROLLER) here")
        return 2
    checkout = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
    sha = a.sha or subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    pkg_dir = (checkout / a.package_dir).resolve()
    if checkout not in pkg_dir.parents or not (pkg_dir / "Package.swift").is_file():
        log(f"{a.package_dir} is not a package of this checkout")
        return 2
    package = pkg_dir.name
    started = time.monotonic()
    rec = read_check(controller, sha, package, a.pr, a.wait)
    job = rec.get("job_id", "")
    if rec.get("state") != "pass" or not job:
        log(f"test-products check for {sha[:12]} {package}: {rec.get('state')} {rec.get('reason', '')} (job {job or '-'})")
        return 1
    waited = time.monotonic() - started
    with tempfile.TemporaryDirectory(prefix="fleet-test-products.") as tmp:
        tmpd = Path(tmp)
        client = fetch_client(controller, tmpd / "client")
        archive = tmpd / "test-products.tar.gz"
        env = dict(os.environ, CMUX_CI_CONTROLLER=controller)
        subprocess.run([sys.executable, str(client), "artifact", job, str(archive)], check=True, env=env)
        stage = tmpd / "stage"
        stage.mkdir()
        with tarfile.open(archive) as tar:
            first = tar.next()
            if first is None or first.name != MANIFEST:
                log("the archive does not start with its manifest")
                return 1
            manifest = json.load(tar.extractfile(first))
            if manifest.get("version") != 1 or manifest.get("sha") != sha:
                log(f"the products are of {manifest.get('sha')!r}, not {sha}")
                return 1
            want_rel = os.path.relpath(pkg_dir, checkout)
            if manifest.get("package_path") != want_rel:
                log(f"the products are of {manifest.get('package_path')!r}, not {want_rel}")
                return 1
            members = list(safe_members(tar, manifest["entries"]))
            # The members are checked above; the "tar" filter (3.12, backported) only adds its own checks.
            extra = {"filter": "tar"} if hasattr(tarfile, "tar_filter") else {}
            tar.extractall(stage, members=members, **extra)
        src_root = manifest["src_root"]
        alias = alias_for(src_root, checkout)
        edited, machos = relocate(stage, src_root.encode(), alias.encode())
        signed = set()
        for p in machos:
            target = bundle_of(p, stage)
            if target in signed:
                continue
            subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(target)], check=True,
                           stdout=subprocess.DEVNULL)
            signed.add(target)
        build = pkg_dir / ".build" / TRIPLE / "debug"
        build.mkdir(parents=True, exist_ok=True)
        for name in manifest["entries"]:
            dest = build / name
            if dest.is_symlink() or dest.is_file():
                dest.unlink()
            elif dest.exists():
                shutil.rmtree(dest)
            os.replace(stage / name, dest)
        debug_link = pkg_dir / ".build" / "debug"
        if not debug_link.exists():
            debug_link.symlink_to(f"{TRIPLE}/debug")
    print(f"fleet-test-products: {len(manifest['entries'])} products of {package} at {sha[:12]} from fleet job {job} "
          f"(waited {waited:.0f}s; {edited} files mapped {src_root} -> {alias} -> {checkout}; {len(signed)} re-signed)",
          flush=True)
    print(f"FLEET_TEST_PRODUCTS_ALIAS={alias}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
