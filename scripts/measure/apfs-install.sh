#!/usr/bin/env bash
# APFS-compressed install experiment (CMUX-570, bundle-size-falls): does a transparently compressed
# cmux NEXT install keep its signature, survive the ways people install it, and what does it cost
# at start? Downloads the newest NIGHTLY arm64 DMG from the appcast, launches nothing but
# `Contents/Resources/bin/cmux --version`, and writes artifacts/apfs-install.txt (the same lines
# as the log). Experiment only: everything lives in a mktemp dir removed at exit.
#
#   cmux-ci run --class exclusive --label measure --script scripts/measure/apfs-install.sh --ref <sha> \
#     --artifact artifacts/apfs-install.txt [--arg=dmg=URL]
set -uo pipefail

feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
dmg=""
runs=10
for a in "$@"; do
  case "$a" in
    dmg=*) dmg="${a#dmg=}" ;;
    runs=*) runs="${a#runs=}" ;;
    *) echo "apfs-install: unknown argument $a" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
mkdir -p "$root/artifacts"
report="$root/artifacts/apfs-install.txt"
: >"$report"
w="$(mktemp -d "${TMPDIR:-/tmp}/apfs-install.XXXXXX")"
mounts=""
cleanup() {
  for m in $mounts; do hdiutil detach -force "$m" >/dev/null 2>&1 || true; done
  rm -rf "$w"
}
trap cleanup EXIT

say() { echo "APFS $*" | tee -a "$report"; }
run() { say "\$ $*"; "$@" 2>&1 | sed 's/^/    /' | tee -a "$report"; return "${PIPESTATUS[0]}"; }

# A tiny C probe: per bundle, apparent bytes, allocated bytes, files, compressed files and the
# decmpfs compression types seen (3/4 zlib, 7/8 lzvn, 11/12 lzfse; odd = inline in the xattr).
cat >"$w/probe.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fts.h>
#include <sys/stat.h>
#include <sys/xattr.h>
int main(int argc, char **argv) {
  char *paths[] = {argv[1], NULL};
  FTS *f = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
  long long app = 0, alloc = 0, files = 0, comp = 0, types[32] = {0};
  FTSENT *e;
  while ((e = fts_read(f))) {
    if (e->fts_info != FTS_F) continue;
    struct stat *s = e->fts_statp;
    files++; app += s->st_size; alloc += (long long)s->st_blocks * 512;
    if (s->st_flags & UF_COMPRESSED) {
      comp++;
      unsigned char h[16];
      ssize_t n = getxattr(e->fts_path, "com.apple.decmpfs", h, sizeof h, 0, XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION);
      if (n >= 8 && memcmp(h, "fpmc", 4) == 0) {
        unsigned t = h[4] | h[5] << 8 | h[6] << 16 | (unsigned)h[7] << 24;
        types[t < 32 ? t : 31]++;
      } else types[0]++;
    }
  }
  printf("apparent=%lld allocated=%lld files=%lld compressed=%lld", app, alloc, files, comp);
  for (int i = 0; i < 32; i++) if (types[i]) printf(" type%d=%lld", i, types[i]);
  printf("\n");
  return 0;
}
C
cc -O2 -o "$w/probe" "$w/probe.c" || { echo "APFS probe compile failed"; exit 3; }

measure() { # LABEL APP
  local label="$1" app="$2" du cs sp
  du="$(du -sk "$app" | awk '{print $1}')"
  if codesign --verify --deep --strict "$app" >"$w/cs.txt" 2>&1; then cs=ok; else cs="FAIL($(tr '\n' ' ' <"$w/cs.txt" | cut -c1-300))"; fi
  sp="$(spctl -a -vv -t exec "$app" 2>&1 | tr '\n' ' ' | cut -c1-300)"
  say "ROW $label du_k=$du $("$w/probe" "$app") codesign=$cs spctl=[$sp]"
}

flags() { # APP: ls -lO of the biggest files
  local app="$1"
  say "ls -lO $app (biggest files)"
  for rel in "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework" \
             "Contents/Resources/bin/cmux" "Contents/MacOS/cmux NIGHTLY"; do
    [[ -e "$app/$rel" ]] && ls -lO "$app/$rel" 2>&1 | sed 's/^/    /' | tee -a "$report"
  done
}

say "host $(hostname -s) macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) arch $(uname -m)"
run df -h "$w"
run diskutil info "$(df "$w" | awk 'NR==2{print $1}')" | grep -E 'File System Personality|Type \(Bundle\)|Solid State' || true
say "ditto offers: $(man ditto 2>/dev/null | col -b | grep -iE -- '--(no)?(hfs|preserveHFS)Compression' | tr -s ' ' | tr '\n' ';')"
say "tools: afsctool=$(command -v afsctool || echo none) compression_tool=$(command -v compression_tool || echo none)"

