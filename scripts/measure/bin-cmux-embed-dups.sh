#!/usr/bin/env bash
# CMUX-570: bin/cmux bytes and embedded-file copies at BASE vs this checkout. Builds the cmux binary with
# cmux-tui's own release profile at both commits, strips it, prints `SIZE side file=N build_seconds=N` and,
# for each file that two crates or a const table used to embed twice, `COPIES side name bytes count`.
# Then a duress bench: with nproc busy loops running, interleaved p50 of `cmux customize recipes` (writes every
# recipe file from the shared table, HOME in scratch) and `cmux --version`, 60 rounds each side: `BENCH side what p50_ms=N`.
# Fleet only:  cmux-ci test -- bash scripts/measure/bin-cmux-embed-dups.sh BASE_FULL_SHA
set -euo pipefail
root="$(git rev-parse --show-toplevel)"; base="${1:?BASE}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/embed-dups.XXXXXX")"; trap 'git -C "$root" worktree remove --force "$scratch/base" 2>/dev/null; rm -rf "$scratch"' EXIT
# A cmux-ci step tree is shallow and has no `origin`: fetch BASE (a full SHA) by URL.
fetch_url="$(git -C "$root" remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)"
depth=(); [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$root" fetch -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$base"
git -C "$root" worktree add -q --detach "$scratch/base" "$base"
# The base worktree has no submodules checked out: both sides build ghostty from HEAD's ghostty-next
# (this cut does not touch it), so the size difference is the Rust change alone.
export CMUX_GHOSTTY_SRC="${CMUX_GHOSTTY_SRC:-$root/ghostty-next}"
files=(cmux-tui/crates/acpmux/skills/cmux-rich-output/templates/deck.html cmux-tui/crates/cmux-app-host/schema/v2/cmux-app.schema.json schemas/theme/slots.json cmux-tui/crates/cmux-browser-host/js/guide.md cmux-tui/crates/cmux-customize-recipes/recipes/apps/tonal/agent-pane.css skills/cmux-customization/templates/my-prs/main.js)
for side in base head; do
  tree="$root"; [[ $side == base ]] && tree="$scratch/base"
  start=$SECONDS
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$scratch/t-$side" cargo build -q --locked --release -p cmux-tui --bin cmux-tui >&2)
  cp "$scratch/t-$side/release/cmux-tui" "$scratch/$side"; strip --strip-unneeded "$scratch/$side"
  echo "SIZE $side file=$(stat -c %s "$scratch/$side") build_seconds=$((SECONDS-start))"
  for f in "${files[@]}"; do
    python3 -c 'import sys;b=open(sys.argv[1],"rb").read();d=open(sys.argv[2],"rb").read();print("COPIES",sys.argv[3],sys.argv[2].split("/")[-1],len(d),b.count(d))' "$scratch/$side" "$root/$f" "$side"
  done
done
busy=(); for _ in $(seq "$(nproc)"); do (while :; do :; done) & busy+=($!); done
trap 'kill "${busy[@]}" 2>/dev/null; git -C "$root" worktree remove --force "$scratch/base" 2>/dev/null; rm -rf "$scratch"' EXIT
python3 - "$scratch" <<'PY'
import subprocess,sys,time,statistics
d=sys.argv[1]; r={}
import os
env=dict(os.environ,HOME=d+"/home",XDG_STATE_HOME=d+"/home/state",XDG_CONFIG_HOME=d+"/home/config")
cases={"customize-recipes":["customize","recipes"],"version":["--version"]}
for _ in range(60):
    for side in ("base","head"):
        for what,args in cases.items():
            t=time.perf_counter(); subprocess.run([d+"/"+side]+args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env)
            r.setdefault((side,what),[]).append((time.perf_counter()-t)*1000)
for (side,what),v in sorted(r.items()): print(f"BENCH {side} {what} p50_ms={statistics.median(v):.2f} n={len(v)}")
PY
