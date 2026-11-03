#!/usr/bin/env bash
# Run the real build-only entry with stand-in native tools. No app compile.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tree/scripts/measure" "$tmp/tree/GhosttyKit.xcframework" "$tmp/bin"
cp "$repo/scripts/measure/split-spring.sh" "$tmp/tree/scripts/measure/"
touch "$tmp/tree/GhosttyKit.xcframework/Info.plist"
cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'rev-parse --show-toplevel') pwd ;;
  'rev-parse HEAD') echo 0123456789abcdef0123456789abcdef01234567 ;;
  *) echo "git $*" >> "$CALLS" ;;
esac
EOF
cat > "$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo "python3 $*" >> "$CALLS"
EOF
cat > "$tmp/bin/ditto" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$2"
EOF
cat > "$tmp/tree/scripts/reload.sh" <<'EOF'
#!/usr/bin/env bash
echo "reload $* zig=${CMUX_SKIP_ZIG_BUILD:-0} cua=${CMUX_NEXT_SKIP_CUA_HELPER:-0} rb=${CMUX_NEXT_SKIP_RB_HOST:-0}" >> "$CALLS"
mkdir -p "$PWD/app"
printf 'App path:\n  %s/app\n' "$PWD"
EOF
chmod +x "$tmp/bin/"* "$tmp/tree/scripts/reload.sh"
export CALLS="$tmp/calls" CI_SHARED_CACHE_DIR="$tmp/cache" PATH="$tmp/bin:$PATH"
unset CMUX_SKIP_ZIG_BUILD CMUX_NEXT_SKIP_CUA_HELPER CMUX_NEXT_SKIP_RB_HOST
run() {
  : > "$CALLS"
  (cd "$tmp/tree" && bash scripts/measure/split-spring.sh --build-only "$@") > "$tmp/output" 2>&1 || { cat "$tmp/output"; exit 1; }
}
run --suite=idle-budget
grep -q 'reload --tag split-spring-idle zig=1 cua=1 rb=1' "$CALLS"
grep -q 'split-spring-submodules.py --cache .* ghostty ghostty-next' "$CALLS"
test -f "$CI_SHARED_CACHE_DIR/split-spring-apps/0123456789abcdef0123456789abcdef01234567-idle-v5/ok"
run --suite=budgets
grep -q 'reload --tag split-spring zig=0 cua=0 rb=0' "$CALLS"
test -f "$CI_SHARED_CACHE_DIR/split-spring-apps/0123456789abcdef0123456789abcdef01234567/ok"
run --suite=idle-budget
! grep -q '^reload\|^python3' "$CALLS" # cached idle app avoids all setup

# The post-Xcode fallback must honor the same explicit CUA skip as the embed
# phase; otherwise the idle build still compiles a helper it never starts.
sed -n '/^CMUX_CUA_HELPER_APP=/,/^# A dev build uses/{ /^# A dev build uses/!p; }' "$repo/scripts/reload.sh" > "$tmp/cua-fallback.sh"
cat > "$tmp/tree/scripts/build-cmux-cua.sh" <<'EOF'
#!/usr/bin/env bash
echo cua-built >> "$CALLS"
EOF
chmod +x "$tmp/tree/scripts/build-cmux-cua.sh"
: > "$CALLS"
(cd "$tmp/tree" && APP_PATH="$tmp/app" CMUX_NEXT_SKIP_CUA_HELPER=1 bash "$tmp/cua-fallback.sh")
! grep -q cua-built "$CALLS"
(cd "$tmp/tree" && APP_PATH="$tmp/app" bash "$tmp/cua-fallback.sh")
grep -q cua-built "$CALLS"
echo 'split-spring idle build profile and helper fallback: ok'
