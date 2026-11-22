#!/usr/bin/env bash
# Run the library test binaries of a set of packages at once, one process per package, and print their
# logs one after another as `cargo test --lib --no-fail-fast` would: a `Running` line, the binary's own
# libtest output, and cargo's `error: test failed` lines when it fails.
#
# usage: cargo-lib-tests-at-once.sh LOGDIR CARGO_TEST_ARGS...
#   CARGO_TEST_ARGS are the `cargo test` arguments that select the packages (`--locked -p a -p b`);
#   `--lib --no-run --message-format=json` is added to list the built binaries (a fresh build: the
#   caller builds first with the same packages, so cargo resolves the same features and rebuilds nothing).
#
# Why: `cargo test --lib` runs one package's binary after another, so acpmux-tests sat behind acpmux's
# lib (~431 s) and then acpmux-book's (~208 s) while the host was mostly idle behind each binary's slowest
# few tests (job 137180420737, 2026-11-22). Run at once, the libraries take as long as the slowest one.
# Each binary runs as cargo runs it: from its package's directory, with CARGO_MANIFEST_DIR, CARGO_PKG_NAME
# and CARGO set. CMUX_LIB_TESTS_SERIAL=1 runs them one after another (today's order and timing) instead.
# Exit status: 0 when every binary passed, 101 (cargo's) when any failed, 1 when none was listed.
set -uo pipefail

logdir="${1:?usage: cargo-lib-tests-at-once.sh LOGDIR CARGO_TEST_ARGS...}"
shift
mkdir -p "$logdir"
list="$logdir/binaries.tsv"
cargo test "$@" --lib --no-run --message-format=json 2>"$logdir/list.err" | python3 -c '
import json, os, sys, tomllib
seen = set()
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    exe = msg.get("executable")
    if msg.get("reason") != "compiler-artifact" or not exe or not msg.get("profile", {}).get("test"):
        continue
    if exe in seen:
        continue
    seen.add(exe)
    target = msg["target"]
    root = os.path.dirname(msg["manifest_path"])
    src = os.path.relpath(target["src_path"], root)
    with open(msg["manifest_path"], "rb") as f:
        package = tomllib.load(f)["package"]["name"]
    print("\t".join((target["name"], exe, root, src, package)))
' | sort > "$list"
if [[ ! -s "$list" ]]; then
  cat "$logdir/list.err" >&2
  echo "cargo-lib-tests-at-once: cargo listed no library test binary for: $*" >&2
  exit 1
fi

names=() exes=() roots=() srcs=() pkgs=() pids=() codes=()
while IFS=$'\t' read -r name exe root src pkg; do
  names+=("$name") exes+=("$exe") roots+=("$root") srcs+=("$src") pkgs+=("$pkg")
done < "$list"

run_one() {
  local i="$1"
  (
    cd "${roots[i]}" || exit 1
    CARGO_MANIFEST_DIR="${roots[i]}" CARGO_PKG_NAME="${pkgs[i]}" \
      CARGO="${CARGO:-$(command -v cargo)}" exec "${exes[i]}"
  ) > "$logdir/$i.log" 2>&1
}

for i in "${!exes[@]}"; do
  if [[ "${CMUX_LIB_TESTS_SERIAL:-}" == 1 ]]; then
    code=0
    run_one "$i" || code=$?
    codes[i]=$code
  else
    run_one "$i" &
    pids[i]=$!
  fi
done

failed=0
for i in "${!exes[@]}"; do
  if [[ "${CMUX_LIB_TESTS_SERIAL:-}" != 1 ]]; then
    code=0
    wait "${pids[i]}" || code=$?
    codes[i]=$code
  fi
  rel="${exes[i]}"
  [[ "$rel" == "$PWD/"* ]] && rel="${rel#"$PWD/"}"
  echo "     Running unittests ${srcs[i]} ($rel)"
  cat "$logdir/$i.log"
  code="${codes[i]}"
  if (( code != 0 )); then
    failed=1
    echo "error: test failed, to rerun pass \`-p ${pkgs[i]} --lib\`"
    echo
    echo "Caused by:"
    if (( code > 128 )); then
      echo "  process didn't exit successfully: \`${exes[i]}\` (signal: $((code - 128)))"
    else
      echo "  process didn't exit successfully: \`${exes[i]}\` (exit status: $code)"
    fi
  fi
done
(( failed == 0 )) || exit 101
