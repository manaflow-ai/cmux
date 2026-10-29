#!/usr/bin/env python3
"""Stages fleet CEF fork builds as the cmux CEF pin, with no R2 upload and no GitHub release
(plans/cmux-next/chrome-parity/p01-process.md, task 003; the release train of task 178 replaces it).

  cef_pin_staging.py pin --arm64 JOB [--x86_64 JOB] [--rb-host-step STEP] [--min-api N]
                         [--accept-missing-api N,N] [--fork-branch NAME] [--manifest PATH]
                         [--rb-host-pin PATH] [--work DIR]
  cef_pin_staging.py fork-api --verify verify-off.json [--manifest PATH]

`pin` reads each JOB (a finished `cmux-ci build cef --arch <arch>` job), downloads its artifact
`cef.tar` (`cmux-ci artifact`, checked against the job's sha256) and checks it before it writes
anything:
  - the tar holds exactly one dist folder, with `Chromium Embedded Framework.framework`, its
    Mach-O binary for that arch, `include/cef_cmux.h` and `archive.json`;
  - archive.json names the job's fork commit, the arch (gn target_cpu) and dcheck_always_on = false;
  - CMUX_CEF_API_VERSION in cef_cmux.h is at least --min-api (default 30), the same for both arches,
    and both jobs built the same fork commit;
  - the header's API history lists every number up to CMUX_CEF_API_VERSION. The app gates features
    with `>= N`, so a fork line that skips a number (API 30 without cmux.34's 28 and 29) passes a
    gate it does not implement. Such a build is refused unless --accept-missing-api names exactly
    the skipped numbers; the manifest then records them in `missing_api`.
The manifest then pins the job artifacts themselves by sha256. Fleet builds of cmux fetch them from
the controller's artifact store (ensure-cef.sh source 2, the recipe's cef-seed), which keeps a job's
artifact 14 days: `staging.store_expires` says until when. ensure-cef.sh enforces the `staging`
object: only the controller store serves the pin, no Release build embeds it, and it fails after
store_expires (warning from 3 days before). The top-level `version` is the arm64 dist folder's
name, because ensure-cef.sh and the fleet seed unpack `<version>/`; the x86_64 object names its
own folder in `dir`. `debug_symbols` names the dSYM archive inside each dist.

The remote browser host (scripts/cmux-next/remote-browser-host.pin.json) must link the staged
arm64 build: embed-remote-browser-host.sh fails a DEV build whose host links another CEF. So `pin`
refuses to write a manifest that the current host pin does not match, unless --rb-host-step STEP
names a passed fleet step of scripts/ci/cmux-remote-browser-host-build.sh run with
--cef sha256:<the arm64 artifact>; that step's artifact becomes the host pin, with its own
`staging` object (ensure-remote-browser-host.sh and check-pinned-assets.sh enforce it).

`fork-api` reads cef-layer-verify.py's verify-<mode>.json and checks that the running app's
debug.cef `windows.fork_api` is at least the manifest's cmux_cef_api_version, and that no fork API
gate in the app's sources names a number in the manifest's `missing_api` (a PASS or FAIL row each;
exit 1 on FAIL).

Environment: CMUX_CI (default ~/.local/bin/cmux-ci).
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

FRAMEWORK = "Chromium Embedded Framework.framework"
BINARY = f"{FRAMEWORK}/Chromium Embedded Framework"
RB_HOST_SCRIPT = "scripts/ci/cmux-remote-browser-host-build.sh"
RB_HOST_CRATE = "cmux-tui/crates/cmux-remote-browser-host"
RB_HOST_ASSET = "cmux-remote-browser-host-macos-arm64"
STORE_DAYS = 14  # the controller store's lifecycle for job artifacts (hq build-fleet README, Artifact store)
# Mach-O 64-bit (MH_MAGIC_64, little endian) and the CPU type of each arch.
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE = {"arm64": 0x0100000C, "x86_64": 0x01000007}
GN_CPU = {"arm64": "arm64", "x86_64": "x64"}
DIR_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
SHA_RE = re.compile(r"[0-9a-f]{64}")
REF_RE = re.compile(r"[0-9a-f]{40}")
# cef_cmux.h: the history block runs from this line to the #define; an entry starts `//   N:` or `//  NN `
# (a wrapped line has more indent).
API_HISTORY_START = "// Version of this API."
API_ENTRY_RE = re.compile(r"^// {1,3}(\d+)[: ]")
# The app's fork API gates: `static let xForkAPI: Int32 = N`, ChromiumHost's kMinForkAPI, `forkAPIVersion >= N`.
GATE_SOURCES = ("Packages/macOS/CmuxNext/Sources", "Packages/macOS/CmuxNext/ChromiumHost/src")
GATE_RE = re.compile(r"static let (\w*[Ff]orkAPI)(?:: Int32)? = (\d+)|constexpr int (kMinForkAPI) = (\d+)"
                     r"|(forkAPIVersion)(?:\(\))? >= (\d+)")
STAGING_NOTE = ("staging pin of fleet builds: no R2 object and no GitHub release; only the controller artifact "
                "store serves the sha256, until store_expires, and no Release build embeds it "
                "(scripts/cmux-next/cef-pin-staging.sh)")
ROOT = Path(__file__).resolve().parents[2]


class StagingError(Exception):
    """A job, artifact or dist that cannot be staged; the message says which and why."""


def cmux_ci(*args: str) -> str:
    tool = os.environ.get("CMUX_CI") or str(Path.home() / ".local/bin/cmux-ci")
    done = subprocess.run([tool, *args], capture_output=True, text=True)
    if done.returncode != 0:
        raise StagingError(f"cmux-ci {' '.join(args)} failed ({done.returncode}): {done.stderr.strip()[-400:]}")
    return done.stdout


def job_status(job: str) -> dict:
    try:
        return json.loads(cmux_ci("status", job))
    except ValueError as error:
        raise StagingError(f"cmux-ci status {job} printed no JSON: {error}") from error


def digest_of(field: str, what: str) -> str:
    hexd = (field or "").removeprefix("sha256:")
    if not SHA_RE.fullmatch(hexd):
        raise StagingError(f"{what} has no sha256 artifact (got {field!r})")
    return hexd


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(job: str, sha: str, out: Path) -> Path:
    """The job's artifact at OUT (reused when it already hashes to SHA)."""
    if not (out.is_file() and sha256_file(out) == sha):
        out.parent.mkdir(parents=True, exist_ok=True)
        cmux_ci("artifact", job, str(out))
    if not out.is_file() or sha256_file(out) != sha:
        raise StagingError(f"the artifact of {job} at {out} does not hash to {sha}")
    return out


