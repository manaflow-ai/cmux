#!/usr/bin/env bash
# Coverage-guided, schema-structured fuzzing of the binary IPC on an idle fleet mini
# (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.7 and task 182). It runs the
# cmux-tui/fuzz targets frame_reader (cmux_ipc::FrameReader against a reference cutter)
# and dispatch_structured (the daemon's request dispatch, with REQUEST frames and bodies
# built from the schema's method table and request shapes) through
# scripts/cmux-next/rust-fuzz.sh, so the resource limits, seeds and finding verdicts are
# that script's. Then it measures the method-id coverage of the dispatch corpus and turns
# every finding into a fixture. Chromium runs its libFuzzer targets the same way, for
# hours on idle machines (ClusterFuzz), and keeps each crasher as a regression input.
#
# It reports; it is not a CI job and no CI runs it (Lawrence 2026-10-23). Agents run it on
# the fleet:
#   cmux-ci run --class isolated --ref SHA --script 'scripts/cmux-next/ipc-fuzz-fleet.sh --hours 8'
# Never on a person's Mac: it compiles cmux-tui.
#
# Usage: scripts/cmux-next/ipc-fuzz-fleet.sh [--hours N | --seconds N] [--targets A,B]
#            [--out DIR] [--build-only] [--coverage CORPUS_DIR]
#   --hours        fuzzing time per target, in hours (default 8). The targets run at once.
#   --seconds      fuzzing time per target, in seconds (a short check of the script).
#   --targets      default frame_reader,dispatch_structured.
#   --out          results directory (default artifacts/ipc-fuzz/<UTC>).
#   --build-only   build the targets and stop (acceptance: they build on the fleet).
#   --coverage     only measure the method-id coverage of a dispatch_structured corpus.
# Results in --out: rust-fuzz.sh's summary.jsonl, logs/ and artifacts/; corpus/<target>/
# (seeds plus what the run found); method-coverage.json; crashers.jsonl (one row per
# finding: target, verdict, fixture, repro); fixtures/cmux-tui/fuzz/corpus/<target>/
# regress-<verdict>-<sha1>, laid out as the repository, so `cp -R OUT/fixtures/. REPO`
# adds every crasher as a seed that each later run replays. File a task per crasher.
# Exit 0 when every target is clean and every method id of the table was routed, 1 on a
# finding or a coverage gap, 2 on a usage error, 75 when a tool, the build or a run failed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FUZZ_DIR="$REPO/cmux-tui/fuzz"
RUST_FUZZ="$REPO/scripts/cmux-next/rust-fuzz.sh"
DISPATCH=dispatch_structured

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# rust-fuzz.sh needs bash 4 (mapfile, wait -n); macOS ships 3.2 as /bin/bash.
BASH4=""
for candidate in "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [[ -x "$candidate" ]] && "$candidate" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
    BASH4="$candidate"
    break
  fi
done

SECONDS_PER_TARGET=$((8 * 3600)) TARGETS="frame_reader,$DISPATCH" OUT="" BUILD_ONLY=0 COVERAGE_ONLY=""

