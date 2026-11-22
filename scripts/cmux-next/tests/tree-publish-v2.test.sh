#!/usr/bin/env bash
# CMUX-TUI-TREE-KEY-V2: the cmux-tui artifacts push publication writes the
# tree under its v2 key and then its v1 key. When v2 already holds a partial
# publication from another commit X (the repair case), completing v2 puts X's
# binaries into assets/tree; the v1 call must still publish THIS run's build
# (review F1). The Windows daemon: the other commit X predates the Windows
# target (it published no cmux-tui-windows/<X>/), so v2 gets THIS run's Windows build with
# completion-windows.json naming this run's commit; a second run reuses it.
# Runs the workflow step itself with the real trusted helper; a
# stub curl serves the CDN and a stub uploader writes into it. No network.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
# Every companion the publisher requires (macOS and Linux), from its own list.
# shellcheck disable=SC2207 # one name per line, no spaces
names=($(python3 "$ROOT/scripts/ci/publish-cmux-tui-tree.py" --list-companions))
# shellcheck disable=SC2207
windows_names=($(python3 "$ROOT/scripts/ci/publish-cmux-tui-tree.py" --list-windows-companions))

python3 - "$ROOT/.github/workflows/cmux-tui-artifacts.yml" "$TMP/publish.sh" <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in workflow["jobs"]["publish-tree"]["steps"]
            if s.get("name") == "Publish the complete tree with the trusted helper")
open(sys.argv[2], "w").write(step["run"])
PY

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$ROOT/scripts/ci/publish-cmux-tui-tree.py" "$src/scripts/ci/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo one > "$src/cmux-tui/a"
cdn="$TMP/cdn"
# The trusted uploader, write-once into the CDN directory.
cat > "$src/scripts/ci/upload-r2-object.py" <<PY
import argparse, pathlib, shutil, sys
parser = argparse.ArgumentParser()
parser.add_argument("--write-once", action="store_true")
for name in ("--file", "--endpoint-url", "--bucket", "--key", "--cache-control"):
    parser.add_argument(name)
args = parser.parse_args()
target = pathlib.Path("$cdn") / args.key.removeprefix("cmux-tui/")
if target.exists():
    sys.exit(0 if target.read_bytes() == pathlib.Path(args.file).read_bytes() else "write-once object differs: " + args.key)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy(args.file, target)
PY
git_q -C "$src" add -A
git_q -C "$src" commit -m one
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty-next
git_q -C "$src" commit -m gitlinks
run_sha=$(git -C "$src" rev-parse HEAD)
v2=$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2)
v1=$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v1)
other=1111111111111111111111111111111111111111

# This run's build (assets/tree) and its commit manifest.
mkdir -p "$src/assets/tree" "$cdn/$run_sha" "$cdn/$other" "$cdn/tree/$v2"
manifest() { # <commit> <dir> <names...> -> manifest.json on stdout
  local commit="$1" dir="$2" sep="" n; shift 2
  printf '{"commit": "%s", "binaries": {' "$commit"
  for n in "$@"; do printf '%s"%s": "%s"' "$sep" "$n" "$(sha "$dir/$n")"; sep=", "; done
  printf '}}\n'
}
for n in "${names[@]}"; do echo "run build $n" > "$src/assets/tree/$n"; echo "other build $n" > "$cdn/$other/$n"; done
for n in "${windows_names[@]}"; do echo "run build $n" > "$src/assets/tree/$n"; done
manifest "$run_sha" "$src/assets/tree" "${names[@]}" > "$cdn/$run_sha/manifest.json"
# The Windows daemon's own commit prefix: cmux-tui-windows/<sha>/ (served from $cdn/windows/).
mkdir -p "$cdn/windows/$run_sha"
manifest "$run_sha" "$src/assets/tree" "${windows_names[@]}" > "$cdn/windows/$run_sha/manifest.json"
manifest "$other" "$cdn/$other" "${names[@]}" > "$cdn/$other/manifest.json"
# v2: a partial publication by the other commit (source.json only). v1: nothing.
printf '{"key": "%s", "commit": "%s"}\n' "$v2" "$other" > "$cdn/tree/$v2/source.json"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
path="\${url%%\?*}"
case "\$path" in
  https://files.cmux.com/cmux-tui-windows/*) path="windows/\${path#https://files.cmux.com/cmux-tui-windows/}" ;;
  *) path="\${path#https://files.cmux.com/cmux-tui/}" ;;
