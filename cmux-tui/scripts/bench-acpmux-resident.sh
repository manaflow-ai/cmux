#!/usr/bin/env bash
# Run through cmux-ci test, in its disposable checkout, with warm Cargo caches.
# Only the daemon sources vary; one final-head fixture/executable measures both builds.
set -euo pipefail

before=${1:?usage: bench-acpmux-resident.sh BEFORE_SHA}
repo=$(git rev-parse --show-toplevel)
after=$(git rev-parse HEAD)
out=${FAST_CHECKS_OUT:?run through cmux-ci test with an artifact directory}
cd "$repo"
git cat-file -e "$before^{commit}"
git diff --quiet

mapfile -t sources < <(git diff --name-only "$before" "$after" -- cmux-tui/crates/acpmux/src)
restore() {
    git -C "$repo" restore --source="$after" -- "${sources[@]}"
}
trap restore EXIT
for source in "${sources[@]}"; do
    if git cat-file -e "$before:$source" 2>/dev/null; then
        git show "$before:$source" > "$source"
    fi
done
cd cmux-tui
cargo build --locked --release -p acpmux --bin acpmux
target=$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
cp "$target/release/acpmux" "$out/acpmux-before"
cd "$repo"
restore
cd cmux-tui
cargo build --locked --release -p acpmux --bin acpmux
cp "$target/release/acpmux" "$out/acpmux-after"
cargo test --locked --release -p acpmux --test daemon_memory --no-run --message-format=json > "$out/build.jsonl"
test_exe=$(python3 - "$out/build.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    record = json.loads(line)
    if record.get("target", {}).get("name") == "daemon_memory" and record.get("executable"):
        print(record["executable"])
PY
)
test -x "$test_exe"
python3 - "$before" "$after" > "$out/sources.json" <<'PY'
import json, platform, sys
print(json.dumps({"before": sys.argv[1], "after": sys.argv[2], "profile": "release",
                  "host": platform.node(), "platform": platform.platform()}))
PY
for pass in 1 2; do
    for phase in before after; do
        ACPMUX_MEMORY_BENCH_BINARY="$out/acpmux-$phase" "$test_exe" \
            idle_session_resident_memory_benchmark --ignored --exact --nocapture --test-threads=1 \
            | tee "$out/resident-$phase-$pass.log"
    done
done
cargo test --locked --release -p acpmux --lib -- shared_value model_options full_access preset_bind policy_mode deferred log_deferral
cargo test --locked --release -p acpmux --test hub_integration -- fork_before
cargo test --locked --release -p acpmux --test hermetic_daemon_guard
