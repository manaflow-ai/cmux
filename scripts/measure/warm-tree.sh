#!/usr/bin/env bash
# Warm build trees (scripts/ci/warm-tree.sh) against today's paths, on one fleet Mac, for a one-line
# edit: a Swift edit in CmuxNextDesign (`swift build` of Packages/macOS/CmuxNext) and a Rust edit in
# acpmux (`cargo build -p cmux-tui -p acpmux --bins` in cmux-tui, as rust-dev-loop's acpmux_leaf).
#
#   cmux-ci run --class exclusive --label measure --measurement --script scripts/measure/warm-tree.sh \
#     --ref SHA --target-worker W --pin-strict --timeout 14400 [--arg=k=40] [--arg=langs=swift,rust]
#
# Every arm builds at one fixed seat path (build state is keyed by absolute path), one at a time:
#   cold     a fresh checkout of the ref, the edit, a build: a slot or runner with nothing warm.
#   current  the slot path today: the seat built at the ref's K-th first-parent ancestor (another
#            job's or an older tip's tree), checked out to the ref in place, the edit, a build.
#   warm     warm-tree.sh use --ref REF over that seat: the tree saved after the ref's own build
#            (as a tip warmer would save it) is cloned in, the ref checked out, the edit, a build.
#   warm_far the same with only the ancestor's tree saved: a job whose nearest saved tree is K
#            commits back (an old tip), to show what restoring alone buys.
# Lines: `WARMTREE {json}` per build (lang, arm, ready_s, build_s, total_s, runner_min, compiled,
# status; runner_min is ready plus build, the runner time a job of that arm holds), `WARMTREE-SAVE`
# (what saving a tree costs the trusted build that saves it, not the job) and
# `WARMTREE-SUMMARY {json}`. The whole root is removed on exit.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
k=40 langs=swift,rust swift_args="" fetch_url="${WARM_TREE_FETCH_URL:-https://github.com/manaflow-ai/cmux.git}"
for kv in "$@"; do
  case "$kv" in
    k=*) k="${kv#*=}" ;;
    langs=*) langs="${kv#*=}" ;;
    swift_args=*) swift_args="${kv#*=}" ;;
    *) echo "warm-tree: unknown argument $kv" >&2; exit 2 ;;
  esac