def store_expiry(job: dict, job_id: str) -> str:
    """The date the controller store drops the job's artifact: STORE_DAYS after the job finished (its last
    change, RFC 3339 UTC)."""
    try:
        done = dt.datetime.strptime((job.get("updated_at") or "")[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        raise StagingError(f"job {job_id} names no finish time (updated_at): its store expiry is unknown") from None
    return (done + dt.timedelta(days=STORE_DAYS)).date().isoformat()


def inspect_dist(archive: Path, arch: str) -> dict:
    """The dist folder of a fleet `cef.tar` and the facts the manifest needs; raises when it is not one."""
    tops: set[str] = set()
    header = archive_json = magic = debug = None
    with tarfile.open(archive, "r:*") as tar:
        for member in tar:
            parts = member.name.strip("/").split("/", 1)
            tops.add(parts[0])
            rest = parts[1] if len(parts) > 1 else ""
            if rest.endswith(".dSYM.tar.xz") and "/" not in rest and member.isfile():
                debug = rest
            elif rest == BINARY and member.isfile():
                magic = tar.extractfile(member).read(8)
            elif rest == "include/cef_cmux.h" and member.isfile():
                header = tar.extractfile(member).read().decode("utf-8", "replace")
            elif rest == "archive.json" and member.isfile():
                archive_json = tar.extractfile(member).read()
    if len(tops) != 1:
        raise StagingError(f"{archive} holds {len(tops)} top-level entries ({sorted(tops)[:4]}), not one dist folder")
    folder = tops.pop()
    if not DIR_RE.fullmatch(folder):
        raise StagingError(f"{archive}: dist folder {folder!r} is not a valid cache folder name")
    if magic is None:
        raise StagingError(f"{archive}: {folder}/{BINARY} is missing")
    if header is None or archive_json is None:
        raise StagingError(f"{archive}: {folder} has no include/cef_cmux.h or archive.json")
    if int.from_bytes(magic[:4], "little") != MH_MAGIC_64 or int.from_bytes(magic[4:8], "little") != CPU_TYPE[arch]:
        raise StagingError(f"{archive}: the framework binary is not a 64-bit Mach-O for {arch}")
    api = re.search(r"^#define CMUX_CEF_API_VERSION\s+(\d+)", header, re.M)
    if not api:
        raise StagingError(f"{archive}: cef_cmux.h defines no CMUX_CEF_API_VERSION")
    try:
        info = json.loads(archive_json)
    except ValueError as error:
        raise StagingError(f"{archive}: archive.json is not JSON: {error}") from error
    gn = info.get("gn_args") or {}
    if gn.get("target_cpu") != GN_CPU[arch]:
        raise StagingError(f"{archive}: archive.json target_cpu is {gn.get('target_cpu')!r}, not {GN_CPU[arch]}")
    if gn.get("dcheck_always_on") is not False:
        raise StagingError(f"{archive}: archive.json does not record dcheck_always_on = false")
    name = info.get("name") or ""
    cef = re.match(r"cef_binary_(\d+\.\d+\.\d+)", name)
    chromium = re.search(r"chromium-(\d+\.\d+\.\d+\.\d+)", name)
    if not cef or not chromium:
        raise StagingError(f"{archive}: archive.json name {name!r} gives no CEF and Chromium version")
    level = int(api.group(1))
    return {"dir": folder, "api": level, "missing": missing_api(header, level, archive),
            "fork_ref": info.get("cmux_ref") or "", "cef": cef.group(1), "chromium": chromium.group(1),
            "debug": debug}


def missing_api(header: str, level: int, archive: Path) -> list[int]:
    """The numbers in 1..LEVEL that cef_cmux.h's API history does not list."""
    lines = header.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith(API_HISTORY_START)), None)
    if start is None:
        raise StagingError(f"{archive}: cef_cmux.h has no API history ({API_HISTORY_START!r})")
    listed: set[int] = set()
    for line in lines[start + 1:]:
        if line.startswith("#define CMUX_CEF_API_VERSION"):
            break
        entry = API_ENTRY_RE.match(line)
        if entry:
            listed.add(int(entry.group(1)))
    return sorted(set(range(1, level + 1)) - listed)


