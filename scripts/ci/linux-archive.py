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
  appdir --release R --keys K --target T --binaries-dir D --icon PNG --out DIR
      the AppDir of the cmux AppImage: the same checked binaries under usr/bin (named as the package
      installs them), AppRun, cmux.desktop and the icon, every mtime the commit time.
  appimage --appdir DIR --runtime RT --runtime-sha256 X --update-info U --out FILE
      the AppImage: the pinned static type2 runtime (no libfuse needed), U written into its .upd_info
      section (the zsync URL AppImageUpdate follows), then a reproducible squashfs of DIR.
  appimage-verify --appimage F --release R --keys K --target T
      read F's squashfs back and check that usr/bin holds exactly the binaries R names for T.

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


def target_binaries(release, release_path, target):
    """The release file's binaries for `target`, each one a name the package knows where to install."""
    if target not in TARGETS:
        fail(f"no package for {target}; packages are built for {', '.join(TARGETS)}")
    binaries = release["targets"].get(target)
    if not binaries:
        fail(f"{release_path} names no binaries for {target}")
    for name in binaries:
        if name not in INSTALLED:
            fail(f"{release_path} names {name}, which the package does not know where to install")
    if "cmux-tui" not in binaries:
        fail(f"{release_path} names no cmux-tui for {target}")
    return binaries


def checked_binaries(args, release):
    """(name, local path) for every binary of the target, each checked against the release file."""
    found = []
    for name, entry in sorted(target_binaries(release, args.release, args.target).items()):
        local = os.path.join(args.binaries_dir, os.path.basename(entry["url"]))
        if not os.path.isfile(local):
            fail(f"{local} is missing: the package holds every binary the release file names")
        if os.path.getsize(local) != entry["size"] or sha256(local) != entry["sha256"]:
            fail(f"{local} is not the {name} the release file names (size or sha256 differ)")
        found.append((name, local))
    return found


def nfpm_config(args):
    release = verified_release(args.release, args.keys)
    contents = []
    for name, local in checked_binaries(args, release):
        contents.append({"src": os.path.abspath(local), "dst": INSTALLED[name], "file_info": {"mode": 0o755}})
    deb_arch, _ = TARGETS[args.target]
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


# The AppImage (a single file a person downloads and runs; the GUI package takes the same path once cmux-fp
# builds). Its AppRun copies the binaries out to one fixed per-user folder before running them: the AppImage's
# own mount ends when it exits, and `cmux host enable` or `cmux server install` write services that name the
# binary's path, so a path inside the mount would stop working at the first exit.
APPRUN = """#!/bin/sh
# cmux AppImage entry (scripts/ci/linux-archive.py appdir). Running cmux-<version>-<arch>.AppImage installs
# that version's binaries to ${XDG_DATA_HOME:-~/.local/share}/cmux/appimage/bin (each one replaced by rename,
# so a running daemon keeps its file) and runs cmux from there. Named acpmux, cmux-tui-hook, cmux-app-host or
# cmux-agent-screen-detection (a symlink to the AppImage), it runs that binary instead.
set -eu
here=$(dirname "$(readlink -f "$0")")
version=$(cat "$here/cmux-version")
bin="${XDG_DATA_HOME:-$HOME/.local/share}/cmux/appimage/bin"
if [ "$(cat "$bin/.version" 2>/dev/null || true)" != "$version" ]; then
  mkdir -p "$bin"
  for f in "$here"/usr/bin/*; do
    n=$(basename "$f")
    cp "$f" "$bin/.$n.$$" && chmod 755 "$bin/.$n.$$" && mv -f "$bin/.$n.$$" "$bin/$n"
  done
  printf '%s\\n' "$version" > "$bin/.version.$$" && mv -f "$bin/.version.$$" "$bin/.version"
fi
name=$(basename "${ARGV0:-$0}")
name=${name%.AppImage}
case "$name" in
  acpmux|cmux-tui-hook|cmux-app-host|cmux-agent-screen-detection) ;;
  *) name=cmux ;;
esac
exec "$bin/$name" "$@"
"""
DESKTOP = """[Desktop Entry]
Type=Application
Name=cmux
Comment=The terminal daemon and agent host
Exec=cmux
Icon=cmux
Terminal=true
Categories=Development;System;
X-AppImage-Version={version}
"""
UPDATE_INFO = re.compile(r"zsync\|https://files\.cmux\.com/[A-Za-z0-9._/-]+\.zsync")


def set_mtimes(root, when):
    for top, dirs, files in os.walk(root):
        for name in dirs + files:
            os.utime(os.path.join(top, name), (when, when), follow_symlinks=False)
    os.utime(root, (when, when))


def appdir(args):
    release = verified_release(args.release, args.keys)
    version = package_version(release["version"])
    if os.path.exists(args.out):
        fail(f"{args.out} exists; the AppDir is made fresh")
    os.makedirs(os.path.join(args.out, "usr", "bin"))
    for name, local in checked_binaries(args, release):
        dst = os.path.join(args.out, "usr", "bin", os.path.basename(INSTALLED[name]))
        shutil.copyfile(local, dst)
        os.chmod(dst, 0o755)
    files = {"AppRun": (APPRUN, 0o755), "cmux.desktop": (DESKTOP.format(version=version), 0o644),
             "cmux-version": (version + "\n", 0o644)}
    for name, (text, mode) in files.items():
        path = os.path.join(args.out, name)
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, mode)
    with open(args.icon, "rb") as f:
        icon = f.read()
    if not icon.startswith(b"\x89PNG\r\n\x1a\n"):
        fail(f"{args.icon} is not a PNG")
    with open(os.path.join(args.out, "cmux.png"), "wb") as f:
        f.write(icon)
    os.symlink("cmux.png", os.path.join(args.out, ".DirIcon"))
    set_mtimes(args.out, release["committed_at"])


