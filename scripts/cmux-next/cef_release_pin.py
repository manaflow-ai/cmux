#!/usr/bin/env python3
"""Pins a manaflow-ai/cef release as scripts/cmux-next/cef-manifest.json, and checks a release pin
(plans/cmux-next/chrome-parity/p01-process.md, task 178: one fork release train, pinned once).

  cef_release_pin.py pin TAG [--repo manaflow-ai/cef] [--min-api N] [--accept-missing-api N,N]
                         [--fork-branch NAME] [--debug-symbols NAME] [--manifest PATH] [--from DIR --ref SHA]
  cef_release_pin.py check [--manifest PATH] [--min-api N] [--keys]

`pin` reads the release TAG (its SHA256SUMS, and cef_cmux.h and CHROMIUM_BUILD_COMPATIBILITY.txt at
the tag's commit) and writes a whole manifest: the arm64 artifact at the top level and the "x86_64"
object, each with its debug (dSYM) asset, and nothing of an earlier pin (a staging pin's `staging`
object and R2 keys go). It refuses a release that lacks one of the four assets
(<tag>-macos-<arch>.tar.xz and <tag>-macos-<arch>-debug.tar.xz, or -dsym.tar.xz) and a header below
--min-api (default: the app's own floor, kMinForkAPI of the Chromium host's chromium_host_wire.h; the
host exits on an older fork). --debug-symbols NAME records the Chromium dSYM archive each arch's dist
holds at its top (`debug_symbols`, which embed-cef.sh keeps beside a Release build). The app gates fork features with `>= N`, so a fork line that skips a number
passes a gate it does not implement: when the header's history skips numbers up to its
CMUX_CEF_API_VERSION, --accept-missing-api must name exactly those numbers and the manifest records
them in `missing_api`. --from DIR reads SHA256SUMS, cef_cmux.h and CHROMIUM_BUILD_COMPATIBILITY.txt
from DIR instead (--ref names the fork commit then); tests use it.

Then `publish-cef-r2.sh TAG --manifest PATH` uploads the assets and writes the R2 keys, and
`publish-cef-r2.sh --verify-manifest PATH` reads every pinned object back from R2.

`check` is the offline half of that: the manifest pins both arches with their debug assets, every
r2_key is the content-addressed cef/<sha256>/<asset> of its sha256, the fork API is at least
--min-api, both arches name one fork commit, and it is not a staging pin. With --keys it prints
"<asset> <sha256> <r2 key>" per artifact for publish-cef-r2.sh. Exit 1 on a finding.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ARCHES = ("arm64", "x86_64")
DEBUG_SUFFIXES = ("-debug.tar.xz", "-dsym.tar.xz")
TAG_RE = re.compile(r"cef-(\d+\.\d+\.\d+)-cmux\.(\d+)")
SHA_RE = re.compile(r"[0-9a-f]{64}")
REF_RE = re.compile(r"[0-9a-f]{40}")
# cef_cmux.h: the API history runs from this line to the #define; an entry starts `//   N:` or
# `//  NN ` (a wrapped line has more indent).
API_HISTORY_START = "// Version of this API."
API_ENTRY_RE = re.compile(r"^// {1,3}(\d+)[: ]")
API_DEFINE_RE = re.compile(r"^#define CMUX_CEF_API_VERSION (\d+)\s*$", re.M)
CHROMIUM_RE = re.compile(r"'chromium_checkout':\s*'refs/tags/([0-9.]+)'")
DEFAULT_MANIFEST = Path(__file__).resolve().parent / "cef-manifest.json"
HOST_WIRE = Path(__file__).resolve().parents[2] / "Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_wire.h"
MIN_FORK_API_RE = re.compile(r"^inline constexpr int kMinForkAPI = (\d+);", re.M)


class PinError(Exception):
    """A release or manifest that cannot be pinned; the message says which and why."""


def app_min_api() -> int:
    """The oldest fork API the app runs: the Chromium host's kMinForkAPI (it exits on an older fork)."""
    try:
        match = MIN_FORK_API_RE.search(HOST_WIRE.read_text())
    except OSError as error:
        raise PinError(f"cannot read the app's fork API floor in {HOST_WIRE}: {error}") from None
    if not match:
        raise PinError(f"{HOST_WIRE} has no `inline constexpr int kMinForkAPI = N;`")
    return int(match.group(1))


def api_of(header: str) -> tuple[int, list[int]]:
    """CMUX_CEF_API_VERSION of a cef_cmux.h and the numbers up to it that its history skips."""
    define = API_DEFINE_RE.search(header)
    if not define:
        raise PinError("cef_cmux.h has no #define CMUX_CEF_API_VERSION")
    version = int(define.group(1))
    start = header.find(API_HISTORY_START)
    if start < 0 or start > define.start():
        raise PinError(f"cef_cmux.h has no API history ({API_HISTORY_START!r}) before its #define")
    listed = {int(m.group(1)) for line in header[start:define.start()].splitlines()
              if (m := API_ENTRY_RE.match(line))}
    return version, [n for n in range(1, version + 1) if n not in listed]