def app_gates(root: Path) -> list[tuple[int, str]]:
    """(number, `path:line name`) of every fork API gate in the app's sources."""
    gates = []
    for top in GATE_SOURCES:
        for path in sorted((root / top).rglob("*")):
            if path.suffix not in (".swift", ".h", ".mm", ".cc") or not path.is_file():
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                for match in GATE_RE.finditer(line):
                    name, value = next((match.group(i), match.group(i + 1)) for i in (1, 3, 5) if match.group(i))
                    gates.append((int(value), f"{path.relative_to(root)}:{number} {name}"))
    return gates


def stage_arch(job_id: str, arch: str, work: Path) -> dict:
    job = job_status(job_id)
    if job.get("kind") != "cef" or job.get("state") != "done":
        raise StagingError(f"job {job_id} is a {job.get('kind')!r} job in state {job.get('state')!r}, not a done cef build")
    if job.get("variant") != arch:
        raise StagingError(f"job {job_id} built {job.get('variant')!r}, not {arch}")
    ref = job.get("ref") or ""
    if not REF_RE.fullmatch(ref):
        raise StagingError(f"job {job_id} names no 40-hex fork commit")
    sha = digest_of(job.get("artifact"), f"job {job_id}")
    facts = inspect_dist(fetch(job_id, sha, work / f"{sha}.tar"), arch)
    if facts["fork_ref"] != ref:
        raise StagingError(f"job {job_id} built {ref}, but its archive.json names {facts['fork_ref'] or 'no commit'}")
    return facts | {"job": job_id, "sha256": sha, "arch": arch, "expires": store_expiry(job, job_id)}


