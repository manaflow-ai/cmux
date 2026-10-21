#!/usr/bin/env python3
"""Share the cmux-next media tour's tagged apps between tours by commit.

A tour builds two tagged dev apps, the merge base's and the head's, about
6 min each. The merge base is usually a feat-cmux-next commit another tour
already built under the same tag (re-tours of a pull request, other pull
requests branched from the same commit, the merge tour that built it as its
head). `pack` turns a built app into a tar for a run artifact named by tag,
commit and Xcode build; `fetch` finds the newest live artifact of that name in
any run and puts the app where reload.sh would have: the tag's DerivedData
product dir. The tag is compiled into the app (bundle id, sockets, rpaths into
its DerivedData), so an app is only reused under the tag it was built with.
RECIPE is a short hash of how the tour builds (its build scripts and env), so
a pull request that changes that never hands its app to others.

Only an artifact uploaded by this repository's cmux-next-media.yml runs counts
(a fork's run could upload one under the same name), and its download must
match the artifact's digest. Debug Mach-Os search the DerivedData's
Build/Products/Debug/PackageFrameworks before the bundle's own Frameworks, so
an app beside package frameworks is never packed, and none is restored beside
them: the consumer's would come from another build.

    media_app_cache.py name  --tag TAG --sha SHA --recipe R [--xcode BUILD]
    media_app_cache.py pack  --app APP --tag TAG --sha SHA --recipe R --out TAR [--xcode BUILD]
    media_app_cache.py fetch --repo OWNER/REPO --tag TAG --sha SHA --recipe R --dest DIR
                             [--xcode BUILD] [--github-output FILE]

fetch reads GH_TOKEN (actions: read) and exits 0 with the app path on a hit, 1
on a miss or any refusal; the tour then builds as before.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

MANIFEST = "media-app.json"
API = "https://api.github.com"
WORKFLOW = ".github/workflows/cmux-next-media.yml"
# The newest two live artifacts are tried. Their downloads share one budget
# and curl never retries, so a slow blob store costs at most DOWNLOAD_SECONDS
# in all, less than the ~6 min build it replaces. A download is not started
# with under MIN_DOWNLOAD_SECONDS left (the zip is ~364 MB).
TRIES = 2
DOWNLOAD_SECONDS = 240
MIN_DOWNLOAD_SECONDS = 30


def xcode_build() -> str:
    out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout
    match = re.search(r"Build version (\S+)", out)
    if not match:
        raise RuntimeError(f"no Xcode build version in: {out!r}")
    return match.group(1)


def app_name(tag: str) -> str:
    return f"cmux DEV {tag}.app"


def artifact_name(tag: str, sha: str, xcode: str, recipe: str) -> str:
    for label, value in (("tag", tag), ("xcode", xcode), ("recipe", recipe)):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", value):
            raise ValueError(f"bad {label}: {value!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError(f"bad commit: {sha!r}")
    return f"cmux-media-app-{tag}-{sha}-xcode-{xcode}-{recipe}"


def package_frameworks(products: Path) -> list[str]:
    path = products / "PackageFrameworks"
    return sorted(p.name for p in path.iterdir()) if path.is_dir() else []


def pack(*, app: Path, tag: str, sha: str, xcode: str, recipe: str, out: Path) -> None:
    artifact_name(tag, sha, xcode, recipe)  # validates
    if app.name != app_name(tag) or not app.is_dir():
        raise ValueError(f"{app} is not the {tag} app")
    beside = package_frameworks(app.parent)
    if beside:
        raise ValueError(f"{app} loads package frameworks from its DerivedData ({', '.join(beside)}); not packed")
    with tempfile.TemporaryDirectory() as tmp:
        manifest = Path(tmp) / MANIFEST
        manifest.write_text(json.dumps({"tag": tag, "sha": sha, "xcode": xcode, "recipe": recipe,
                                        "app": app.name}) + "\n")
        out.parent.mkdir(parents=True, exist_ok=True)
        # System tar keeps the bundle's framework symlinks, modes and xattrs;
        # upload-artifact alone would follow the symlinks and break the signature.
        subprocess.run(["tar", "-cf", str(out), "-C", tmp, MANIFEST], check=True)
        subprocess.run(["tar", "-rf", str(out), "-C", str(app.parent), app.name], check=True)


class GitHubApi:
    def __init__(self, token: str) -> None:
        self.token = token

    def _get(self, url: str) -> bytes:
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()

    def list_artifacts(self, repo: str, name: str) -> list[dict]:
        query = urllib.parse.urlencode({"name": name, "per_page": 10})
        data = json.loads(self._get(f"{API}/repos/{repo}/actions/artifacts?{query}"))
        return list(data.get("artifacts") or [])

    def run(self, repo: str, run_id: int) -> dict:
        return json.loads(self._get(f"{API}/repos/{repo}/actions/runs/{int(run_id)}"))

    def download(self, url: str, dest: Path, seconds: int) -> None:
        # The zip URL redirects to blob storage, which must not get the token:
        # curl drops the Authorization header on a redirect to another host.
        # The header goes in on stdin, not argv, where other jobs could read it.
        subprocess.run(
            ["curl", "-fsSL", "--retry", "0", "--max-time", str(int(seconds)), "-K", "-", "-o", str(dest), url],
            input=f'header = "Authorization: Bearer {self.token}"\n', text=True, check=True,
        )


def _members(tar: Path) -> list[str]:
    out = subprocess.run(["tar", "-tf", str(tar)], capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


def _safe(members: list[str], app: str) -> bool:
    for member in members:
        parts = Path(member).parts
        if member.startswith("/") or ".." in parts:
            return False
        if member != MANIFEST and (not parts or parts[0] != app):
            return False
    return True


def trusted(api, repo: str, art: dict) -> str:
    """Why this artifact is not the tour's own upload, or "" when it is."""
    run = art.get("workflow_run") or {}
    if not run.get("id") or run.get("head_repository_id") != run.get("repository_id"):
        return "it was not uploaded by a run of this repository's own branches"
    path = (api.run(repo, run["id"]) or {}).get("path") or ""
    if path.split("@", 1)[0] != WORKFLOW:
        return f"it was uploaded by {path or 'an unknown workflow'}, not {WORKFLOW}"
    return ""