def elf_section(data, wanted):
    """(offset, size) of the ELF64 little-endian section named `wanted`."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        fail("the runtime is not a 64-bit little-endian ELF file")
    shoff = int.from_bytes(data[0x28:0x30], "little")
    shentsize, shnum, shstrndx = (int.from_bytes(data[i:i + 2], "little") for i in (0x3A, 0x3C, 0x3E))
    def header(i):
        h = data[shoff + i * shentsize: shoff + (i + 1) * shentsize]
        return (int.from_bytes(h[0:4], "little"), int.from_bytes(h[24:32], "little"),
                int.from_bytes(h[32:40], "little"))
    _, names_at, _ = header(shstrndx)
    for i in range(shnum):
        name_at, offset, size = header(i)
        start = names_at + name_at
        if data[start:data.index(b"\0", start)] == wanted.encode():
            return offset, size
    fail(f"the runtime has no {wanted} section")


def appimage(args):
    if not UPDATE_INFO.fullmatch(args.update_info):
        fail(f"bad update information {args.update_info!r} (zsync|https://files.cmux.com/...zsync)")
    if shutil.which("mksquashfs") is None:
        fail("mksquashfs is required (apt-get install squashfs-tools)")
    with open(args.runtime, "rb") as f:
        runtime = bytearray(f.read())
    if hashlib.sha256(runtime).hexdigest() != args.runtime_sha256:
        fail(f"{args.runtime} is not the pinned runtime (sha256 differs)")
    offset, size = elf_section(runtime, ".upd_info")
    info = args.update_info.encode()
    if len(info) >= size:
        fail(f"the update information is longer than the runtime's .upd_info ({size} bytes)")
    runtime[offset:offset + size] = info + b"\0" * (size - len(info))
    when = str(int(os.stat(os.path.join(args.appdir, "cmux-version")).st_mtime))
    squashfs = args.out + ".squashfs"
    if os.path.exists(squashfs):
        os.remove(squashfs)
    # Reproducible: fixed times, root-owned, no xattrs, sorted entries; zstd, which the type2 runtime reads.
    result = subprocess.run(["mksquashfs", args.appdir, squashfs, "-noappend", "-all-root", "-no-xattrs",
                             "-comp", "zstd", "-Xcompression-level", "15", "-b", "1M", "-mkfs-time", when,
                             "-all-time", when, "-quiet", "-no-progress"], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"mksquashfs failed: {result.stderr.strip()}")
    tmp = args.out + ".tmp"
    with open(tmp, "wb") as out, open(squashfs, "rb") as fs:
        out.write(runtime)
        shutil.copyfileobj(fs, out, 1 << 20)
    os.remove(squashfs)
    os.chmod(tmp, 0o755)
    os.replace(tmp, args.out)


def appimage_verify(args):
    release = verified_release(args.release, args.keys)
    binaries = target_binaries(release, args.release, args.target)
    with open(args.appimage, "rb") as f:
        head = f.read(1 << 22)
    # The squashfs starts where the runtime ELF ends: after its section header table.
    shoff = int.from_bytes(head[0x28:0x30], "little")
    shentsize, shnum = (int.from_bytes(head[i:i + 2], "little") for i in (0x3A, 0x3C))
    offset = shoff + shentsize * shnum
    if head[offset:offset + 4] != b"hsqs":
        fail(f"{args.appimage} has no squashfs after its runtime (at {offset})")
    if shutil.which("unsquashfs") is None:
        fail("unsquashfs is required (apt-get install squashfs-tools)")
    out = args.appimage + ".verify"
    shutil.rmtree(out, ignore_errors=True)
    try:
        result = subprocess.run(["unsquashfs", "-o", str(offset), "-d", out, "-no-progress", "-quiet",
                                 args.appimage, "usr/bin"], capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"unsquashfs could not read {args.appimage}: {result.stderr.strip()}")
        bin_dir = os.path.join(out, "usr", "bin")
        held = sorted(os.listdir(bin_dir))
        want = sorted(os.path.basename(INSTALLED[name]) for name in binaries)
        if held != want:
            fail(f"{args.appimage} holds {held}, not the binaries the release file names ({want})")
        for name, entry in binaries.items():
            path = os.path.join(bin_dir, os.path.basename(INSTALLED[name]))
            if os.path.getsize(path) != entry["size"] or sha256(path) != entry["sha256"]:
                fail(f"{args.appimage}'s {INSTALLED[name]} is not the {name} the release file names")
    finally:
        shutil.rmtree(out, ignore_errors=True)
    print(f"{args.appimage}: {len(binaries)} binaries match {args.release} for {args.target}")


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
    d = sub.add_parser("appdir")
    for name in ("--release", "--keys", "--target", "--binaries-dir", "--icon", "--out"):
        d.add_argument(name, required=True)
    i = sub.add_parser("appimage")
    for name in ("--appdir", "--runtime", "--runtime-sha256", "--update-info", "--out"):
        i.add_argument(name, required=True)
    v = sub.add_parser("appimage-verify")
    for name in ("--appimage", "--release", "--keys", "--target"):
        v.add_argument(name, required=True)
    args = parser.parse_args(argv[1:])
    if getattr(args, "channel", None) is not None and not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.channel):
        fail(f"bad channel {args.channel!r}")
    {"nfpm-config": nfpm_config, "apt-repo": apt_repo, "rpm-repo": rpm_repo, "appdir": appdir,
     "appimage": appimage, "appimage-verify": appimage_verify}[args.command](args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