esac
[[ "\$path" != "\${url%%\?*}" && -f "$cdn/\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
STUB
chmod +x "$TMP/bin/curl"

status=0
out=$(cd "$src" && env PATH="$TMP/bin:$PATH" GITHUB_SHA="$run_sha" GITHUB_RUN_ID=1 \
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=manaflow-ai/cmux R2_ENDPOINT=https://r2.test \
  KEY_V2="$v2" LEGACY_KEY="$v1" bash "$TMP/publish.sh" 2>&1) || status=$?
[[ "$status" == 0 ]] || fail "the publication failed (exit $status):" "$out"
for n in "${names[@]}"; do
  [[ "$(cat "$cdn/tree/$v2/$n")" == "other build $n" ]] || fail "v2 $n is not the other commit's build it was started with"
  [[ "$(cat "$cdn/tree/$v1/$n")" == "run build $n" ]] || fail "v1 $n is not this run's build"
done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["key"] == sys.argv[2] and d["commit"] == sys.argv[3], d' \
  "$cdn/tree/$v1/source.json" "$v1" "$run_sha" || fail "the v1 source.json does not name v1 and this run's commit"
[[ -f "$cdn/tree/$v1/completion.json" && -f "$cdn/tree/$v2/completion.json" ]] || fail "a completion manifest is missing"
for key in "$v2" "$v1"; do
  for n in "${windows_names[@]}"; do
    [[ "$(cat "$cdn/tree/$key/$n")" == "run build $n" ]] || fail "$key $n is not this run's Windows build"
    [[ "$(awk '{print $1}' "$cdn/tree/$key/$n.sha256")" == "$(sha "$cdn/tree/$key/$n")" ]] || fail "$key $n.sha256 is wrong"
  done
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["sourceCommit"] == sys.argv[2], d' \
    "$cdn/tree/$key/completion-windows.json" "$run_sha" || fail "$key completion-windows.json does not name this run's commit"
done

# A second run of the same commit completes nothing new and conflicts with nothing
# (its commit-addressed objects are published by then).
cp "$src"/assets/run/* "$cdn/$run_sha/"
out=$(cd "$src" && rm -rf assets/tree tree && mkdir -p assets/tree && cp "$src"/assets/run/* assets/tree/ && env PATH="$TMP/bin:$PATH" GITHUB_SHA="$run_sha" GITHUB_RUN_ID=2 \
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=manaflow-ai/cmux R2_ENDPOINT=https://r2.test \
  KEY_V2="$v2" LEGACY_KEY="$v1" bash "$TMP/publish.sh" 2>&1) || fail "the second publication failed:" "$out"

# The Windows build is optional: a run that built none (no cmux-tui-windows/<sha>/)
# publishes the macOS and Linux tree without Windows objects.
rm -rf "$cdn/tree" "$cdn/windows"
mkdir -p "$cdn/tree/$v2"
printf '{"key": "%s", "commit": "%s"}\n' "$v2" "$other" > "$cdn/tree/$v2/source.json"
for n in "${windows_names[@]}"; do rm -f "$src/assets/run/$n"; done
out=$(cd "$src" && rm -rf assets/tree tree && mkdir -p assets/tree && cp assets/run/* assets/tree/ && env PATH="$TMP/bin:$PATH" GITHUB_SHA="$run_sha" GITHUB_RUN_ID=3 \
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=manaflow-ai/cmux R2_ENDPOINT=https://r2.test \
  KEY_V2="$v2" LEGACY_KEY="$v1" bash "$TMP/publish.sh" 2>&1) || fail "a run without a Windows build failed:" "$out"
for key in "$v2" "$v1"; do
  [[ -f "$cdn/tree/$key/completion.json" ]] || fail "$key: no completion.json without Windows"
  [[ ! -e "$cdn/tree/$key/completion-windows.json" ]] || fail "$key: completion-windows.json without a Windows build"
  for n in "${windows_names[@]}"; do [[ ! -e "$cdn/tree/$key/$n" ]] || fail "$key: $n without a Windows build"; done
done
grep -q "published without the Windows daemon" <<<"$out" || fail "no warning for a tree without Windows:" "$out"

printf 'tree-publish-v2 tests: ok\n'