# The DMG: newest NIGHTLY arm64 enclosure of the appcast, as scripts/cmux-next/fetch-nightly-dmg.py picks it.
if [[ -z "$dmg" ]]; then
  curl -fsSL --retry 3 -o "$w/appcast.xml" "$feed" || { say "appcast download failed"; exit 3; }
  cat >"$w/newest.py" <<'PY'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
best = None
for item in ET.parse(sys.argv[1]).iter("item"):
    enc = item.find("enclosure")
    if enc is None: continue
    ver = enc.get(S + "version") or (item.findtext(S + "version") or "0")
    try: v = int(ver)
    except ValueError: continue
    if best is None or v > best[0]: best = (v, enc.get("url"))
print(best[1])
PY
  dmg="$(python3 -I "$w/newest.py" "$w/appcast.xml")"
fi
say "dmg $dmg"
curl -fsSL --retry 3 --retry-all-errors -o "$w/in.dmg" "$dmg" || { say "DMG download failed"; exit 3; }
say "dmg_bytes $(stat -f %z "$w/in.dmg")"
mkdir -p "$w/m0"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$w/m0" "$w/in.dmg" >/dev/null || { say "mount failed"; exit 3; }
mounts="$w/m0"
src="$(find "$w/m0" -maxdepth 1 -name '*.app' -type d | head -1)"
name="$(basename "$src")"
say "app $name"
measure "published-dmg-volume" "$src"

# 1. Baseline: ditto, no flags.
mkdir -p "$w/base"
t0=$(python3 -c 'import time;print(time.time())')
ditto "$src" "$w/base/$name"
say "ditto(no flags) seconds $(python3 -c "import time;print(round(time.time()-$t0,2))")"
measure "1-ditto-plain" "$w/base/$name"
run stapler validate "$w/base/$name" || true

# 2. ditto --hfsCompression.
mkdir -p "$w/comp"
t0=$(python3 -c 'import time;print(time.time())')
ditto --hfsCompression "$src" "$w/comp/$name"
say "ditto --hfsCompression seconds $(python3 -c "import time;print(round(time.time()-$t0,2))")"
measure "2-ditto-hfsCompression" "$w/comp/$name"
flags "$w/comp/$name"
flags "$w/base/$name"
if command -v afsctool >/dev/null; then
  mkdir -p "$w/lzfse"; ditto "$src" "$w/lzfse/$name"
  afsctool -c -T LZFSE "$w/lzfse/$name" >/dev/null 2>&1 || true
  measure "2b-afsctool-lzfse" "$w/lzfse/$name"
  rm -rf "$w/lzfse"
fi

# 3. Does compression survive install from a DMG whose volume holds compressed files?
for fmt in ULFO UDZO; do
  img="$w/comp-$fmt.dmg"
  t0=$(python3 -c 'import time;print(time.time())')
  hdiutil create -quiet -srcfolder "$w/comp" -volname "cmux NIGHTLY" -format "$fmt" "$img" || { say "hdiutil create $fmt failed"; continue; }
  say "3-$fmt create seconds $(python3 -c "import time;print(round(time.time()-$t0,2))") dmg_bytes $(stat -f %z "$img")"
  mp="$w/m-$fmt"; mkdir -p "$mp"
  hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mp" "$img" >/dev/null || { say "attach $fmt failed"; continue; }
  mounts="$mounts $mp"
  say "3-$fmt volume fs: $(diskutil info "$mp" | grep -E 'File System Personality' | tr -s ' ')"
  measure "3-$fmt-volume" "$mp/$name"
  d="$w/i-$fmt"; mkdir -p "$d/ditto" "$d/cp" "$d/fm"
  ditto "$mp/$name" "$d/ditto/$name"; measure "3-$fmt-a-ditto-plain" "$d/ditto/$name"; rm -rf "$d/ditto"
  cp -R "$mp/$name" "$d/cp/$name"; measure "3-$fmt-b-cp-R" "$d/cp/$name"; rm -rf "$d/cp"
  swift -e 'import Foundation; let a = CommandLine.arguments; try FileManager.default.copyItem(at: URL(fileURLWithPath: a[1]), to: URL(fileURLWithPath: a[2]))' \
    "$mp/$name" "$d/fm/$name" 2>&1 | tail -3 | tee -a "$report"
  measure "3-$fmt-c-FileManager-copyItem" "$d/fm/$name"; flags "$d/fm/$name"; rm -rf "$d/fm"
  hdiutil detach -force "$mp" >/dev/null 2>&1; rm -f "$img"
done
# The same copies from the published (uncompressed) DMG, for the control.
d="$w/i-pub"; mkdir -p "$d/fm" "$d/cp"
cp -R "$src" "$d/cp/$name"; measure "3-published-b-cp-R" "$d/cp/$name"; rm -rf "$d/cp"
swift -e 'import Foundation; let a = CommandLine.arguments; try FileManager.default.copyItem(at: URL(fileURLWithPath: a[1]), to: URL(fileURLWithPath: a[2]))' \
  "$src" "$d/fm/$name" 2>&1 | tail -3 | tee -a "$report"
