#!/usr/bin/env bash
# The cmux/ui-proof look of a pull request whose change needs a Swift build, on a fleet Mac with a console session:
# the head's Swift built Release as the nightly builds it and swapped into a side-instance copy of the signed nightly
# (scripts/cmux-next/swap-binary.sh, as swap-binary-proof.sh), then `hot-verify.py look --head-app` shoots NIGHTLY's
# copy into before/ and the swapped copy, with the plan's rust and web layers put in, into after/ and steps/.
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/ui-proof-look.sh \
#     --ref <feat-cmux-next sha> --arg head=<sha> --arg pr=<N> [--arg state64=BASE64] [--arg video=0] \
#     [--arg nightly=URL] --artifact .build/ui-proof-look/report.tgz --timeout 5400
#   head=SHA       the pull request's head commit (the record names it)
#   pr=N           the pull request (its published web layer; the record's PR)
#   state64=B64    a hot-verify steps file ({"steps": [...]}, no kit), base64: the click-through after the change;
#                  else the default walk
#   video=0        no video.mp4
# The swapped Swift is the change's own commits (merge base..head) applied onto the nightly's commit, as the look's
# daemon_from is, so after/ differs from before/ by the change alone. A plan the swap cannot carry (helpers, the FFI,
# Info.plist...) exits 3 with the plan's reasons. Prints UPL-PLAN, UPL-BUILD and UPL-RECORD; report.tgz holds look/
# (before/, after/, steps/, receipt.json, proof-record.md) and the logs. Nothing is posted: the caller reads
# look/proof-record.md and posts it (gh pr comment N --body-file proof-record.md). The copies are removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/ui-proof-look"
rm -rf "$out" && mkdir -p "$out"
head="" pr="" state64="" video=1 nightly=""
for arg in "$@"; do
  case "$arg" in
    head=*) head="${arg#head=}" ;;
    pr=*) pr="${arg#pr=}" ;;
    state64=*) state64="${arg#state64=}" ;;
    video=0|video=1) video="${arg#video=}" ;;
    nightly=https://*) nightly="${arg#nightly=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "head= takes a 40-hex commit" >&2; exit 2; }
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr= takes a pull request number" >&2; exit 2; }
tool="$root/scripts/cmux-next/swap-binary.sh" side="$root/scripts/cmux-next/side-instance.sh"
hv="$root/scripts/cmux-next/hot-verify.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/ui-proof-look.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
cleanup() {
  python3 "$hv" stop --side upl-look --remove >/dev/null 2>&1 || true
  "$side" remove upl-head >/dev/null 2>&1 || true
  [[ -d "$work/onto" ]] && git -C "$root" worktree remove --force "$work/onto" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
echo "UPL host macOS $(sw_vers -productVersion) xcode=\"$(xcodebuild -version 2>/dev/null | tr '\n' ' ')\""

# NIGHTLY, as swap-binary-proof.sh takes it.
if [[ -z "$nightly" ]]; then
  nightly="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$nightly" || { echo "UPL download failed"; exit 3; }
mkdir -p "$work/mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$work/mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$work/mnt" >/dev/null
app="$work/app/cmux NIGHTLY.app"
commit="$(plutil -extract CMUXCommit raw -o - "$app/Contents/Info.plist")"
echo "UPL nightly $nightly commit=$commit"

# The plan against NIGHTLY: what the look will do, and whether a swap carries its build.
for sha in "$commit" "$head"; do
  git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$root" fetch -q --no-tags origin "$sha" \
    || git -C "$root" fetch -q --no-tags https://github.com/manaflow-ai/cmux.git "$sha" || { echo "UPL cannot fetch $sha"; exit 3; }
done
git -C "$root" merge-base "$commit" "$head" >/dev/null 2>&1 || git -C "$root" fetch -q --no-tags --unshallow origin 2>/dev/null || true
python3 "$hv" plan --source "sha:$head" --app "$app" --json >"$out/plan.json" 2>"$out/plan.err" || { cat "$out/plan.err"; exit 3; }
read -r carried onto rust <<<"$(python3 -I - "$out/plan.json" "$head" <<'PY'
import json, sys
plan, head = json.load(open(sys.argv[1])), sys.argv[2]
swap = {"Swift", "Swift, resources or manifests", "strings"}  # hot-verify.py SWAP_REASONS
build = plan.get("build") or {}
carried = int(bool(plan.get("needs_build")) and set(build) <= swap)
rust = int("rust" in (plan.get("layers") or []))
print(carried, plan.get("daemon_from") or head, rust)
PY
)"
echo "UPL-PLAN $(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); print("layers=" + (",".join(p["layers"]) or "none"), "build=" + (";".join(p["build"]) or "none"))' "$out/plan.json") onto=$onto"
[[ "$carried" == 1 ]] || { echo "UPL refused: a swap of the head's Swift does not carry this plan's build (plan.json)"; cat "$out/plan.json"; exit 3; }
if [[ "$onto" == "$head" ]] && ! git -C "$root" merge-base --is-ancestor "$commit" "$head"; then
  # No daemon_from (no rust layer): the change's own commits onto the nightly's commit, by the look's recipe
  # (hot-verify.py onto_app), so the swapped Swift lacks nothing NIGHTLY has.
  fork="$(git -C "$root" merge-base "$commit" "$head")" || { echo "UPL no merge base of $commit and $head"; exit 3; }
  tree="$(git -C "$root" merge-tree --write-tree --no-messages --merge-base="$fork" "$commit" "$head")" \
    || { echo "UPL the change does not apply cleanly onto the nightly's commit $commit"; exit 3; }
  stamp="$(git -C "$root" show -s --format=%ct "$head")"
  onto="$(GIT_AUTHOR_NAME=hot-verify GIT_AUTHOR_EMAIL=hot-verify@cmux.invalid GIT_COMMITTER_NAME=hot-verify \
    GIT_COMMITTER_EMAIL=hot-verify@cmux.invalid GIT_AUTHOR_DATE="@$stamp +0000" GIT_COMMITTER_DATE="@$stamp +0000" \
    git -C "$root" commit-tree --no-gpg-sign "$tree" -p "$commit" -m "hot-verify: $fork .. $head onto $commit")"