def parse_sums(text: str) -> dict[str, str]:
    sums = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and SHA_RE.fullmatch(parts[0]):
            sums[parts[1].lstrip("*")] = parts[0]
    return sums


def assets_of(tag: str, sums: dict[str, str]) -> dict[str, dict[str, str]]:
    """Per arch: asset, sha256, debug_asset, debug_sha256; raises when one of the four is missing."""
    out, missing = {}, []
    for arch in ARCHES:
        asset = f"{tag}-macos-{arch}.tar.xz"
        debug = [f"{tag}-macos-{arch}{s}" for s in DEBUG_SUFFIXES if f"{tag}-macos-{arch}{s}" in sums]
        if asset not in sums:
            missing.append(asset)
        if len(debug) != 1:
            missing.append(f"{tag}-macos-{arch}-debug.tar.xz" if not debug else f"one debug asset of {arch}")
        if asset in sums and len(debug) == 1:
            out[arch] = {"asset": asset, "sha256": sums[asset], "debug_asset": debug[0],
                         "debug_sha256": sums[debug[0]]}
    if missing:
        raise PinError(f"release {tag} lacks {', '.join(missing)} in SHA256SUMS: the train ships both arches "
                       "with their debug assets")
    return out


def run(*args: str) -> str:
    done = subprocess.run(args, capture_output=True, text=True)
    if done.returncode != 0:
        raise PinError(f"{' '.join(args[:4])} failed ({done.returncode}): {done.stderr.strip()[-400:]}")
    return done.stdout


def github_inputs(repo: str, tag: str) -> tuple[str, str, str, str]:
    """SHA256SUMS, cef_cmux.h, CHROMIUM_BUILD_COMPATIBILITY.txt and the commit of release TAG."""
    sums = run("gh", "release", "download", tag, "--repo", repo, "--pattern", "SHA256SUMS", "--output", "-")
    ref = run("gh", "api", f"repos/{repo}/commits/refs/tags/{tag}", "--jq", ".sha").strip()

    def raw(path: str) -> str:
        return run("gh", "api", "-H", "Accept: application/vnd.github.raw", f"repos/{repo}/contents/{path}?ref={ref}")

    return sums, raw("include/cef_cmux.h"), raw("CHROMIUM_BUILD_COMPATIBILITY.txt"), ref


def build_manifest(tag: str, repo: str, sums: str, header: str, compat: str, ref: str, *, min_api: int,
                   accept_missing: list[int], fork_branch: str | None, debug_symbols: str | None = None) -> dict:
    match = TAG_RE.fullmatch(tag)
    if not match:
        raise PinError(f"tag {tag!r} is not cef-<x.y.z>-cmux.<n>")
    if not REF_RE.fullmatch(ref):
        raise PinError(f"fork ref {ref!r} is not a full commit sha")
    chromium = CHROMIUM_RE.search(compat)
    if not chromium:
        raise PinError("CHROMIUM_BUILD_COMPATIBILITY.txt names no chromium_checkout tag")
    api, missing = api_of(header)
    if api < min_api:
        raise PinError(f"release {tag} has fork API {api}; the pin needs >= {min_api}")
    if sorted(set(accept_missing)) != missing:
        raise PinError(f"cef_cmux.h at {ref[:12]} has API {api} and its history skips {missing or 'nothing'}; "
                       f"--accept-missing-api names {sorted(set(accept_missing)) or 'nothing'}. An app gate "
                       "`>= N` on a skipped number would pass without the feature: name exactly the skipped numbers")
    arts = assets_of(tag, parse_sums(sums))
    url = f"https://github.com/{repo}/releases/download/{tag}/"
    arm, x86 = arts["arm64"], arts["x86_64"]
    manifest = {"version": tag, "cef": match.group(1), "chromium": chromium.group(1), "arch": "arm64",
                "repo": repo, "tag": tag, "asset": arm["asset"], "url": url + arm["asset"],
                "sha256": arm["sha256"], "debug_asset": arm["debug_asset"], "debug_sha256": arm["debug_sha256"]}
    if debug_symbols:
        manifest["debug_symbols"] = debug_symbols
    if fork_branch:
        manifest["fork_branch"] = fork_branch
    manifest.update({"fork_ref": ref, "cmux_cef_api_version": api})
    if missing:
        manifest["missing_api"] = missing
    manifest["x86_64"] = {"asset": x86["asset"], "sha256": x86["sha256"], "url": url + x86["asset"],
                          "debug_asset": x86["debug_asset"], "debug_sha256": x86["debug_sha256"], "fork_ref": ref}
    if debug_symbols:
        manifest["x86_64"]["debug_symbols"] = debug_symbols
    manifest["require_dcheck_off"] = True
    return manifest