measure "3-published-c-FileManager-copyItem" "$d/fm/$name"; rm -rf "$d/fm"
# Same-volume move/copy of a compressed app (Sparkle's final step is a rename on the same volume).
mkdir -p "$w/mv"; cp -c -R "$w/comp/$name" "$w/mv/$name" 2>/dev/null || ditto "$w/comp/$name" "$w/mv/$name"
mv "$w/mv/$name" "$w/mv/moved.app"; measure "3-same-volume-mv" "$w/mv/moved.app"; rm -rf "$w/mv"

# 5. Cost: the CEF binary's read and `bin/cmux --version`, compressed vs not.
cef="Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
if sudo -n /usr/sbin/purge 2>"$w/purge.txt"; then purge_ok=1; say "purge: ok (sudo -n)"; else purge_ok=0; say "purge: refused ($(tr '\n' ' ' <"$w/purge.txt"))"; fi
python3 -I - "$w/base/$name/$cef" "$w/comp/$name/$cef" "$w/base/$name/Contents/Resources/bin/cmux" "$w/comp/$name/Contents/Resources/bin/cmux" "$runs" "$purge_ok" <<'PY' | tee -a "$report"
import os, statistics, subprocess, sys, time
bcef, ccef, bcli, ccli, runs, purge = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6] == "1"
def purge_now():
    if purge: subprocess.run(["sudo", "-n", "/usr/sbin/purge"], check=False)
def read(p):
    t = time.perf_counter()
    with open(p, "rb", buffering=0) as f:
        while f.read(8 << 20): pass
    return (time.perf_counter() - t) * 1000
def cli(p):
    t = time.perf_counter(); subprocess.run([p, "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return (time.perf_counter() - t) * 1000
for label, fn, pair in (("cef-read", read, (bcef, ccef)), ("cli-version", cli, (bcli, ccli))):
    for mode in (("cold", "warm") if purge else ("warm",)):
        res = {}
        for name, p in (("plain", pair[0]), ("compressed", pair[1])):
            xs = []
            for _ in range(runs):
                if mode == "cold": purge_now()
                xs.append(fn(p))
            res[name] = xs
        for name, xs in res.items():
            print(f"APFS COST {label} {mode} {name} median_ms={statistics.median(xs):.1f} min={min(xs):.1f} max={max(xs):.1f} n={len(xs)} first={xs[0]:.1f}")
PY
# Without purge, a first read after a fresh copy into a never-read file is the closest to cold:
# copy each again (ditto keeps / drops compression as above) and read once.
for kind in plain compressed; do
  for i in 1 2 3; do
    t="$w/cold-$kind-$i"; mkdir -p "$t"
    if [[ $kind == compressed ]]; then ditto --hfsCompression "$w/base/$name/$cef" "$t/cef"; else ditto "$w/base/$name/$cef" "$t/cef"; fi
    python3 -I -c 'import sys,time
t=time.perf_counter(); f=open(sys.argv[1],"rb",buffering=0)
while f.read(8<<20): pass
print(f"APFS COST cef-read fresh-copy '"$kind"' run='"$i"' ms={(time.perf_counter()-t)*1000:.1f}")' "$t/cef" | tee -a "$report"
    rm -rf "$t"
  done
done

# 6. Self-compress fallback: compress an installed (plain) copy in place, keep the signature.
mkdir -p "$w/self"; ditto "$w/base/$name" "$w/self/$name"
t0=$(python3 -c 'import time;print(time.time())')
ditto --hfsCompression "$w/self/$name" "$w/self/$name.tmp" && mv "$w/self/$name" "$w/self/$name.old" && mv "$w/self/$name.tmp" "$w/self/$name" && rm -rf "$w/self/$name.old"
say "6a whole-bundle ditto+swap seconds $(python3 -c "import time;print(round(time.time()-$t0,2))")"
measure "6a-self-ditto-swap" "$w/self/$name"; rm -rf "$w/self"
mkdir -p "$w/self2"; ditto "$w/base/$name" "$w/self2/$name"
t0=$(python3 -c 'import time;print(time.time())')
find "$w/self2/$name" -type f -size +16k -print0 | while IFS= read -r -d '' f; do
  ditto --hfsCompression "$f" "$f.cmuxtmp" && mv -f "$f.cmuxtmp" "$f"
done
say "6b per-file ditto+rename seconds $(python3 -c "import time;print(round(time.time()-$t0,2))")"
measure "6b-self-per-file" "$w/self2/$name"; flags "$w/self2/$name"
# A launch of the compressed CLI after the per-file pass still works.
run "$w/self2/$name/Contents/Resources/bin/cmux" --version || true
rm -rf "$w/self2"
say "done"
