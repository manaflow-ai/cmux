#!/usr/bin/env python3
"""The signed apt and yum archive of cmux for Linux hosts (cmuxterm-hq docs/design/linux-signed-packages.md
section 5, phase 4; Leo's decision d-fce10e3659: an OpenPGP archive key whose certify-only primary stays
offline, with only an expiring signing subkey in CI).

Every step reads the build's signed Linux release file (cmux-tui/<commit>/release.json, verified with
web-ota-pointer.py and web-update-keys.json), so a package holds exactly the bytes that file names and the
repository indexes cannot disagree with it.

  nfpm-config --release R --keys K --target T --binaries-dir D --out YAML
      check every binary of target T in D against R's sha256 and size, then write the nfpm config of the
      `cmux` package: /usr/bin/cmux, /usr/bin/cmux-tui-hook, /usr/bin/acpmux, /usr/bin/cmux-app-host and
      /usr/bin/cmux-agent-screen-detection (each one R names) and a cmux-host systemd unit, disabled.
  apt-repo --debs DIR --channel C --out ROOT --key-id FPR [--valid-days 7] [--now T]
      pool/<file>.deb plus dists/C/{Release,InRelease,Release.gpg} and main/binary-<arch>/Packages(.gz).
      Release carries Valid-Until (publish time plus --valid-days) inside the signed part: apt refuses an
      expired index, so a replayed old one stops working.
  rpm-repo --rpms DIR --channel C --out ROOT --key-id FPR
      <channel>/<file>.rpm and repodata/ (createrepo_c) with repomd.xml.asc, the detached signature.

Signing runs gpg with the GNUPGHOME it is given; --key-id names the signing subkey (FPR! form is used, so
gpg signs with that subkey and never the primary, which CI does not hold).
"""
import argparse
import datetime
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
POINTER = os.path.join(ROOT, "scripts", "cmux-next", "web-ota-pointer.py")
LINUX_RELEASE = "cmux-linux-release"
# Release file name -> installed path. A name the release file does not list for the target is left out.
INSTALLED = {
    "cmux-tui": "/usr/bin/cmux",
    "cmux-tui-hook": "/usr/bin/cmux-tui-hook",
    "cmux-tui-acpmux": "/usr/bin/acpmux",
    "cmux-tui-app-host": "/usr/bin/cmux-app-host",
    "cmux-tui-agent-screen-detection": "/usr/bin/cmux-agent-screen-detection",
}
# Packages are built from the static (musl) binaries, which run on any distribution.
TARGETS = {"x86_64-unknown-linux-musl": ("amd64", "x86_64"), "aarch64-unknown-linux-musl": ("arm64", "aarch64")}
UNIT = """[Unit]
Description=cmux host daemon
Documentation=https://cmux.com
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cmux host run
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
"""
UNIT_PATH = "/usr/lib/systemd/system/cmux-host.service"
VALID_DAYS = 7


