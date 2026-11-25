#!/usr/bin/env bash
# Download bridge (Leo-Ask-Trace: ask-70d77cbccc): a big npm install on this machine's own link, and the
# bytes that would reach a Mac under each scheme. Installs webviews/package.json's dependencies (46 packages,
# ~hundreds of transitive) from the public registry into a fresh mktemp dir with an empty npm cache, so every
# tarball crosses this machine's link. --ignore-scripts: no postinstall, the fetch alone is measured.
#
# Prints one line per round:
#   download-bridge: {"host", "os", "round", "seconds", "downloadBytes", "nodeModulesBytes", "nodeModulesFiles",
#                     "packages", "lazyReadBytes", "lazyReadFiles", "warmSeconds"}
# Bytes to the Mac by scheme: install on the Mac = downloadBytes over the Mac's link; install on the VM and sync
# back = nodeModulesBytes; download bridge (install on the VM, project lazily) = 0 at install, then only what the
# Mac reads: lazyReadBytes (package.json and type declarations, what a TS language server opens).
#
#   scripts/measure/download-bridge.sh [rounds=1]
#   cmux-ci run --class exclusive --label measure --script scripts/measure/download-bridge.sh --ref <sha> --os macos
set -uo pipefail

rounds=1
for a in "$@"; do
  case "$a" in
    rounds=*) rounds="${a#rounds=}" ;;
    *) echo "download-bridge: unknown argument $a" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
command -v npm >/dev/null || { echo "download-bridge: npm not found" >&2; exit 1; }
w="$(mktemp -d "${TMPDIR:-/tmp}/download-bridge.XXXXXX")"
trap 'chmod -R u+w "$w" 2>/dev/null; rm -rf -- "$w"' EXIT

python3 - "$root/webviews/package.json" "$w/manifest.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
deps = {**p.get("dependencies", {}), **p.get("devDependencies", {})}
json.dump({"name": "download-bridge-measure", "private": True, "dependencies": deps}, open(sys.argv[2], "w"))
PY

now() { python3 -c 'import time; print(time.time())'; }
bytes_of() { python3 - "$1" <<'PY'
import os, sys
total = files = 0
for d, _, names in os.walk(sys.argv[1]):
    for n in names:
        try:
            st = os.lstat(os.path.join(d, n))
        except OSError:
            continue
        total += st.st_size; files += 1
print(total, files)
PY
}

host="$(hostname -s 2>/dev/null || hostname)"
os="$(uname -s)"
for r in $(seq 1 "$rounds"); do
  d="$w/r$r"; mkdir -p "$d/proj" "$d/cache"
  cp "$w/manifest.json" "$d/proj/package.json"
  t0="$(now)"
  (cd "$d/proj" && npm install --cache "$d/cache" --ignore-scripts --legacy-peer-deps --no-audit --no-fund --loglevel=error \
     --prefer-online >"$d/npm.log" 2>&1) || { echo "download-bridge: npm install failed" >&2; tail -20 "$d/npm.log" >&2; exit 1; }
  t1="$(now)"
  # Warm: same cache, fresh node_modules: what a host-shared cache buys the second VM on the host.
  mv "$d/proj/node_modules" "$d/nm-cold"
  t2="$(now)"
  (cd "$d/proj" && npm install --cache "$d/cache" --ignore-scripts --legacy-peer-deps --no-audit --no-fund --loglevel=error \
     --prefer-offline >>"$d/npm.log" 2>&1) || true
  t3="$(now)"
  read -r dl _ < <(bytes_of "$d/cache/_cacache/content-v2")
  read -r nmb nmf < <(bytes_of "$d/nm-cold")
  python3 - "$d/nm-cold" "$host" "$os" "$r" "$t0" "$t1" "$t2" "$t3" "$dl" "$nmb" "$nmf" <<'PY'
import json, os, sys
nm, host, osn, r, t0, t1, t2, t3, dl, nmb, nmf = sys.argv[1:]
lazy = lazyf = pkgs = 0
for d, _, names in os.walk(nm):
    for n in names:
        if n == "package.json" or n.endswith((".d.ts", ".d.mts", ".d.cts")):
            try:
                lazy += os.lstat(os.path.join(d, n)).st_size; lazyf += 1
            except OSError:
                pass
# packages: directories directly under node_modules (and @scope/x), any depth
for d, dirs, _ in os.walk(nm):
    if d == nm or os.path.basename(d) == "node_modules":
        for x in dirs:
            if x.startswith("."):
                continue
            pkgs += len(os.listdir(os.path.join(d, x))) if x.startswith("@") else 1
print("download-bridge: " + json.dumps({
    "host": host, "os": osn, "round": int(r), "seconds": round(float(t1) - float(t0), 2),
    "downloadBytes": int(dl), "nodeModulesBytes": int(nmb), "nodeModulesFiles": int(nmf), "packages": pkgs,
    "lazyReadBytes": lazy, "lazyReadFiles": lazyf, "warmSeconds": round(float(t3) - float(t2), 2)}))
PY
done