done
[[ "$k" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "warm-tree: k must be 1-9999" >&2; exit 2; }
export GIT_TERMINAL_PROMPT=0
if [ -n "${CMUX_CI_XCODE_APP:-}" ]; then
  export DEVELOPER_DIR="$CMUX_CI_XCODE_APP/Contents/Developer"
fi
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$repo/cmux-tui/rust-toolchain.toml")"
export RUSTUP_TOOLCHAIN="$toolchain"

# On the data volume, never under the step's checkout or a tmpfs; seat and store on one volume.
mkdir -p "$HOME/.cache"
root="$(mktemp -d "$HOME/.cache/warm-tree-measure.XXXXXX")"
root="$(cd "$root" && pwd -P)"
cleanup() { chmod -R u+w "$root" 2>/dev/null || true; rm -rf "$root"; }
trap cleanup EXIT
seat="$root/seat"
store="$root/store"
wt=(env WARM_TREE_BIN_CACHE="$root/bin" "$repo/scripts/ci/warm-tree.sh")

now_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }
secs() { python3 -c 'import sys; print(round(int(sys.argv[1]) / 1000, 1))' "$1"; }
field() { python3 -c 'import json, sys; v = json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

# History for the ref and its K-th ancestor: the step's checkout (often shallow, no origin), then
# GitHub for the commits it lacks.
ref="$(git -C "$repo" rev-parse HEAD)"
gitsrc="$root/git"
git init -q --bare "$gitsrc"
git -C "$gitsrc" fetch -q --no-tags --no-recurse-submodules "$repo" "$ref"
git -C "$gitsrc" update-ref refs/measure/ref "$ref"
if ! git -C "$gitsrc" rev-parse -q --verify "$ref~$k^{commit}" >/dev/null; then
  git -C "$gitsrc" fetch -q --no-tags --no-recurse-submodules --depth=$((k + 2)) "$fetch_url" "$ref"
fi
old="$(git -C "$gitsrc" rev-parse --verify "$ref~$k^{commit}")"
echo "warm-tree: ref $ref, ancestor $old ($k first-parent commits back)"

# A fresh standalone checkout of REV at the seat, with the submodules the builds need.
fresh_seat() {
  chmod -R u+w "$seat" 2>/dev/null || true
  rm -rf "$seat"
  git init -q "$seat"
  git -C "$seat" fetch -q --no-tags --no-recurse-submodules "$gitsrc" "$1"
  git -C "$seat" checkout -q --detach "$1"
  submodules
}
submodules() {
  # ghostty-next: cmux-tui builds libghostty-vt from it. Shallow, as cmux-build.sh does.
  if [[ ",$langs," == *",rust,"* ]]; then
    git -C "$seat" -c protocol.file.allow=always submodule update -q --init --depth 1 ghostty-next
  fi
}
in_place() {
  git -C "$seat" fetch -q --no-tags --no-recurse-submodules "$gitsrc" "$1" 2>/dev/null || true
  git -C "$seat" checkout -q --force --detach "$1"
  submodules
}

swift_file="Packages/macOS/CmuxNext/Sources/CmuxNextDesign/AgentPresenceColor.swift"
rust_file="cmux-tui/crates/acpmux/src/harness_icon_set.rs"
edit() {
  case "$1" in
    swift) printf '\nprivate let warmTreeMeasureEdit = %s\n' "$2" >> "$seat/$swift_file" ;;
    rust) printf '\n#[allow(dead_code)]\nconst WARM_TREE_MEASURE_EDIT: u32 = %s;\n' "$2" >> "$seat/$rust_file" ;;
  esac
}
unedit() { git -C "$seat" checkout -q -- "$swift_file" "$rust_file"; }

# build LANG LOG: prints "MS COMPILED STATUS".
build() {
  local started status=0 ms compiled
  started=$(now_ms)
  case "$1" in
    swift) (cd "$seat/Packages/macOS/CmuxNext" && swift build $swift_args) > "$2" 2>&1 < /dev/null || status=$? ;;
    rust) (cd "$seat/cmux-tui" && cargo build --locked -p cmux-tui -p acpmux --bins) > "$2" 2>&1 < /dev/null || status=$? ;;
  esac
  ms=$(( $(now_ms) - started ))
  case "$1" in
    swift) compiled=$(grep -cE '^\[[0-9]+/[0-9]+\] Compiling ' "$2" || true) ;;
    rust) compiled=$(grep -cE '^ +Compiling ' "$2" || true) ;;
  esac
  echo "$ms $compiled $status"
}

emit() { # LANG ARM READY_MS MS COMPILED STATUS [EXTRA_JSON]
  # runner_min: the minutes this build holds a runner (the step is alone on it, class exclusive).
  printf 'WARMTREE {"lang":"%s","arm":"%s","ready_s":%s,"build_s":%s,"total_s":%s,"runner_min":%s,"compiled":%s,"status":%s%s}\n' \
    "$1" "$2" "$(secs "$3")" "$(secs "$4")" "$(secs $(( $3 + $4 )))" \
    "$(python3 -c 'import sys; print(round(int(sys.argv[1]) / 60000, 2))' $(( $3 + $4 )))" "$5" "$6" "${7:+,$7}"
}
must() { [ "$1" -eq 0 ] || { tail -40 "$2" >&2; echo "warm-tree: $3 failed ($1)" >&2; exit 1; }; }

