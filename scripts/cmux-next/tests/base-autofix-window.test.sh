#!/usr/bin/env bash
# The base autofix window (base-autofix-window.sh): at most one run repairs per window; every other push run is
# held, and anything the gate can't judge runs as before. gh is a stub that serves a fixed runs list.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-window.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_LOG"
[[ -n "${GH_STUB_FAIL:-}" ]] && { echo "HTTP 403: API rate limit exceeded" >&2; exit 1; }
for t in ${GH_STUB_FAIL_TOKENS:-}; do [[ "$t" == "${GH_TOKEN:-}" ]] && { echo "HTTP 403: rate limit" >&2; exit 1; }; done
# The caller's --jq turns the runs into id, status, conclusion, title rows; the stub serves them as such.
cat "$GH_STUB_ROWS"
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_STUB_LOG="$tmp/gh.log" GH_STUB_ROWS="$tmp/rows"
export GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=push GITHUB_RUN_ATTEMPT=1 BASE_AUTOFIX_WINDOW_NOW=1800000000
unset NEXT_BASE_AUTOFIX_WINDOW_MINUTES BASE_AUTOFIX_CARGO_CHANGED GH_STUB_FAIL GH_STUB_FAIL_TOKENS BASE_AUTOFIX_POOL_TOKENS
export GH_TOKEN=job

rows() { printf '%s\n' "$@" | tr '|' '\037' > "$tmp/rows"; }
decide() { : > "$tmp/gh.log"; bash "$script" 500 feat-cmux-next; }
expect() { # expect RUN WHY_SUBSTRING
  local out; out="$(decide)"
  grep -qx "run=$1" <<<"$out" || fail "want run=$1 ($2): $out"
  grep -q "^why=.*$2" <<<"$out" || fail "want why naming '$2': $out"
}

# 1. No run in the window: this one repairs; the read asks for push runs on the branch since now - 120 min.
rows
expect true "no run repaired within the last 120 min"
grep -q 'actions/workflows/cmux-next-base-autofix.yml/runs?branch=feat-cmux-next&event=push&created=%3E%3D2027-01-15T06:00:00Z' "$tmp/gh.log" \
  || fail "the read names the wrong window: $(cat "$tmp/gh.log")"

# 2. An older run that repaired (green or red) holds this one; so does one still in flight.
rows "499|completed|success|fix: a thing"
expect false "run 499 ended success"
rows "480|completed|failure|fix: a thing"
expect false "run 480 ended failure"
rows "499|in_progress||fix: b"
expect false "run 499 is in flight"
rows "499|queued||fix: b"
expect false "run 499 is in flight"

# 3. Held (cancelled) and skipped runs, the bot's own repair pushes and newer runs never hold it.
rows "499|completed|cancelled|fix: a" "498|completed|skipped|fix: b" \
  "497|completed|success|chore(next): base autofix at 0123456789ab" \
  "496|in_progress||chore(next): pin GhosttyKit for ghostty 0123456789ab" \
  "501|in_progress||fix: newer" "502|completed|success|fix: newer"
expect true "no run repaired"

# 3b. A held run whose cancel was refused ends success (or failure) in seconds: it repaired nothing, so it never holds
#     this one (2026-11-27: each such run held the next and nothing repaired for 7 h). A long run still holds.
rows "499|completed|success|fix: a|95" "498|completed|failure|fix: b|11"
expect true "no run repaired"
rows "499|completed|success|fix: a|95" "498|completed|success|fix: b|2300"
expect false "run 498 ended success"
rows "499|completed|failure|fix: a|2355"
expect false "run 499 ended failure"
rows "499|completed|success|fix: a|95"
NEXT_BASE_AUTOFIX_HELD_MAX_SECONDS=60 expect false "run 499 ended success"
NEXT_BASE_AUTOFIX_HELD_MAX_SECONDS=junk expect true "no run repaired"
rows "499|in_progress||fix: a|"
expect false "run 499 is in flight"

# 4. Fail open: an unreadable list, a window of 0 or garbage, a dispatch and a re-run all run.
rows "499|completed|success|fix: a"
GH_STUB_FAIL=1 expect true "runs unreadable"
GH_STUB_FAIL=1 GH_TOKEN="" expect true "no token"

# 4b. A refused job token falls through to the CI pool tokens, in order; the first that reads decides.
rows "499|completed|success|fix: a"
GH_TOKEN=job BASE_AUTOFIX_POOL_TOKENS="pool1 pool2" GH_STUB_FAIL_TOKENS="job pool1" expect false "run 499 ended success"
[[ "$(grep -c . "$tmp/gh.log")" == 3 ]] || fail "want three reads (job, pool1, pool2): $(cat "$tmp/gh.log")"
GH_TOKEN=job BASE_AUTOFIX_POOL_TOKENS="pool1 pool2" GH_STUB_FAIL_TOKENS="job pool1 pool2" expect true "runs unreadable"
GH_TOKEN=job BASE_AUTOFIX_POOL_TOKENS="pool1" expect false "run 499 ended success"
[[ "$(grep -c . "$tmp/gh.log")" == 1 ]] || fail "a job token that reads asks no pool token: $(cat "$tmp/gh.log")"
NEXT_BASE_AUTOFIX_WINDOW_MINUTES=0 expect true "window off"
NEXT_BASE_AUTOFIX_WINDOW_MINUTES=abc expect true "window off"
GITHUB_EVENT_NAME=workflow_dispatch expect true "event workflow_dispatch"
GITHUB_RUN_ATTEMPT=2 expect true "re-run"
[[ ! -s "$tmp/gh.log" ]] || fail "a re-run read GitHub: $(cat "$tmp/gh.log")"

# 5. The window is the variable's: 30 minutes asks from now - 30 min.
rows
NEXT_BASE_AUTOFIX_WINDOW_MINUTES=30 expect true "within the last 30 min"
grep -q 'created=%3E%3D2027-01-15T07:30:00Z' "$tmp/gh.log" || fail "30-minute window read: $(cat "$tmp/gh.log")"

# 6. A push that changes a Cargo file repairs now, whatever repaired within the window (cmux#57132: one lock of five
#    updated, every --locked build red until the window let a repair run). Anything but "true" is held as before.
rows "499|completed|success|fix: a" "498|in_progress||fix: b"
BASE_AUTOFIX_CARGO_CHANGED=true expect true "changes a Cargo.toml or Cargo.lock"
[[ ! -s "$tmp/gh.log" ]] || fail "a Cargo push read GitHub: $(cat "$tmp/gh.log")"
BASE_AUTOFIX_CARGO_CHANGED=false expect false "run 499 ended success"
BASE_AUTOFIX_CARGO_CHANGED="" expect false "run 499 ended success"

echo "base-autofix-window: ok"