def artifacts(manifest: dict) -> list[tuple[str, dict]]:
    x86 = manifest.get("x86_64")
    return [("arm64", manifest)] + ([("x86_64", x86)] if isinstance(x86, dict) else [])


def check_manifest(manifest: dict, min_api: int) -> tuple[list[str], list[str]]:
    """Findings, and "<asset> <sha256> <r2 key>" lines of every pinned object."""
    findings, keys = [], []
    if not manifest.get("version") or manifest.get("version") != manifest.get("tag"):
        findings.append(f"version {manifest.get('version')!r} is not the release tag {manifest.get('tag')!r}")
    if "staging" in manifest:
        findings.append("it is a staging pin (a `staging` object): no R2 object stands behind it")
    if not manifest.get("r2_bucket"):
        findings.append("no r2_bucket")
    api = manifest.get("cmux_cef_api_version")
    if not isinstance(api, int) or api < min_api:
        findings.append(f"cmux_cef_api_version is {api!r}; the pin needs >= {min_api}")
    pinned = dict(artifacts(manifest))
    for arch in ARCHES:
        if arch not in pinned:
            findings.append(f"no {arch} artifact")
    for arch, art in pinned.items():
        for asset_field, sha_field, key_field in (("asset", "sha256", "r2_key"),
                                                  ("debug_asset", "debug_sha256", "debug_r2_key")):
            asset, sha, key = art.get(asset_field), art.get(sha_field), art.get(key_field)
            if not asset or not SHA_RE.fullmatch(sha or ""):
                findings.append(f"{arch} has no {asset_field} with a sha256 ({sha_field})")
                continue
            if key != f"cef/{sha}/{asset}":
                findings.append(f"{arch} {key_field} is {key!r}, not cef/{sha}/{asset}")
                continue
            keys.append(f"{asset} {sha} {key}")
    refs = {art.get("fork_ref") for art in pinned.values()}
    if len(refs) != 1 or not REF_RE.fullmatch(next(iter(refs)) or ""):
        findings.append(f"the arches do not name one fork commit (fork_ref {sorted(map(str, refs))})")
    return findings, keys


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    pin = sub.add_parser("pin")
    pin.add_argument("tag")
    pin.add_argument("--repo", default="manaflow-ai/cef")
    pin.add_argument("--min-api", type=int)
    pin.add_argument("--debug-symbols", help="the dSYM archive at the top of each arch's dist")
    pin.add_argument("--accept-missing-api", default="")
    pin.add_argument("--fork-branch")
    pin.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    pin.add_argument("--from", dest="source", type=Path)
    pin.add_argument("--ref")
    check = sub.add_parser("check")
    check.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    check.add_argument("--min-api", type=int)
    check.add_argument("--keys", action="store_true")
    args = parser.parse_args(argv)
    try:
        min_api = args.min_api if args.min_api is not None else app_min_api()
        if args.command == "pin":
            accept = [int(n) for n in args.accept_missing_api.split(",") if n.strip()]
            if args.source:
                if not args.ref:
                    raise PinError("--from needs --ref (the fork commit of the release)")
                inputs = tuple((args.source / name).read_text() for name in
                               ("SHA256SUMS", "cef_cmux.h", "CHROMIUM_BUILD_COMPATIBILITY.txt")) + (args.ref,)
            else:
                inputs = github_inputs(args.repo, args.tag)
            manifest = build_manifest(args.tag, args.repo, *inputs, min_api=min_api,
                                      accept_missing=accept, fork_branch=args.fork_branch,
                                      debug_symbols=args.debug_symbols)
            args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"==> pinned {args.tag} (fork API {manifest['cmux_cef_api_version']}, "
                  f"{manifest['fork_ref'][:12]}) in {args.manifest}; next: publish-cef-r2.sh {args.tag} "
                  f"--manifest {args.manifest}", file=sys.stderr)
            return 0
        manifest = json.loads(args.manifest.read_text())
        findings, keys = check_manifest(manifest, min_api)
        for finding in findings:
            print(f"FAIL {args.manifest}: {finding}", file=sys.stderr)
        if findings:
            return 1
        if args.keys:
            print("\n".join(keys))
        else:
            print(f"ok {args.manifest}: {manifest['version']} pins {len(keys)} objects at fork API "
                  f"{manifest['cmux_cef_api_version']}", file=sys.stderr)
        return 0
    except (PinError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