summary=()
for lang in ${langs//,/ }; do
  case "$lang" in swift|rust) ;; *) echo "warm-tree: unknown lang $lang" >&2; exit 2 ;; esac
  rm -rf "$store"

  # cold: fresh checkout of the ref, the edit, a build.
  t=$(now_ms); fresh_seat "$ref"; ready=$(( $(now_ms) - t ))
  edit "$lang" 1
  read -r ms compiled status < <(build "$lang" "$root/$lang-cold.log"); must "$status" "$root/$lang-cold.log" "$lang cold"
  emit "$lang" cold "$ready" "$ms" "$compiled" "$status"
  cold_s=$(secs $(( ready + ms )))
  # The ref's own tree, as the tip warmer would leave it: built without the edit, then saved.
  unedit
  read -r ms compiled status < <(build "$lang" "$root/$lang-ref.log"); must "$status" "$root/$lang-ref.log" "$lang ref build"
  saved=$("${wt[@]}" save --store "$store/near" --seat "$seat" --keep 4)
  echo "WARMTREE-SAVE {\"lang\":\"$lang\",\"save_ms\":$(field "$saved" ms),\"clone\":\"$(field "$saved" clone)\"}"

  # current: the seat built at the ancestor, then the in-place checkout of the ref as a slot does.
  fresh_seat "$old"
  read -r ms compiled status < <(build "$lang" "$root/$lang-old.log"); must "$status" "$root/$lang-old.log" "$lang ancestor build"
  echo "WARMTREE-SETUP {\"lang\":\"$lang\",\"ancestor_build_s\":$(secs "$ms"),\"compiled\":$compiled}"
  "${wt[@]}" save --store "$store/far" --seat "$seat" --keep 4 > /dev/null
  t=$(now_ms); in_place "$ref"; ready=$(( $(now_ms) - t ))
  changed=$(git -C "$seat" diff --name-only "$old" "$ref" | wc -l | tr -d ' ')
  edit "$lang" 2
  read -r ms compiled status < <(build "$lang" "$root/$lang-current.log"); must "$status" "$root/$lang-current.log" "$lang current"
  emit "$lang" current "$ready" "$ms" "$compiled" "$status" "\"changed_files\":$changed"
  current_s=$(secs $(( ready + ms )))

  # warm: restore the ref's saved tree over the seat, check out the ref, the edit, a build.
  t=$(now_ms)
  # --always: the seat already sits at the ref after the current arm; a job's seat would not.
  used=$("${wt[@]}" use --store "$store/near" --seat "$seat" --ref "$ref" --git "$gitsrc" --always)
  submodules; ready=$(( $(now_ms) - t ))
  [ "$(field "$used" restored)" = True ] || { echo "warm-tree: $lang warm did not restore: $used" >&2; exit 1; }
  edit "$lang" 3
  read -r ms compiled status < <(build "$lang" "$root/$lang-warm.log"); must "$status" "$root/$lang-warm.log" "$lang warm"
  emit "$lang" warm "$ready" "$ms" "$compiled" "$status" "\"discard_ms\":$(field "$used" discard_ms),\"restore_ms\":$(field "$used" restore_ms),\"checkout_ms\":$(field "$used" checkout_ms),\"nearest_distance\":$(field "$used" nearest_distance)"
  warm_s=$(secs $(( ready + ms )))

  # warm_far: only the ancestor's tree saved (an old tip): restore it, check out the ref, edit, build.
  t=$(now_ms)
  used=$("${wt[@]}" use --store "$store/far" --seat "$seat" --ref "$ref" --git "$gitsrc" --always)
  submodules; ready=$(( $(now_ms) - t ))
  edit "$lang" 4
  read -r ms compiled status < <(build "$lang" "$root/$lang-warm-far.log"); must "$status" "$root/$lang-warm-far.log" "$lang warm_far"
  emit "$lang" warm_far "$ready" "$ms" "$compiled" "$status" "\"discard_ms\":$(field "$used" discard_ms),\"restore_ms\":$(field "$used" restore_ms),\"checkout_ms\":$(field "$used" checkout_ms),\"nearest_distance\":$(field "$used" nearest_distance),\"changed_files\":$(field "$used" changed_files)"
  summary+=("\"$lang\":{\"cold_s\":$cold_s,\"current_s\":$current_s,\"warm_s\":$warm_s}")
done
printf 'WARMTREE-SUMMARY {%s,"k":%s,"ref":"%s","host":"%s","xcode":"%s"}\n' \
  "$(IFS=,; echo "${summary[*]}")" "$k" "$ref" "$(hostname -s)" "$(xcodebuild -version 2>/dev/null | head -1)"