need_count() {
  [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "ipc-fuzz-fleet.sh: $1 needs a positive integer" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) need_count "$@"; SECONDS_PER_TARGET=$(( $2 * 3600 )); shift 2 ;;
    --seconds) need_count "$@"; SECONDS_PER_TARGET="$2"; shift 2 ;;
    --targets) [[ $# -ge 2 && -n "$2" ]] || usage; TARGETS="$2"; shift 2 ;;
    --out) [[ $# -ge 2 && -n "$2" ]] || usage; OUT="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --coverage) [[ $# -ge 2 && -n "$2" ]] || usage; COVERAGE_ONLY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "ipc-fuzz-fleet.sh: unknown argument '$1'" >&2; usage ;;
  esac
done

if [[ -z "$BASH4" ]]; then
  echo "ipc-fuzz-fleet.sh: rust-fuzz.sh needs bash 4 or later; none found (brew install bash)" >&2
  exit 75
fi

OUT="${OUT:-$REPO/artifacts/ipc-fuzz/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# The pinned nightly and cargo-fuzz, installed for this user when missing (a fleet mini is
# not set up by scripts/cmux-next/linux/setup-tools.sh). cargo-fuzz goes into a cache
# outside the checkout, never into the global cargo bin.
CHANNEL="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$FUZZ_DIR/rust-toolchain.toml")"
CARGO_FUZZ_VERSION="$(sed -n '/^\[cargo-install\]/,/^\[/s/^cargo-fuzz *= *"\(.*\)"/\1/p' \
  "$REPO/scripts/cmux-next/linux/tool-versions.toml")"
TOOLS="${CMUX_IPC_FUZZ_TOOLS:-$HOME/.cache/cmux/ipc-fuzz-tools}"
export PATH="$TOOLS/bin:$PATH"
if ! rustup run "$CHANNEL" rustc --version >/dev/null 2>&1; then
  echo "ipc-fuzz-fleet.sh: installing $CHANNEL"
  rustup toolchain install "$CHANNEL" --profile minimal --component llvm-tools >"$OUT/toolchain.log" 2>&1 || {
    tail -n 20 "$OUT/toolchain.log" >&2; echo "ipc-fuzz-fleet.sh: could not install $CHANNEL" >&2; exit 75; }
fi
if ! command -v cargo-fuzz >/dev/null; then
  echo "ipc-fuzz-fleet.sh: installing cargo-fuzz $CARGO_FUZZ_VERSION into $TOOLS"
  cargo install --locked "cargo-fuzz@$CARGO_FUZZ_VERSION" --root "$TOOLS" >"$OUT/cargo-fuzz.log" 2>&1 || {
    tail -n 20 "$OUT/cargo-fuzz.log" >&2; echo "ipc-fuzz-fleet.sh: could not install cargo-fuzz" >&2; exit 75; }
fi
# cmux-tui-core links libghostty-vt, built from the ghostty-next submodule.
if [[ -z "${CMUX_GHOSTTY_SRC:-}" && ! -f "$REPO/ghostty-next/build.zig" ]]; then
  git -C "$REPO" submodule update --init ghostty-next >"$OUT/submodule.log" 2>&1 || {
    tail -n 20 "$OUT/submodule.log" >&2; echo "ipc-fuzz-fleet.sh: ghostty-next is missing" >&2; exit 75; }
fi

# The method ids the dispatch corpus routed and decoded, against the table the target
# prints (CMUX_IPC_FUZZ_COVERAGE=1, one libFuzzer pass over the corpus, no mutation).
# Exit 0 at 100% routed, 1 below, 75 when the pass failed.
# It runs the binary rust-fuzz.sh built (cargo fuzz build is then a no-op), not cargo fuzz
# run, which rebuilds when the git index changed (cmux-build-identity).
coverage() {
  local corpus="$1" log="$OUT/logs/coverage-$DISPATCH.log" host binary
  mkdir -p "$OUT/logs"
  if ! (cd "$FUZZ_DIR" && cargo fuzz build "$DISPATCH" --fuzz-dir . --sanitizer address) \
      >"$OUT/logs/coverage-build.log" 2>&1; then
    tail -n 40 "$OUT/logs/coverage-build.log" >&2
    echo "ipc-fuzz-fleet.sh: $DISPATCH did not build" >&2
    return 75
  fi
  host="$(cd "$FUZZ_DIR" && rustc -vV | sed -n 's/^host: //p')"
  binary="${CARGO_TARGET_DIR:-$FUZZ_DIR/target}/$host/release/$DISPATCH"
  if ! CMUX_IPC_FUZZ_COVERAGE=1 "$binary" "$corpus" -runs=0 -rss_limit_mb=2048 -timeout=10 \
      >"$log" 2>&1; then
    tail -n 40 "$log" >&2
    echo "ipc-fuzz-fleet.sh: the coverage pass over $corpus failed (log $log)" >&2
    return 75
  fi
  python3 -I - "$log" "$OUT/method-coverage.json" <<'PY'
import json, re, sys

log, out = sys.argv[1:]
table, routed, decoded = {}, set(), set()
for line in open(log, errors="replace"):
    if m := re.match(r"cmux-ipc-fuzz table-method=0x([0-9a-f]{4}) name=(\S+)", line):
        table[int(m.group(1), 16)] = m.group(2)
    elif m := re.match(r"cmux-ipc-fuzz method=0x([0-9a-f]{4}) routed=([01]) decoded=([01])", line):
        method = int(m.group(1), 16)
        if m.group(2) == "1":
            routed.add(method)
        if m.group(3) == "1":
            decoded.add(method)
if not table:
    print("ipc-fuzz-fleet.sh: the coverage pass printed no method table", file=sys.stderr)
    sys.exit(75)
missing = sorted(set(table) - routed)
undecoded = sorted(set(table) - decoded)
percent = lambda part: round(100.0 * len(part & set(table)) / len(table), 1)
row = {
    "methods": len(table),
    "routed": len(routed & set(table)), "routed_percent": percent(routed),
    "decoded": len(decoded & set(table)), "decoded_percent": percent(decoded),
    "not_routed": [f"0x{m:04x} {table[m]}" for m in missing],
    "not_decoded": [f"0x{m:04x} {table[m]}" for m in undecoded],
}
json.dump(row, open(out, "w"), indent=2)
print(f"method-id coverage: routed {row['routed']}/{row['methods']} ({row['routed_percent']}%), "
      f"decoded {row['decoded']}/{row['methods']} ({row['decoded_percent']}%); {out}")
for method in row["not_routed"]:
    print(f"  not routed: {method}")
sys.exit(1 if missing else 0)
PY
}

if [[ -n "$COVERAGE_ONLY" ]]; then
  [[ -d "$COVERAGE_ONLY" ]] || { echo "ipc-fuzz-fleet.sh: no corpus at $COVERAGE_ONLY" >&2; exit 2; }
  status=0
  coverage "$(cd "$COVERAGE_ONLY" && pwd)" || status=$?
  exit "$status"
fi

if [[ "$BUILD_ONLY" == 1 ]]; then
  exec "$BASH4" "$RUST_FUZZ" --target "$TARGETS" --build-only --out "$OUT"
fi

IFS=, read -r -a SELECTED <<<"$TARGETS"
fuzz_status=0
"$BASH4" "$RUST_FUZZ" --target "$TARGETS" --seconds "$SECONDS_PER_TARGET" \
  --parallel "${#SELECTED[@]}" --out "$OUT" || fuzz_status=$?
if [[ "$fuzz_status" != 0 && "$fuzz_status" != 1 ]]; then
  echo "ipc-fuzz-fleet.sh: rust-fuzz.sh exited $fuzz_status (no verdict for every target)" >&2
fi

coverage_status=0
if [[ ",$TARGETS," == *",$DISPATCH,"* ]]; then
  coverage "$OUT/corpus/$DISPATCH" || coverage_status=$?
fi

# Every finding becomes a fixture under the repository's corpus layout, and a row with the
# command that replays it.
python3 -I - "$OUT" <<'PY'
import hashlib, json, pathlib, shutil, sys

out = pathlib.Path(sys.argv[1])
summary = out / "summary.jsonl"
rows = [json.loads(line) for line in summary.read_text().splitlines() if line.strip()] if summary.exists() else []
with open(out / "crashers.jsonl", "w") as crashers:
    for row in rows:
        if row["verdict"] not in ("crash", "oom", "timeout", "leak") or not row.get("artifact"):
            continue
        artifact = pathlib.Path(row["artifact"])
        digest = hashlib.sha1(artifact.read_bytes()).hexdigest()
        relative = pathlib.Path("cmux-tui/fuzz/corpus") / row["target"] / f"regress-{row['verdict']}-{digest}"
        fixture = out / "fixtures" / relative
        fixture.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(artifact, fixture)
        entry = {"target": row["target"], "verdict": row["verdict"], "fixture": str(relative),
                 "repro": f"cd cmux-tui/fuzz && cargo fuzz run {row['target']} {relative.relative_to('cmux-tui/fuzz')}"}
        crashers.write(json.dumps(entry) + "\n")
        print(f"crasher: {row['target']} {row['verdict']} -> {relative} (file a task; replay: {entry['repro']})")
PY

if [[ "$fuzz_status" != 0 && "$fuzz_status" != 1 ]]; then
  exit 75
fi
if [[ "$coverage_status" == 75 ]]; then
  exit 75
fi
if [[ "$fuzz_status" == 1 || "$coverage_status" == 1 ]]; then
  exit 1
fi
echo "ipc-fuzz-fleet.sh: clean; results in $OUT"