def fail(message):
    print(f"linux-archive: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verified_release(path, keys):
    result = subprocess.run([sys.executable, POINTER, "verify", "--pointer", path, "--keys", keys,
                             "--purpose", LINUX_RELEASE, "--allow-expired"], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{path} is not a verified Linux release file: {result.stderr.strip()}")
    return json.loads(result.stdout)


def package_version(version):
    """The release version (`<cargo>+<stamp>.<commit12>`) as dpkg and rpm both read it."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\+[0-9]{14}\.[0-9a-f]{12}", version or ""):
        fail(f"bad release version {version!r}")
    return version


def nfpm_config(args):
    release = verified_release(args.release, args.keys)
    if args.target not in TARGETS:
        fail(f"no package for {args.target}; packages are built for {', '.join(TARGETS)}")
    binaries = release["targets"].get(args.target)
    if not binaries:
        fail(f"{args.release} names no binaries for {args.target}")
    deb_arch, _ = TARGETS[args.target]
    contents = []
    for name, entry in sorted(binaries.items()):
        if name not in INSTALLED:
            fail(f"{args.release} names {name}, which the package does not know where to install")
        local = os.path.join(args.binaries_dir, os.path.basename(entry["url"]))
        if not os.path.isfile(local):
            fail(f"{local} is missing: the package holds every binary the release file names")
        if os.path.getsize(local) != entry["size"] or sha256(local) != entry["sha256"]:
            fail(f"{local} is not the {name} the release file names (size or sha256 differ)")
        contents.append({"src": os.path.abspath(local), "dst": INSTALLED[name], "file_info": {"mode": 0o755}})
    if "cmux-tui" not in binaries:
        fail(f"{args.release} names no cmux-tui for {args.target}")
    unit = os.path.join(os.path.dirname(os.path.abspath(args.out)), "cmux-host.service")
    with open(unit, "w") as f:
        f.write(UNIT)
    contents.append({"src": unit, "dst": UNIT_PATH, "type": "config", "file_info": {"mode": 0o644}})
    config = {
        "name": "cmux", "arch": deb_arch, "platform": "linux", "version": package_version(release["version"]),
        "version_schema": "none", "maintainer": "Manaflow <support@cmux.com>", "homepage": "https://cmux.com",
        "description": "cmux: the terminal daemon and agent host (cmux host run, disabled until enabled)",
        "license": "Proprietary", "contents": contents,
        # The commit time as every file's mtime: a rerun builds the same bytes, so the write-once upload
        # of cmux-tui/<commit>/<package> accepts it.
        "mtime": datetime.datetime.fromtimestamp(release["committed_at"], datetime.timezone.utc)
                 .strftime("%Y-%m-%dT%H:%M:%SZ"),
        # nfpm maps arch to each format (amd64 -> x86_64 for rpm). No scripts: installing the package
        # starts nothing; `systemctl enable --now cmux-host` (or the Cloud bake) turns the daemon on.
    }
    # JSON is YAML, so nfpm reads this file as is.
    with open(args.out, "w") as f:
        json.dump(config, f, indent=1, sort_keys=True)
        f.write("\n")


def gpg_sign(key_id, mode, src, dst):
    """gpg --clearsign or --detach-sign with exactly the subkey `key_id` (the `!` suffix)."""
    argv = ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--local-user", f"{key_id}!",
            "--digest-algo", "SHA512", "--output", dst]
    argv += {"clear": ["--clearsign"], "detach": ["--detach-sign"], "armor": ["--armor", "--detach-sign"]}[mode]
    result = subprocess.run(argv + [src], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"gpg could not sign {src} with {key_id}: {result.stderr.strip()}")


def deb_fields(path):
    result = subprocess.run(["dpkg-deb", "-f", path], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{path} is not a .deb: {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def apt_repo(args):
    now = int(args.now) if args.now else int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    dist = os.path.join(args.out, "dists", args.channel)
    pool = os.path.join(args.out, "pool", args.channel)
    os.makedirs(pool, exist_ok=True)
    by_arch = {}
    for name in sorted(os.listdir(args.debs)):
        if not name.endswith(".deb"):
            continue
        src = os.path.join(args.debs, name)
        fields = deb_fields(src)
        arch = re.search(r"^Architecture: (\S+)$", fields, re.M)
        if not arch:
            fail(f"{src} has no Architecture")
        shutil.copyfile(src, os.path.join(pool, name))
        stanza = (f"{fields}\nFilename: pool/{args.channel}/{name}\nSize: {os.path.getsize(src)}\n"
                  f"SHA256: {sha256(src)}\n")
        by_arch.setdefault(arch.group(1), []).append(stanza)
    if not by_arch:
        fail(f"no .deb in {args.debs}")
    listed = []
    for arch, stanzas in sorted(by_arch.items()):
        rel = f"main/binary-{arch}/Packages"
        os.makedirs(os.path.join(dist, os.path.dirname(rel)), exist_ok=True)
        data = "\n".join(stanzas).encode()
        with open(os.path.join(dist, rel), "wb") as f:
            f.write(data)
        with open(os.path.join(dist, rel + ".gz"), "wb") as f:
            f.write(gzip.compress(data, mtime=0))
        listed += [rel, rel + ".gz"]
    when = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S UTC")
    lines = [f"Origin: cmux", f"Label: cmux", f"Suite: {args.channel}", f"Codename: {args.channel}",
             f"Date: {when(now)}", f"Valid-Until: {when(now + args.valid_days * 86400)}",
             f"Architectures: {' '.join(sorted(by_arch))}", "Components: main", "Acquire-By-Hash: no", "SHA256:"]
    for rel in listed:
        path = os.path.join(dist, rel)
        lines.append(f" {sha256(path)} {os.path.getsize(path):>16} {rel}")
    release = os.path.join(dist, "Release")
    with open(release, "w") as f:
        f.write("\n".join(lines) + "\n")
    gpg_sign(args.key_id, "clear", release, os.path.join(dist, "InRelease"))
    gpg_sign(args.key_id, "detach", release, os.path.join(dist, "Release.gpg"))


def rpm_repo(args):
    repo = os.path.join(args.out, args.channel)
    os.makedirs(repo, exist_ok=True)
    rpms = [n for n in sorted(os.listdir(args.rpms)) if n.endswith(".rpm")]
    if not rpms:
        fail(f"no .rpm in {args.rpms}")
    for name in rpms:
        shutil.copyfile(os.path.join(args.rpms, name), os.path.join(repo, name))
    if shutil.which("createrepo_c") is None:
        fail("createrepo_c is required (apt-get install createrepo-c)")
    result = subprocess.run(["createrepo_c", "--simple-md-filenames", "--no-database", repo],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"createrepo_c failed: {result.stderr.strip()}")
    repomd = os.path.join(repo, "repodata", "repomd.xml")
    gpg_sign(args.key_id, "armor", repomd, repomd + ".asc")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    n = sub.add_parser("nfpm-config")
    for name in ("--release", "--keys", "--target", "--binaries-dir", "--out"):
        n.add_argument(name, required=True)
    a = sub.add_parser("apt-repo")
    for name in ("--debs", "--channel", "--out", "--key-id"):
        a.add_argument(name, required=True)
    a.add_argument("--valid-days", type=int, default=VALID_DAYS)
    a.add_argument("--now", help="unix seconds (tests)")
    r = sub.add_parser("rpm-repo")
    for name in ("--rpms", "--channel", "--out", "--key-id"):
        r.add_argument(name, required=True)
    args = parser.parse_args(argv[1:])
    if getattr(args, "channel", None) is not None and not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.channel):
        fail(f"bad channel {args.channel!r}")
    {"nfpm-config": nfpm_config, "apt-repo": apt_repo, "rpm-repo": rpm_repo}[args.command](args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
