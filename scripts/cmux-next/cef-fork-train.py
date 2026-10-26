#!/usr/bin/env python3
"""The shared CEF fork train: every program's fork exports in one build and one pin.

The ledger (scripts/cmux-next/cef-fork-train.json) lists each fork export: the
program that needs it, the fork API number its cmux gate checks (null until the
train numbers it), and the fork commit that implements it (null while none is
pushed). The train is one manaflow-ai/cef branch (`train_branch`) that every
program's train task (p01-process 178, p03-rendering 041, p13-webui 086,
p14-energy 136, ...) merges its exports into; one build of it is the one pin of
scripts/cmux-next/cef-manifest.json. No program bumps the pin alone: `pin` is
the only writer of the manifest's fork fields, and `check-manifest` refuses a
manifest whose fork API or fork ref is not the ledger's `pinned` record.

Chromium's release model is the reference: one milestone branch carries every
feature, gated by version (chrome/VERSION, one number per release), never a
build per feature.

  cef-fork-train.py check [--ledger L] [--sources DIR]
      Ledger rules, and every fork API gate in DIR's Swift and shim sources
      (`...ForkAPI: Int32 = N`, `constexpr int k...ForkApi = N`) newer than the
      pin is claimed by an export. Exit 1 on a broken rule.
  cef-fork-train.py status [--ledger L] [--fork-repo R] [--json]
      Each export by program: merged into the train, ready (a fork commit not
      merged yet), pending (no fork commit) or deferred. With a manaflow-ai/cef
      clone, merged is checked by ancestry and the train's CMUX_CEF_API_VERSION
      is read. Exit 0; `ready` is the gate.
  cef-fork-train.py ready [--ledger L] --fork-repo R
      Exit 0 only when the train can be built and pinned: every export that is
      not deferred is merged, and the train header says the ledger's API.
  cef-fork-train.py check-manifest [--ledger L] [--manifest M]
      The manifest's tag, fork API and fork ref are the ledger's `pinned`.
  cef-fork-train.py pin --tag T --sums SHA256SUMS --chromium V --fork-repo R
                        [--ledger L] [--manifest M] [--message FILE]
      After `ready`: writes the manifest's fork fields and the four artifacts'
      sha256 from the release's SHA256SUMS (arm64, x86_64 and their debug
      assets), records the pin in the ledger, and writes the pin commit message
      (fork API, features per program, checksums). The R2 fields are left to
      `publish-cef-r2.sh <tag> --manifest` (a person with R2 write access).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEDGER = HERE / "cef-fork-train.json"
MANIFEST = HERE / "cef-manifest.json"
SOURCES = HERE.parent.parent / "Packages" / "macOS" / "CmuxNext"
SHA = re.compile(r"^[0-9a-f]{40}$")
TAG = re.compile(r"^cef-(?P<cef>\d+\.\d+\.\d+)-cmux\.(?P<n>\d+)$")
# A gate: Swift `static let fooForkAPI: Int32 = N`, C++ `constexpr int kFooForkApi = N`.
# `kExit...` constants are the host's process exit statuses, not API numbers.
GATE = re.compile(r"(?:static let|constexpr int)\s+(?!kExit)(\w*[Ff]ork(?:API|Api))\s*(?::\s*Int32)?\s*=\s*(\d+)\b")
HEADER_API = re.compile(r"^#define CMUX_CEF_API_VERSION (\d+)$", re.M)
STATES = ("merged", "ready", "pending", "deferred")


class TrainError(Exception):
    """A broken ledger rule or a train that cannot be pinned."""


def load(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def rule_errors(ledger: dict) -> list[str]:
    """The ledger rules that hold without the fork: numbers, ids, holes, deferrals."""
    errors = []
    if ledger.get("schema") != 1:
        errors.append("schema must be 1")
    pinned, target = ledger["pinned"]["api"], ledger["api"]
    if target < pinned:
        errors.append(f"train api {target} is older than the pinned api {pinned}")
    seen = set()
    claimed = set()
    for e in ledger["exports"]:
        eid = e["id"]
        if eid in seen:
            errors.append(f"{eid}: listed twice")
        seen.add(eid)
        api, commit, defer = e.get("api"), e.get("fork_commit"), e.get("defer")
        if commit is not None and not SHA.match(commit):
            errors.append(f"{eid}: fork_commit must be a full 40-hex sha")
        if api is None:
            continue
        if not isinstance(api, int) or api <= pinned:
            errors.append(f"{eid}: api {api} must be newer than the pinned api {pinned}")
        elif api > target and not defer:
            errors.append(f"{eid}: api {api} is past the train's {target}; defer it or raise the train")
        elif api <= target and defer:
            errors.append(f"{eid}: deferred, but a gate at api {api} would read the train ({target}) as having it;"
                          " renumber it past the train or land it")
        claimed.add(api)
    holes = [n for n in range(pinned + 1, target + 1) if n not in claimed]
    if holes:
        errors.append("no export claims api " + ", ".join(map(str, holes))
                      + ": every number up to the train's must say what it holds")
    return errors


def gate_errors(ledger: dict, sources: Path) -> list[str]:
    """Fork API gates in the app newer than the pin that no export claims."""
    pinned = ledger["pinned"]["api"]
    claimed = {e["api"] for e in ledger["exports"] if e.get("api") is not None}
    errors = []
    for path in sorted(sources.rglob("*")):
        parts = path.relative_to(sources).parts
        if path.suffix not in (".swift", ".mm", ".h", ".cc") or "Tests" in parts or any(p.startswith(".") for p in parts):
            continue
        for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for name, number in GATE.findall(line):
                n = int(number)
                if n > pinned and n not in claimed:
                    errors.append(f"{path.relative_to(sources)}:{lineno}: {name} checks api {n},"
                                  " which no export in the train ledger claims")
    return errors


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def train_ref(ledger: dict, repo: Path) -> str:
    for ref in (f"origin/{ledger['train_branch']}", ledger["train_branch"]):
        out = git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        if out.returncode == 0:
            return out.stdout.strip()
    raise TrainError(f"{repo}: no branch {ledger['train_branch']} (fetch {ledger['fork_repo']})")


def header_api(repo: Path, ref: str) -> int | None:
    out = git(repo, "show", f"{ref}:include/cef_cmux.h")
    found = HEADER_API.search(out.stdout) if out.returncode == 0 else None
    return int(found.group(1)) if found else None


def states(ledger: dict, repo: Path | None) -> tuple[dict[str, str], str | None, int | None]:
    """Each export's state, and the train's ref and header API when a fork clone is given."""
    ref = train_ref(ledger, repo) if repo else None
    result = {}
    for e in ledger["exports"]:
        commit = e.get("fork_commit")
        if e.get("defer"):
            result[e["id"]] = "deferred"
        elif commit is None:
            result[e["id"]] = "pending"
        elif ref is None:
            result[e["id"]] = "ready"
        else:
            merged = git(repo, "merge-base", "--is-ancestor", commit, ref).returncode == 0
            result[e["id"]] = "merged" if merged else "ready"
    return result, ref, header_api(repo, ref) if ref else None


def ready_errors(ledger: dict, repo: Path) -> list[str]:
    found, ref, api = states(ledger, repo)
    errors = rule_errors(ledger)
    for e in ledger["exports"]:
        state = found[e["id"]]
        if state == "pending":
            errors.append(f"{e['id']} ({e['program']}): no fork commit; push it, or defer it with a reason")
        elif state == "ready":
            errors.append(f"{e['id']} ({e['program']}): {e['fork_commit'][:10]} is not merged into {ledger['train_branch']}")
    if api != ledger["api"]:
        errors.append(f"{ledger['train_branch']} at {ref[:10]} says CMUX_CEF_API_VERSION {api}, the ledger {ledger['api']}")
    return errors


def manifest_errors(ledger: dict, manifest: dict) -> list[str]:
    pinned = ledger["pinned"]
    errors = []
    pairs = (("tag", manifest.get("tag")), ("api", manifest.get("cmux_cef_api_version")),
             ("fork_ref", manifest.get("fork_ref")))
    for field, value in pairs:
        if value != pinned[field]:
            errors.append(f"cef-manifest.json {field} {value!r} is not the train's pin {pinned[field]!r}:"
                          " pin through cef-fork-train.py pin, never one program's bump")
    x86 = manifest.get("x86_64", {}).get("fork_ref")
    if x86 is not None and x86 != pinned["fork_ref"]:
        errors.append(f"cef-manifest.json x86_64 fork_ref {x86!r} is not the train's pin")
    return errors


def read_sums(path: Path) -> dict[str, str]:
    sums = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            sums[parts[1].lstrip("*")] = parts[0]
    return sums


def artifact(tag: str, arch: str, sums: dict[str, str], repo: str, fork_ref: str) -> dict:
    asset, debug = f"{tag}-macos-{arch}.tar.xz", f"{tag}-macos-{arch}-debug.tar.xz"
    missing = [name for name in (asset, debug) if name not in sums]
    if missing:
        raise TrainError("SHA256SUMS has no " + ", ".join(missing))
    return {"asset": asset, "sha256": sums[asset],
            "url": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
            "debug_asset": debug, "debug_sha256": sums[debug], "fork_ref": fork_ref}


def pinned_manifest(old: dict, ledger: dict, tag: str, chromium: str, fork_ref: str, sums: dict[str, str]) -> dict:
    """The manifest for the train's build; R2 fields are dropped for publish-cef-r2.sh to add."""
    match = TAG.match(tag)
    if not match:
        raise TrainError(f"tag {tag!r} is not cef-<cef version>-cmux.<n>")
    repo = ledger["fork_repo"]
    arm = artifact(tag, "arm64", sums, repo, fork_ref)
    x86 = artifact(tag, "x86_64", sums, repo, fork_ref)
    out = {"version": tag, "cef": match["cef"], "chromium": chromium, "arch": old.get("arch", "arm64"),
           "repo": repo, "tag": tag, "asset": arm["asset"], "url": arm["url"], "sha256": arm["sha256"],
           "debug_asset": arm["debug_asset"], "debug_sha256": arm["debug_sha256"],
           "fork_branch": ledger["train_branch"], "fork_ref": fork_ref,
           "cmux_cef_api_version": ledger["api"], "x86_64": {k: x86[k] for k in
           ("asset", "sha256", "url", "debug_asset", "debug_sha256", "fork_ref")}}
    kept = {k: v for k, v in old.items() if k not in out and k not in ("r2_bucket", "r2_key", "debug_r2_key")}
    out.update(kept)
    return out


