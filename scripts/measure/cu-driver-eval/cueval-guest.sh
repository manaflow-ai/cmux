#!/usr/bin/env bash
# Runs the CU hill-climb suite (evals/computer-use, prereg-cu-hill-climb-macos.json: 20 macOS tasks x
# 3 trials, arm cmux-cu, claude opus) inside a cu-driver-bench VM (cu-driver-bench.sh suite=cueval),
# in the console user's login session (guest-start.sh starts it as a LaunchAgent). The route stage has
# already put the pinned Claude Code at /opt/homebrew/bin/claude, its managed settings on the route.
#   cueval-guest.sh [trials=N] [tasks=a,b] [ARG...]     (reps=, drivers=, electron= are ignored)
# It installs the newest cmux NEXT Nightly from its feed, grants it, bash and the pinned Python TCC
# (the VM has SIP off), opens it, waits for its daemon socket, then runs cueval. trials= or tasks=
# other than the prereg's run unregistered (--split all needs a prereg, so they use --split dev).
# Writes ~/cu-eval/artifacts/cu-driver-eval/cueval/{results,calls}.jsonl and cu-driver-eval.tgz.
set -uo pipefail
trials=3 tasks=""
for arg in "$@"; do
  case "$arg" in
    trials=*) trials="${arg#trials=}" ;;
    tasks=*) tasks="${arg#tasks=}" ;;
  esac
done
[[ "$trials" =~ ^[0-9]{1,2}$ && "$tasks" =~ ^[a-z0-9,-]*$ ]] || { echo "cueval-guest.sh: trials= is a number, tasks= a comma list" >&2; exit 2; }
root="${CU_DRIVER_EVAL_ROOT:-$HOME/cu-eval}"
here="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/cu-driver-eval"
work="$root/.build/cueval"
cache="$HOME/Library/Caches/cmux/cu-driver-eval"
rm -rf "$out" "$work" "$root/artifacts/cu-driver-eval.tgz"
mkdir -p "$out/cueval" "$work" "$cache"
facts="$out/cueval/run.json"
note() { echo "CU-DRIVER-EVAL-STAGE $*"; }
finish() {
  [[ -n "${1:-}" ]] && { echo "CU-DRIVER-EVAL-ERROR $1"; printf '%s\n' "$1" >"$out/cueval/blocked.txt"; }
  tar -czf "$root/artifacts/cu-driver-eval.tgz" -C "$root/artifacts" cu-driver-eval
}
pin() { python3 -I -c 'import functools, json, sys; print(functools.reduce(lambda d, k: d[k], sys.argv[2:], json.load(open(sys.argv[1]))))' "$here/pins.json" "$@"; }

note "python"
# cueval needs Python 3.10 or later; the image has only the Command Line Tools' 3.9.
py_sum=$(pin python sha256) py_tgz="$cache/python-$py_sum.tar.gz"
if [[ "$(shasum -a 256 "$py_tgz" 2>/dev/null | awk '{print $1}')" != "$py_sum" ]]; then
  curl -fsSL --retry 3 --retry-all-errors -o "$py_tgz.part" "$(pin python url)" && mv "$py_tgz.part" "$py_tgz"
fi
[[ "$(shasum -a 256 "$py_tgz" 2>/dev/null | awk '{print $1}')" == "$py_sum" ]] || { rm -f "$py_tgz"; finish "could not fetch the pinned Python"; exit 4; }
tar -xzf "$py_tgz" -C "$work" || { finish "could not unpack the pinned Python"; exit 4; }
py="$work/python/bin/python3"
"$py" -V || { finish "the pinned Python does not run"; exit 4; }

