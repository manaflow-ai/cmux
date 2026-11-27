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
if [[ -n "${GH_STUB_FAIL:-}" && "${GH_TOKEN:-}" != "${GH_STUB_GOOD_TOKEN:-unset}" ]]; then
  echo "gh: API rate limit exceeded for installation ID 1 (HTTP 403)" >&2
  exit 1
fi
# The caller's --jq turns the runs into id, status, conclusion, title rows; the stub serves them as such.
cat "$GH_STUB_ROWS"
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_STUB_LOG="$tmp/gh.log" GH_STUB_ROWS="$tmp/rows"
export GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=push GITHUB_RUN_ATTEMPT=1 BASE_AUTOFIX_WINDOW_NOW=1800000000
unset NEXT_BASE_AUTOFIX_WINDOW_MINUTES GH_STUB_FAIL GH_STUB_GOOD_TOKEN GH_TOKEN_FALLBACK
export GH_TOKEN=repo-token

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

# 4. Fail open: an unreadable list, a window of 0 or garbage, a dispatch and a re-run all run.
rows "499|completed|success|fix: a"
GH_STUB_FAIL=1 expect true "runs unreadable"
NEXT_BASE_AUTOFIX_WINDOW_MINUTES=0 expect true "window off"
NEXT_BASE_AUTOFIX_WINDOW_MINUTES=abc expect true "window off"
GITHUB_EVENT_NAME=workflow_dispatch expect true "event workflow_dispatch"
GITHUB_RUN_ATTEMPT=2 expect true "re-run"
[[ ! -s "$tmp/gh.log" ]] || fail "a re-run read GitHub: $(cat "$tmp/gh.log")"

# 4b. An unreadable list names gh's error; a fallback token (GH_TOKEN_FALLBACK) reads it instead and holds the run,
#     and a fallback that fails too still runs, naming both errors.
GH_STUB_FAIL=1 expect true "runs unreadable (fail open): gh: API rate limit exceeded for installation ID 1 (HTTP 403)"
GH_STUB_FAIL=1 GH_STUB_GOOD_TOKEN=app-token GH_TOKEN_FALLBACK=app-token expect false "run 499 ended success"
GH_STUB_FAIL=1 GH_STUB_GOOD_TOKEN=other GH_TOKEN_FALLBACK=app-token expect true "fallback token: gh: API rate limit"
out="$(GH_STUB_FAIL=1 decide)"
[[ "$(grep -c '^why=' <<<"$out")" == 1 && "$(wc -l <<<"$out")" == 2 ]] || fail "the error spills past one why line: $out"

# 5. The window is the variable's: 30 minutes asks from now - 30 min.
rows
NEXT_BASE_AUTOFIX_WINDOW_MINUTES=30 expect true "within the last 30 min"
grep -q 'created=%3E%3D2027-01-15T07:30:00Z' "$tmp/gh.log" || fail "30-minute window read: $(cat "$tmp/gh.log")"

echo "base-autofix-window: ok"