def pin_message(ledger: dict, manifest: dict, previous_api: int) -> str:
    lines = [f"CEF: pin {manifest['tag']} (fork API {ledger['api']}, the shared fork train for every program)", "",
             f"Fork: {ledger['fork_repo']} {ledger['train_branch']} at {manifest['fork_ref']};"
             f" fork API {previous_api} -> {ledger['api']}. One build, one pin (p07-memory-074).", "",
             "Artifacts (sha256):"]
    for label, art in (("arm64", manifest), ("x86_64", manifest["x86_64"])):
        lines.append(f"  {label} {art['asset']} {art['sha256']}")
        lines.append(f"  {label} {art['debug_asset']} {art['debug_sha256']}")
    lines += ["", "Features by program:"]
    by_program: dict[str, list[str]] = {}
    deferred = []
    for e in ledger["exports"]:
        if e.get("defer"):
            deferred.append(f"  {e['id']} ({e['program']}): {e['defer']}")
            continue
        number = f"API {e['api']}" if e.get("api") is not None else f"API {ledger['api']} (numbered by this train)"
        by_program.setdefault(e["program"], []).append(f"    {e['id']} ({number}): {e['summary']}")
    for program in sorted(by_program):
        lines.append(f"  {program}")
        lines += by_program[program]
    if deferred:
        lines += ["", "Deferred to the next train:"] + deferred
    lines += ["", f"R2: scripts/cmux-next/publish-cef-r2.sh {manifest['tag']} --manifest scripts/cmux-next/cef-manifest.json"
              " (one upload request, a person with R2 write access), its r2 fields in this commit."]
    return "\n".join(lines) + "\n"


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def report(errors: list[str]) -> int:
    for error in errors:
        print(f"cef-fork-train: {error}", file=sys.stderr)
    return 1 if errors else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=("check", "status", "ready", "check-manifest", "pin"))
    parser.add_argument("--ledger", type=Path, default=LEDGER)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--sources", type=Path, default=SOURCES)
    parser.add_argument("--fork-repo", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--tag")
    parser.add_argument("--sums", type=Path)
    parser.add_argument("--chromium")
    parser.add_argument("--message", type=Path)
    args = parser.parse_args(argv)
    ledger = load(args.ledger)
    try:
        if args.command == "check":
            errors = rule_errors(ledger)
            if args.sources.is_dir():
                errors += gate_errors(ledger, args.sources)
            return report(errors)
        if args.command == "check-manifest":
            return report(manifest_errors(ledger, load(args.manifest)))
        if args.command == "status":
            found, ref, api = states(ledger, args.fork_repo)
            if args.json:
                print(json.dumps({"train_ref": ref, "header_api": api, "api": ledger["api"], "exports": found}, indent=2))
                return 0
            where = f" at {ref[:10]} (header API {api})" if ref else " (no fork clone: merged is not checked)"
            print(f"train {ledger['train_branch']}{where}, ledger API {ledger['api']}, pinned API {ledger['pinned']['api']}")
            for state in STATES:
                rows = [e for e in ledger["exports"] if found[e["id"]] == state]
                if rows:
                    print(f"{state}:")
                    for e in rows:
                        print(f"  {e['id']:<24} {str(e.get('api') or '-'):>3}  {e['program']}")
            return 0
        if args.fork_repo is None:
            raise TrainError(f"{args.command} needs --fork-repo (a {ledger['fork_repo']} clone)")
        if args.command == "ready":
            return report(ready_errors(ledger, args.fork_repo))
        if not (args.tag and args.sums and args.chromium):
            raise TrainError("pin needs --tag, --sums and --chromium")
        errors = ready_errors(ledger, args.fork_repo)
        if errors:
            return report(errors)
        fork_ref = train_ref(ledger, args.fork_repo)
        previous_api = ledger["pinned"]["api"]
        manifest = pinned_manifest(load(args.manifest), ledger, args.tag, args.chromium, fork_ref, read_sums(args.sums))
        ledger["pinned"] = {"tag": args.tag, "api": ledger["api"], "fork_ref": fork_ref}
        message = pin_message(ledger, manifest, previous_api)
        # The pin ships every export that is not deferred; the next train lists only what it adds.
        ledger["exports"] = [e for e in ledger["exports"] if e.get("defer")]
        write_json(args.manifest, manifest)
        write_json(args.ledger, ledger)
        if args.message:
            args.message.write_text(message)
        else:
            sys.stdout.write(message)
        return 0
    except TrainError as error:
        return report([str(error)])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