def manifest_for(arm: dict, x86: dict | None, fork_branch: str | None) -> dict:
    manifest = {
        "version": arm["dir"],
        "cef": arm["cef"],
        "chromium": arm["chromium"],
        "arch": "arm64",
        "repo": "manaflow-ai/cef",
        "asset": f"{arm['dir']}.tar",
        "sha256": arm["sha256"],
    }
    if arm["debug"]:
        manifest["debug_symbols"] = arm["debug"]
    if fork_branch:
        manifest["fork_branch"] = fork_branch
    manifest["fork_ref"] = arm["fork_ref"]
    manifest["cmux_cef_api_version"] = arm["api"]
    if arm["missing"]:
        manifest["missing_api"] = arm["missing"]
    if x86:
        manifest["x86_64"] = {"asset": f"{x86['dir']}.tar", "sha256": x86["sha256"], "dir": x86["dir"]}
        if x86["debug"]:
            manifest["x86_64"]["debug_symbols"] = x86["debug"]
        manifest["x86_64"]["fork_ref"] = x86["fork_ref"]
    manifest["require_dcheck_off"] = True
    manifest["staging"] = {
        "note": STAGING_NOTE,
        "jobs": {a["arch"]: a["job"] for a in (arm, x86) if a},
        "store_expires": min(a["expires"] for a in (arm, x86) if a),
    }
    return manifest


def rb_host_pin(step_id: str, arm: dict, work: Path) -> dict:
    step = job_status(step_id)
    if step.get("state") != "done" or step.get("script") != RB_HOST_SCRIPT:
        raise StagingError(f"step {step_id} is {step.get('script')!r} in state {step.get('state')!r}, "
                           f"not a done {RB_HOST_SCRIPT} step")
    cef = (step.get("inputs") or {}).get("cef") or step.get("cef") or ""
    if cef != "sha256:" + arm["sha256"]:
        raise StagingError(f"step {step_id} linked CEF {cef or '(none)'}, not the staged arm64 sha256:{arm['sha256']}")
    commit = step.get("ref") or ""
    if not REF_RE.fullmatch(commit):
        raise StagingError(f"step {step_id} names no 40-hex cmux commit")
    sha = digest_of(step.get("artifact"), f"step {step_id}")
    binary = fetch(step_id, sha, work / f"{sha}-{RB_HOST_ASSET}")
    with binary.open("rb") as handle:
        magic = handle.read(8)
    if int.from_bytes(magic[:4], "little") != MH_MAGIC_64 or int.from_bytes(magic[4:8], "little") != CPU_TYPE["arm64"]:
        raise StagingError(f"step {step_id}: the artifact is not a 64-bit arm64 Mach-O")
    tree = subprocess.run(["git", "-C", str(ROOT), "rev-parse", f"{commit}:{RB_HOST_CRATE}"],
                          capture_output=True, text=True)
    if tree.returncode != 0:
        raise StagingError(f"cannot read {RB_HOST_CRATE} at {commit} in this checkout (fetch it first)")
    return {"asset": RB_HOST_ASSET, "arch": "arm64", "sha256": sha, "source_commit": commit,
            "crate_tree": tree.stdout.strip(), "cef_version": arm["dir"], "cef_sha256": arm["sha256"],
            "build_step": step_id,
            "staging": {"note": STAGING_NOTE, "store_expires": min(store_expiry(step, step_id), arm["expires"])}}


