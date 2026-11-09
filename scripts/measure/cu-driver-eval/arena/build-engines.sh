#!/usr/bin/env bash
# Builds the arena's engines that exist only as open PRs (README.md, "Arms"), on the fleet worker
# before the bench VM boots: the worker has Xcode and the Rust toolchain, the guest has neither.
# Each engine is built from its PR's commit, fetched by sha, and cached by that sha.
#
#   build-engines.sh OUT CACHE cu-fast=SHA cu-rewrite=SHA chief-desktop=SHA
#
# OUT/<engine>/ gets what the guest needs, or OUT/<engine>/unavailable with the reason:
#   cu-fast        cmux#36993: cmux-cu-service (the guest assembles and signs "cmux CU Engine.app")
#   cu-rewrite     cmux#37003: "cmux Remote (dev).app" (its build script, unsigned), acpmux, SKILL.md
#   chief-desktop  cmux#36515: SKILL.md, the "Drive the desktop" part of its chief-cloud-machines skill
# An engine that does not build is reported, never fatal: the other arms still run.
set -uo pipefail
out=$1 cache=$2
shift 2
root="$(git rev-parse --show-toplevel)"
mkdir -p "$out" "$cache"
log() { echo "ARENA-BUILD $*"; }

# tree SHA: SHA's files (git archive, without the iOS app and the web trees, which no engine
# builds from), cached by sha; prints its path. An archive, not a worktree: the step's own
# checkout, which a worktree would point back into, is gone after the step.
tree() {
  local sha=$1 dir="$cache/tree-$1"
  if [[ ! -f "$dir/.arena-complete" ]]; then
    rm -rf "$dir"
    # Not shallow: the warm checkout outlives the step. It may have no origin remote (as chief-build-cache.sh).
    # No submodules: the worker's checkout fetches them by default, and a submodule commit its
    # remote does not serve ("upload-pack: not our ref") failed the whole fetch (run at af1275d1).
    git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$root" fetch -q --no-tags --no-recurse-submodules origin "$sha" 2>/dev/null \
      || git -C "$root" fetch -q --no-tags --no-recurse-submodules https://github.com/manaflow-ai/cmux.git "$sha" || return 1
    mkdir -p "$dir"
    git -C "$root" archive "$sha" -- . ':(exclude)cmux-next-ios' ':(exclude)web' ':(exclude)webviews' | tar -x -C "$dir" || return 1
    touch "$dir/.arena-complete"
  fi
  echo "$dir"
}

for spec in "$@"; do
  name=${spec%%=*} sha=${spec#*=}
  dest="$out/$name"
  rm -rf "$dest"
  mkdir -p "$dest"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "not a full sha: $sha" >"$dest/unavailable"; continue; }
  echo "$sha" >"$dest/sha"
  done_marker="$cache/built-$name-$sha"
  if ! src=$(tree "$sha"); then
    echo "could not fetch $sha" >"$dest/unavailable"
    log "$name: could not fetch $sha"
    continue
  fi
  started=$(date +%s)
  case "$name" in
    cu-fast)
      package="$src/Packages/macOS/CmuxComputerUseEngine"
      if (cd "$package" && swift build -c release --arch arm64 --product cmux-cu-service </dev/null) >"$dest/build.log" 2>&1; then
        cp "$(cd "$package" && swift build -c release --arch arm64 --show-bin-path)/cmux-cu-service" "$dest/"
      else
        echo "swift build of cmux-cu-service failed (build.log)" >"$dest/unavailable"
      fi
      ;;
    cu-rewrite)
      remote_zip="$cache/cmux-remote-$sha.zip" acpmux="$cache/acpmux-$sha"
      if [[ ! -s "$remote_zip" ]]; then
        # Its own build script; Icon Composer's ictool may be missing on a worker, and an icon
        # changes nothing here, so a failed icon export is tolerated by running the steps it needs.
        if (cd "$src" && bash scripts/cmux-next/build-cmux-remote-dev.sh --out "$cache/remote-$sha") >"$dest/build.log" 2>&1; then
          cp "$cache/remote-$sha/cmux-remote-dev-unsigned-macos-arm64.zip" "$remote_zip"
        fi
      fi
      if [[ ! -x "$acpmux" ]]; then
        (cd "$src/cmux-tui" && MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_TARGET_DIR="$cache/target-$sha" \
          cargo build --release --locked -p acpmux --bin acpmux) >>"$dest/build.log" 2>&1 &&
          cp "$cache/target-$sha/release/acpmux" "$acpmux"
      fi
      if [[ -s "$remote_zip" && -x "$acpmux" ]]; then
        cp "$remote_zip" "$dest/cmux-remote.zip"
        cp "$acpmux" "$dest/acpmux"
        cp "$src/skills/cmux-computer-use/SKILL.md" "$dest/SKILL.md" 2>/dev/null || true
      else
        echo "cmux Remote or acpmux did not build (build.log: $(grep -m1 -E 'error' "$dest/build.log" | head -c 200))" >"$dest/unavailable"
      fi
      ;;
    chief-desktop)
      skill="$src/Native/OptChat/optchat-chief/skills/chief-cloud-machines/SKILL.md"
      # The section the Chief reads before it drives a desktop, up to the next "## " heading.
      awk '/^## 3\. Drive the desktop/{on=1} on && /^## / && !/^## 3\./{exit} on' "$skill" >"$dest/SKILL.md" 2>/dev/null
      [[ -s "$dest/SKILL.md" ]] || echo "no 'Drive the desktop' section in $skill" >"$dest/unavailable"
      ;;
    *) echo "no engine named $name" >"$dest/unavailable" ;;
  esac
  [[ -f "$dest/unavailable" ]] && log "$name: unavailable: $(cat "$dest/unavailable")" || { touch "$done_marker"; log "$name: built at ${sha:0:10} in $(( $(date +%s) - started )) s"; }
done
exit 0
