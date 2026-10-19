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

    media_app_cache.py name  --tag TAG --sha SHA [--xcode BUILD]
    media_app_cache.py pack  --app APP --tag TAG --sha SHA --out TAR [--xcode BUILD]
    media_app_cache.py fetch --repo OWNER/REPO --tag TAG --sha SHA --dest DIR
                             [--xcode BUILD] [--github-output FILE]

fetch reads GH_TOKEN (actions: read) and exits 0 with the app path on a hit, 1
on a miss or any refusal; the tour then builds as before.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

MANIFEST = "media-app.json"
API = "https://api.github.com"


def xcode_build() -> str:
    out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout
    match = re.search(r"Build version (\S+)", out)
    if not match:
        raise RuntimeError(f"no Xcode build version in: {out!r}")
    return match.group(1)


def app_name(tag: str) -> str:
    return f"cmux DEV {tag}.app"


def artifact_name(tag: str, sha: str, xcode: str) -> str:
    for label, value in (("tag", tag), ("xcode", xcode)):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", value):
            raise ValueError(f"bad {label}: {value!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError(f"bad commit: {sha!r}")
    return f"cmux-media-app-{tag}-{sha}-xcode-{xcode}"


def pack(*, app: Path, tag: str, sha: str, xcode: str, out: Path) -> None:
    artifact_name(tag, sha, xcode)  # validates
    if app.name != app_name(tag) or not app.is_dir():
        raise ValueError(f"{app} is not the {tag} app")
    with tempfile.TemporaryDirectory() as tmp:
        manifest = Path(tmp) / MANIFEST
        manifest.write_text(json.dumps({"tag": tag, "sha": sha, "xcode": xcode, "app": app.name}) + "\n")
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

    def download(self, url: str, dest: Path) -> None:
        # The zip URL redirects to blob storage, which must not get the token.
        # curl drops the Authorization header on a redirect to another host.
        subprocess.run([
            "curl", "-fsSL", "--retry", "3", "--max-time", "900",
            "-H", f"Authorization: Bearer {self.token}",
            "-o", str(dest), url,
        ], check=True)


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


def fetch(*, repo: str, tag: str, sha: str, xcode: str, dest: Path, api, verify: bool = True) -> Path | None:
    name = artifact_name(tag, sha, xcode)
    try:
        candidates = [a for a in api.list_artifacts(repo, name) if a.get("name") == name and not a.get("expired")]
    except (urllib.error.URLError, OSError, ValueError) as err:
        print(f"app cache: cannot list {name}: {err}", file=sys.stderr)
        return None
    candidates.sort(key=lambda a: a.get("created_at") or "", reverse=True)
    if not candidates:
        print(f"app cache: no live artifact {name}")
        return None
    want = app_name(tag)
    dest.mkdir(parents=True, exist_ok=True)
    for art in candidates:
        scratch = Path(tempfile.mkdtemp(prefix=".media-app-", dir=dest))
        try:
            zipped = scratch / "app.zip"
            api.download(art["archive_download_url"], zipped)
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
            expect = {"tag": tag, "sha": sha, "xcode": xcode, "app": want}
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
        except (subprocess.CalledProcessError, OSError, ValueError, zipfile.BadZipFile, KeyError) as err:
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
        print(artifact_name(args.tag, args.sha, xcode))
        return 0
    if args.cmd == "pack":
        pack(app=args.app, tag=args.tag, sha=args.sha, xcode=xcode, out=args.out)
        return 0
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        print("app cache: no GH_TOKEN", file=sys.stderr)
        return 1
    app = fetch(repo=args.repo, tag=args.tag, sha=args.sha, xcode=xcode, dest=args.dest, api=GitHubApi(token))
    if app is None:
        return 1
    if args.github_output:
        with args.github_output.open("a") as out:
            out.write(f"app={app}\n")
    print(app)
    return 0


if __name__ == "__main__":
    sys.exit(main())