def current_host_cef(path: Path) -> str:
    """The CEF sha256 the current remote browser host pin links ('' when there is none)."""
    try:
        return json.loads(path.read_text()).get("cef_sha256") or ""
    except (OSError, ValueError):
        return ""


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def pin(opts: argparse.Namespace) -> int:
    work = Path(opts.work)
    arm = stage_arch(opts.arm64, "arm64", work)
    x86 = stage_arch(opts.x86_64, "x86_64", work) if opts.x86_64 else None
    if x86 and (x86["fork_ref"], x86["api"], x86["missing"]) != (arm["fork_ref"], arm["api"], arm["missing"]):
        raise StagingError(f"arm64 is fork {arm['fork_ref'][:12]} API {arm['api']}, "
                           f"x86_64 is fork {x86['fork_ref'][:12]} API {x86['api']}: stage one fork build")
    if arm["api"] < opts.min_api:
        raise StagingError(f"fork {arm['fork_ref'][:12]} is API {arm['api']}, below --min-api {opts.min_api}")
    if arm["missing"] != opts.accept_missing_api:
        listed = ",".join(map(str, arm["missing"]))
        raise StagingError(f"fork {arm['fork_ref'][:12]} is API {arm['api']}, and its cef_cmux.h history lacks "
                           f"{listed or 'no number'} while --accept-missing-api names "
                           f"{','.join(map(str, opts.accept_missing_api)) or 'none'}: a `>= N` gate passes for a "
                           f"missing N. Stage a fork that has them"
                           + (f", or pass --accept-missing-api {listed} (recorded as missing_api)" if listed else ""))
    for number, where in app_gates(ROOT):
        if number in arm["missing"]:
            print(f"cef-pin-staging: warning: {where} gates on API {number}, which this pin lacks: the staging "
                  f"check's fork-api part fails until that gate or the fork changes", file=sys.stderr)
    host = rb_host_pin(opts.rb_host_step, arm, work) if opts.rb_host_step else None
    if not host and current_host_cef(Path(opts.rb_host_pin)) != arm["sha256"]:
        raise StagingError(f"{opts.rb_host_pin} links CEF sha256:{current_host_cef(Path(opts.rb_host_pin)) or '?'}, "
                           f"not the staged sha256:{arm['sha256']}: every DEV build would fail its CEF pin check. "
                           f"Build the host against the staged build and pass --rb-host-step")
    write_json(Path(opts.manifest), manifest_for(arm, x86, opts.fork_branch))
    print(f"cef-pin-staging: {opts.manifest}: {arm['dir']} fork {arm['fork_ref'][:12]} API {arm['api']}"
          + (f" (missing {arm['missing']})" if arm["missing"] else "")
          + f", arm64 sha256 {arm['sha256'][:12]}" + (f", x86_64 sha256 {x86['sha256'][:12]}" if x86 else ", no x86_64"))
    if host:
        write_json(Path(opts.rb_host_pin), host)
        print(f"cef-pin-staging: {opts.rb_host_pin}: host sha256 {host['sha256'][:12]} from step {host['build_step']}")
    return 0


def fork_api(opts: argparse.Namespace) -> int:
    manifest = json.loads(Path(opts.manifest).read_text())
    want = int(manifest.get("cmux_cef_api_version") or 0)
    missing = set(manifest.get("missing_api") or [])
    hits = [f"{where} = {number}" for number, where in app_gates(Path(opts.root)) if number in missing]
    print(f"{'FAIL' if hits else 'PASS'} fork-api-gaps: the pin lacks API {sorted(missing) or 'none'}; app gates on "
          f"them: {'; '.join(hits) or 'none'}")
    try:
        facts = json.loads(Path(opts.verify).read_text()).get("facts") or {}
    except (OSError, ValueError) as error:
        print(f"FAIL fork-api: cannot read {opts.verify}: {error}")
        return 1
    got = int(facts.get("fork_api") or 0)
    ok = want > 0 and got >= want
    print(f"{'PASS' if ok else 'FAIL'} fork-api: debug.cef windows.fork_api {got}, the pin's cmux_cef_api_version {want}")
    return 0 if ok and not hits else 1


def api_list(text: str) -> list[int]:
    try:
        return sorted({int(part) for part in text.split(",") if part.strip()})
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a comma-separated list of API numbers") from None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pin")
    p.add_argument("--arm64", required=True, help="the finished arm64 `cmux-ci build cef` job")
    p.add_argument("--x86_64", help="the finished x86_64 job of the same fork commit")
    p.add_argument("--rb-host-step", help="a done cmux-remote-browser-host-build.sh step linked to the arm64 build")
    p.add_argument("--min-api", type=int, default=30)
    p.add_argument("--accept-missing-api", type=api_list, default=[],
                   help="the API numbers below the build's that its fork line lacks, comma separated (exactly)")
    p.add_argument("--fork-branch")
    p.add_argument("--manifest", default=str(ROOT / "scripts/cmux-next/cef-manifest.json"))
    p.add_argument("--rb-host-pin", default=str(ROOT / "scripts/cmux-next/remote-browser-host.pin.json"))
    p.add_argument("--work", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "cef-pin-staging"))
    f = sub.add_parser("fork-api")
    f.add_argument("--verify", required=True, help="cef-layer-verify.py's verify-<mode>.json")
    f.add_argument("--manifest", default=str(ROOT / "scripts/cmux-next/cef-manifest.json"))
    f.add_argument("--root", default=str(ROOT), help="the checkout whose app sources hold the fork API gates")
    opts = parser.parse_args(argv)
    try:
        return pin(opts) if opts.command == "pin" else fork_api(opts)
    except StagingError as error:
        print(f"cef-pin-staging: error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