def fetch(*, repo: str, tag: str, sha: str, xcode: str, recipe: str, dest: Path, api,
          verify: bool = True, clock=time.monotonic) -> Path | None:
    name = artifact_name(tag, sha, xcode, recipe)
    try:
        candidates = [a for a in api.list_artifacts(repo, name) if a.get("name") == name and not a.get("expired")]
    except (urllib.error.URLError, OSError, ValueError) as err:
        print(f"app cache: cannot list {name}: {err}", file=sys.stderr)
        return None
    # A fork run could upload under this name too; drop those before taking
    # the newest TRIES, so they can't push the tour's own upload out.
    candidates = [a for a in candidates if (a.get("workflow_run") or {}).get("head_repository_id")
                  == (a.get("workflow_run") or {}).get("repository_id")]
    candidates.sort(key=lambda a: a.get("created_at") or "", reverse=True)
    if not candidates:
        print(f"app cache: no live artifact {name}")
        return None
    want = app_name(tag)
    beside = package_frameworks(dest)
    if beside:
        print(f"app cache: {dest} has package frameworks from another build ({', '.join(beside)}); building instead")
        return None
    dest.mkdir(parents=True, exist_ok=True)
    deadline = clock() + DOWNLOAD_SECONDS
    for art in candidates[:TRIES]:
        if int(deadline - clock()) < MIN_DOWNLOAD_SECONDS:
            print(f"app cache: under {MIN_DOWNLOAD_SECONDS}s of the {DOWNLOAD_SECONDS}s download budget left; building instead")
            break
        scratch = Path(tempfile.mkdtemp(prefix=".media-app-", dir=dest))
        try:
            why = trusted(api, repo, art)
            if why:
                print(f"app cache: artifact {art.get('id')} refused: {why}", file=sys.stderr)
                continue
            zipped = scratch / "app.zip"
            left = int(deadline - clock())
            if left < MIN_DOWNLOAD_SECONDS:
                print(f"app cache: {left}s of the {DOWNLOAD_SECONDS}s download budget left; building instead")
                break
            api.download(art["archive_download_url"], zipped, left)
            digest = str(art.get("digest") or "")
            hasher = hashlib.sha256()
            with zipped.open("rb") as blob:
                for chunk in iter(lambda: blob.read(1 << 20), b""):
                    hasher.update(chunk)
            got_digest = "sha256:" + hasher.hexdigest()
            if digest != got_digest:
                print(f"app cache: artifact {art.get('id')} download {got_digest} does not match {digest or 'no digest'}; refused",
                      file=sys.stderr)
                continue
            with zipfile.ZipFile(zipped) as zf:
                tars = [n for n in zf.namelist() if n.endswith(".tar") and "/" not in n]
                if len(tars) != 1:
                    print(f"app cache: artifact {art.get('id')} holds {zf.namelist()}, not one tar", file=sys.stderr)
                    continue
                zf.extract(tars[0], scratch)
            tar = scratch / tars[0]
            zipped.unlink()
            if not _safe(_members(tar), want):
                print(f"app cache: artifact {art.get('id')} has paths outside {want}; refused", file=sys.stderr)
                continue
            out = scratch / "x"
            out.mkdir()
            subprocess.run(["tar", "-xpf", str(tar), "-C", str(out)], check=True)
            manifest = json.loads((out / MANIFEST).read_text())
            expect = {"tag": tag, "sha": sha, "xcode": xcode, "recipe": recipe, "app": want}
            if any(manifest.get(k) != v for k, v in expect.items()):
                print(f"app cache: artifact {art.get('id')} was packed for {manifest}; refused", file=sys.stderr)
                continue
            got = out / want
            if not (got / "Contents").is_dir():
                print(f"app cache: artifact {art.get('id')} has no {want}", file=sys.stderr)
                continue
            if verify and shutil.which("codesign"):
                check = subprocess.run(["codesign", "--verify", "--strict", str(got)], capture_output=True, text=True)
                if check.returncode != 0:
                    print(f"app cache: {want} from artifact {art.get('id')} fails codesign: {check.stderr.strip()}", file=sys.stderr)
                    continue
            final = dest / want
            if final.exists() or final.is_symlink():
                shutil.rmtree(final) if final.is_dir() and not final.is_symlink() else final.unlink()
            got.rename(final)
            print(f"app cache: {want} for {sha} from artifact {art.get('id')} ({art.get('created_at')})")
            return final
        except (subprocess.CalledProcessError, OSError, ValueError, zipfile.BadZipFile, KeyError,
                urllib.error.URLError) as err:
            print(f"app cache: artifact {art.get('id')} unusable: {err}", file=sys.stderr)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for cmd in ("name", "pack", "fetch"):
        p = sub.add_parser(cmd)
        p.add_argument("--tag", required=True)
        p.add_argument("--sha", required=True)
        p.add_argument("--recipe", required=True, help="short hash of the tour's build recipe")
        p.add_argument("--xcode", help="Xcode build version (default: xcodebuild -version)")
        if cmd == "pack":
            p.add_argument("--app", type=Path, required=True)
            p.add_argument("--out", type=Path, required=True)
        if cmd == "fetch":
            p.add_argument("--repo", required=True)
            p.add_argument("--dest", type=Path, required=True)
            p.add_argument("--github-output", type=Path)
    args = parser.parse_args(argv)
    xcode = args.xcode or xcode_build()
    if args.cmd == "name":
        print(artifact_name(args.tag, args.sha, xcode, args.recipe))
        return 0
    if args.cmd == "pack":
        pack(app=args.app, tag=args.tag, sha=args.sha, xcode=xcode, recipe=args.recipe, out=args.out)
        return 0
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        print("app cache: no GH_TOKEN", file=sys.stderr)
        return 1
    app = fetch(repo=args.repo, tag=args.tag, sha=args.sha, xcode=xcode, recipe=args.recipe, dest=args.dest,
                api=GitHubApi(token))
    if app is None:
        return 1
    if args.github_output:
        with args.github_output.open("a") as out:
            out.write(f"app={app}\n")
    print(app)
    return 0


if __name__ == "__main__":
    sys.exit(main())