note "nightly"
# The newest build on the NEXT feed with a DMG, as the probes install it (cmuxterm-hq cloud_chat_app_probe.py).
feed=https://files-next.cmux.com/nightly-next/appcast-arm64.xml
curl -fsSL --retry 3 --retry-all-errors -m 60 -o "$work/appcast.xml" "$feed" || { finish "could not read the NEXT feed"; exit 4; }
read -r build commit dmg_url < <("$py" -I - "$work/appcast.xml" <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
best = None
for item in re.findall(r"<item>(.*?)</item>", text, re.S):
    version = re.search(r"<sparkle:version>([0-9]+)</sparkle:version>", item)
    commit = re.search(r"sourceCommit[^>]*>([0-9a-f]{40})<", item)
    url = re.search(r'<enclosure url="(https://files-next\.cmux\.com/[^"]+\.dmg)"', item)
    if version and url and (best is None or int(version.group(1)) > int(best[0])):
        best = (version.group(1), commit.group(1) if commit else "-", url.group(1))
print(*(best or ("", "", "")))
EOF
)
[[ -n "${dmg_url:-}" ]] || { finish "the NEXT feed names no build with a DMG"; exit 4; }
echo "nightly build $build commit $commit"
curl -fsSL --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg_url" || { finish "could not download $dmg_url"; exit 4; }
mkdir -p "$work/mnt"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$work/mnt" "$work/nightly.dmg" >/dev/null || { finish "hdiutil attach failed"; exit 4; }
src=$(find "$work/mnt" -maxdepth 1 -name '*.app' | head -1)
app="/Applications/$(basename "${src:-none.app}")"
[[ -n "$src" ]] && sudo -n rm -rf "$app" && sudo -n ditto "$src" "$app"
hdiutil detach -force "$work/mnt" >/dev/null 2>&1 || true
[[ -n "$src" && -d "$app" ]] || { finish "the Nightly's DMG holds no app"; exit 4; }
codesign --verify --deep --strict "$app" || { finish "the Nightly's signature does not verify"; exit 4; }
sudo -n xattr -cr "$app"
cli="$app/Contents/Resources/bin/cmux"
[[ -x "$cli" ]] || { finish "the Nightly has no CLI at Contents/Resources/bin/cmux"; exit 4; }

note "grant"
# Who TCC asks about: the app (its daemon drives the screen), every executable it ships, the shell and
# Python that start the agent and the fixtures.
grants=(/bin/bash "$work/python/bin/python3.12")
while IFS= read -r exe; do grants+=("$exe"); done < <(find "$app/Contents/MacOS" "$app/Contents/Resources/bin" -maxdepth 1 -type f -perm -u+x 2>/dev/null)
bash "$here/tcc-grant.sh" "${grants[@]}" || { bash "$here/tcc-grant.sh" --diagnose >"$out/cueval/tcc-diagnose.txt" 2>&1; finish "tcc-grant.sh failed (cueval/tcc-diagnose.txt)"; exit 4; }

note "open"
open -g "$app" || { finish "open $app failed"; exit 4; }
sock="${TMPDIR:-/tmp}/cmux-tui-$(id -u)/cmux-app-nightly.sock"
for _ in $(seq 1 60); do [[ -S "$sock" ]] && break; sleep 2; done
[[ -S "$sock" ]] || { ls -la "$(dirname "$sock")" 2>&1; finish "the Nightly's daemon socket did not appear in 120 s ($sock)"; exit 4; }
"$cli" --version 2>&1 | head -1

note "cueval"
export PATH="$app/Contents/Resources/bin:/opt/homebrew/bin:$PATH" CUEVAL_CMUX_BIN="$cli" CUEVAL_CMUX_TAG=nightly
export CUEVAL_CMUX_CU_COMMAND="[\"$cli\", \"computer-use\", \"mcp\"]" CUEVAL_CLAUDE=/opt/homebrew/bin/claude
args=(--arms cmux-cu --agent claude --model opus --trials "$trials" --out "$work/out")
if [[ "$trials" == 3 && -z "$tasks" ]]; then
  args+=(--split all --prereg prereg-cu-hill-climb-macos.json
    --tasks "$("$py" -I -c 'import json; print(",".join(json.load(open("prereg-cu-hill-climb-macos.json"))["task_ids"]))' 2>/dev/null)")
else
  args+=(--split dev ${tasks:+--tasks "$tasks"})
fi
"$py" -I -c 'import json, sys; print(json.dumps({"nightly_build": sys.argv[1], "nightly_commit": sys.argv[2], "trials": int(sys.argv[3]), "args": sys.argv[4:]}))' \
  "$build" "$commit" "$trials" "${args[@]}" >"$facts"
started=$(date +%s)
(cd "$root/evals/computer-use" && "$py" -m cueval run "${args[@]}")
status=$?
echo "cueval exited $status after $(( $(date +%s) - started )) s"
cp "$work/out/results.jsonl" "$work/out/calls.jsonl" "$out/cueval/" 2>/dev/null
touch "$out/cueval/results.jsonl" "$out/cueval/calls.jsonl"
echo "$(wc -l <"$out/cueval/results.jsonl" | tr -d ' ') results"
finish
exit $status
