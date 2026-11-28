#!/usr/bin/env bash
# rustc-heavy-lock.sh runs the heavy crates (acpmux, cmux_tui_core) one at a time and every other crate at once:
# on cloud-journey-pr.yml's 14 GiB runner the two overlapping rustc went past the runner's memory and the kernel
# SIGKILLed acpmux (run 46147374990, 2026-11-28). A fake rustc logs when each call starts and ends.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wrapper="$here/../rustc-heavy-lock.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/rustc" <<'EOF'
#!/usr/bin/env bash
name=""; prev=""
for a in "$@"; do [ "$prev" = "--crate-name" ] && name="$a"; prev="$a"; done
echo "start $name" >> "$LOG"; sleep 1; echo "end $name" >> "$LOG"
[ "$name" = "fails" ] && exit 7
exit 0
EOF
chmod +x "$tmp/rustc"
export LOG="$tmp/log" RUSTC_HEAVY_LOCK="$tmp/lock"

overlapped() { # 0 when the two named calls ran at the same time
  awk -v a="$1" -v b="$2" '$1=="start"{on[$2]=1; if (on[a] && on[b]) hit=1} $1=="end"{on[$2]=0} END{exit hit?0:1}' "$LOG"
}

# 1. The two heavy crates never overlap.
: > "$LOG"
"$wrapper" "$tmp/rustc" --crate-name acpmux --edition=2024 & p1=$!
"$wrapper" "$tmp/rustc" --crate-name cmux_tui_core --edition=2024 & p2=$!
wait "$p1" "$p2"
if overlapped acpmux cmux_tui_core; then echo "FAIL: acpmux and cmux_tui_core overlapped"; cat "$LOG"; exit 1; fi

# 2. Other crates still run at once, beside a heavy one too.
: > "$LOG"
"$wrapper" "$tmp/rustc" --crate-name acpmux & p1=$!
"$wrapper" "$tmp/rustc" --crate-name tokio & p2=$!
"$wrapper" "$tmp/rustc" --crate-name naga & p3=$!
wait "$p1" "$p2" "$p3"
overlapped tokio naga || { echo "FAIL: tokio and naga were serialized"; cat "$LOG"; exit 1; }
overlapped acpmux tokio || { echo "FAIL: tokio waited on acpmux"; cat "$LOG"; exit 1; }

# 3. rustc's exit status and cargo's version probe (no --crate-name) pass through.
set +e
"$wrapper" "$tmp/rustc" --crate-name fails; rc=$?
set -e
[ "$rc" = 7 ] || { echo "FAIL: exit status $rc, want 7"; exit 1; }
"$wrapper" "$tmp/rustc" -vV || { echo "FAIL: version probe"; exit 1; }

# 4. RUSTC_HEAVY_CRATES replaces the list.
: > "$LOG"
RUSTC_HEAVY_CRATES="tokio naga" "$wrapper" "$tmp/rustc" --crate-name tokio & p1=$!
RUSTC_HEAVY_CRATES="tokio naga" "$wrapper" "$tmp/rustc" --crate-name naga & p2=$!
wait "$p1" "$p2"
if overlapped tokio naga; then echo "FAIL: RUSTC_HEAVY_CRATES ignored"; cat "$LOG"; exit 1; fi

echo "rustc-heavy-lock: 4 cases pass"