fi

# The head's Swift (onto the nightly's commit), swapped into a copy of NIGHTLY.
t0=$SECONDS
"$tool" build "$onto" "$out/build-head" --like "$app" 2>"$out/build-head.err" | tee "$out/build-head.log" || { tail -30 "$out/build-head.err"; exit 1; }
"$side" make upl-head --from "$app" --label "cmux ui-proof head" --swap "$out/build-head" >"$out/make-head.log" 2>&1 || { cat "$out/make-head.log"; exit 1; }
head_app="$("$side" path upl-head)"
swift_s=$((SECONDS - t0))
# Its daemon, when the plan has a rust layer: nothing CI publishes for a lane head, so cargo here, at the commit the
# look's rust layer names (daemon_from: --rust-binary; else the head: --rust-binary-head).
rust_args=()
if [[ "$rust" == 1 ]]; then
  command -v cargo >/dev/null || { echo "UPL no cargo on this Mac to build the head's daemon (the plan has a rust layer)"; exit 3; }
  t1=$SECONDS
  git -C "$root" worktree add -q --detach "$work/onto" "$onto" || exit 1
  target="${CMUX_UI_PROOF_LOOK_TARGET:-$HOME/Library/Caches/cmux-next/ui-proof-look/target}" # warm across runs
  (cd "$work/onto/cmux-tui" && CARGO_TARGET_DIR="$target" cargo build --release -p cmux-tui --bin cmux-tui) \
    >"$out/cargo.log" 2>&1 || { tail -30 "$out/cargo.log"; exit 1; }
  cp "$target/release/cmux-tui" "$work/cmux-tui"
  if python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("daemon_from") else 1)' "$out/plan.json"; then
    rust_args=(--rust-binary "$work/cmux-tui")
  else
    rust_args=(--rust-binary-head "$work/cmux-tui")
  fi
  echo "UPL-BUILD daemon cargo_s=$((SECONDS - t1))"
fi
echo "UPL-BUILD swift onto=$onto swift_s=$swift_s"

state_args=() video_args=()
if [[ -n "$state64" ]]; then
  printf '%s' "$state64" | base64 -D >"$work/steps.json" 2>/dev/null || printf '%s' "$state64" | base64 -d >"$work/steps.json" \
    || { echo "UPL state64= is not base64" >&2; exit 2; }
  state_args=(--state "$work/steps.json")
fi
[[ "$video" == 0 ]] && video_args=(--no-video)
python3 "$hv" look --source "sha:$head" --pr "$pr" --app "$app" --head-app "$head_app" --side upl-look \
  --out "$out/look" --record --no-post ${rust_args[@]+"${rust_args[@]}"} ${state_args[@]+"${state_args[@]}"} ${video_args[@]+"${video_args[@]}"} 2>&1 | tee "$out/look.log"
code=${PIPESTATUS[0]}
record="$out/look/proof-record.md"
if [[ -f "$record" ]]; then
  echo "UPL-RECORD $(head -1 "$record") $(sed -n '2p' "$record" | cut -c1-200)"
else
  echo "UPL-RECORD none (look exit $code)"
fi
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude 'build-*/app' . 2>/dev/null || true
[[ "$code" == 0 && -f "$record" ]]
