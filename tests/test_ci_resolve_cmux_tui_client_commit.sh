#!/usr/bin/env bash
# Guards scripts/ci/resolve-cmux-tui-client-commit.sh, which the nightly and release
# workflows use to pick the cmux-tui client build to bundle.
#
# Regression: actions/checkout clones with depth 1. In a one-commit history the grafted
# root shows every file as added, so `git log -1 -- cmux-tui` answers HEAD whether or
# not HEAD touched cmux-tui. HEAD only has a published client when it touched cmux-tui,
# so the manifest download returned 404 on almost every push (nightly runs 33941558929
# and 33943122606 died in "Bundle the cmux-tui client" with `curl: (56) ... 404`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/ci/resolve-cmux-tui-client-commit.sh"
if [[ ! -x "$RESOLVER" ]]; then
  echo "FAIL: missing executable $RESOLVER"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=cmux-test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=cmux-test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git init -q "$TMP/src"
git -C "$TMP/src" checkout -q -b main
commit_touching() {
  mkdir -p "$(dirname "$TMP/src/$2")"
  echo "$1" >"$TMP/src/$2"
  git -C "$TMP/src" add -A
  git -C "$TMP/src" commit -q -m "$1"
  git -C "$TMP/src" rev-parse HEAD
}
C1="$(commit_touching "tui one" cmux-tui/src/main.rs)"
C2="$(commit_touching "app change" Sources/App.swift)"
C3="$(commit_touching "tui two" cmux-tui/src/lib.rs)"
C4="$(commit_touching "docs" docs/notes.md)"
C5="$(commit_touching "web" web/app.ts)"
: "$C2" "$C4"

# The artifact store: only C1 and C3 have a published client, like main after an
# artifacts run that only exists for commits touching cmux-tui.
STORE="$TMP/store"
mkdir -p "$STORE/$C1" "$STORE/$C3"
printf '{"commit":"%s"}\n' "$C1" >"$STORE/$C1/manifest.json"
printf '{"commit":"%s"}\n' "$C3" >"$STORE/$C3/manifest.json"
export CMUX_TUI_CLIENT_MANIFEST_BASE="file://$STORE"

git clone -q --depth 1 "file://$TMP/src" "$TMP/work"

# This is the bug the resolver exists for: a depth-1 clone answers HEAD.
naive="$(git -C "$TMP/work" log -1 --format=%H -- cmux-tui)"
if [[ "$naive" != "$C5" ]]; then
  echo "FAIL: expected the depth-1 clone to answer HEAD ($C5) for the naive query, got $naive"
  exit 1
fi

got="$(cd "$TMP/work" && "$RESOLVER")"
if [[ "$got" != "$C3" ]]; then
  echo "FAIL: shallow clone must resolve the newest published cmux-tui commit $C3, got '$got'"
  exit 1
fi

# The newest cmux-tui commit lost its artifacts (failed or still-running artifacts run).
rm "$STORE/$C3/manifest.json"
if (cd "$TMP/work" && "$RESOLVER" >/dev/null 2>&1); then
  echo "FAIL: exact mode must fail when the newest cmux-tui commit has no published client"
  exit 1
fi
got="$(cd "$TMP/work" && "$RESOLVER" --max-fallback 3 2>"$TMP/fallback.err")"
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: fallback must pick the previous published commit $C1, got '$got'"
  exit 1
fi
if ! grep -q '^::warning' "$TMP/fallback.err"; then
  echo "FAIL: a fallback must annotate the run with a ::warning"
  exit 1
fi

# A leading zero is decimal, not octal: 08 means eight, not a Bash arithmetic error.
got="$(cd "$TMP/work" && "$RESOLVER" --max-fallback 08 2>/dev/null)"
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: --max-fallback 08 must be read as decimal 8 and resolve $C1, got '$got'"
  exit 1
fi

# A full clone takes the same decision without deepening.
git clone -q "file://$TMP/src" "$TMP/full"
got="$(cd "$TMP/full" && "$RESOLVER" --max-fallback 3 2>/dev/null)"
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: full clone must resolve $C1, got '$got'"
  exit 1
fi

# A transient network failure while deepening (DNS blip, connection reset) must not
# fail the run: release run 34851108495 died in "Install universal Ghostty CLI helper"
# with `Could not resolve host: github.com` on its first --deepen and never retried.
# The ext:: remote below fails its first two upload-pack invocations, then serves
# normally, so a single attempt fails and a bounded retry succeeds.
FLAKY="$TMP/flaky-upload-pack"
cat >"$FLAKY" <<EOF
#!/usr/bin/env bash
left="\$(cat "$TMP/failures-left" 2>/dev/null || echo 0)"
if [[ "\$left" -gt 0 ]]; then
  echo \$((left - 1)) >"$TMP/failures-left"
  echo "fatal: unable to access 'https://github.com/manaflow-ai/cmux/': Could not resolve host: github.com" >&2
  exit 128
fi
exec git upload-pack "$TMP/src"
EOF
chmod +x "$FLAKY"
printf '{"commit":"%s"}\n' "$C3" >"$STORE/$C3/manifest.json"
git clone -q --depth 1 "file://$TMP/src" "$TMP/flaky-work"
git -C "$TMP/flaky-work" config protocol.ext.allow always
git -C "$TMP/flaky-work" remote set-url origin "ext::$FLAKY"

echo 2 >"$TMP/failures-left"
if (cd "$TMP/flaky-work" && CMUX_TUI_CLIENT_FETCH_ATTEMPTS=1 CMUX_TUI_CLIENT_FETCH_RETRY_SECONDS=0 "$RESOLVER" >/dev/null 2>&1); then
  echo "FAIL: with a single fetch attempt the flaky remote must make the resolver fail (test setup)"
  exit 1
fi
# An all-zero attempt count is rejected like a bare 0, not normalized into "zero attempts".
# (An empty value means unset and takes the default, so it is not in this list.)
for bad in 0 00 x; do
  if (cd "$TMP/flaky-work" && CMUX_TUI_CLIENT_FETCH_ATTEMPTS="$bad" "$RESOLVER" >/dev/null 2>&1); then
    echo "FAIL: CMUX_TUI_CLIENT_FETCH_ATTEMPTS='$bad' must be rejected"
    exit 1
  fi
  (cd "$TMP/flaky-work" && CMUX_TUI_CLIENT_FETCH_ATTEMPTS="$bad" "$RESOLVER" >/dev/null 2>&1) || rc=$?
  if [[ "${rc:-0}" != 64 ]]; then
    echo "FAIL: CMUX_TUI_CLIENT_FETCH_ATTEMPTS='$bad' must exit 64 (usage error), got ${rc:-0}"
    exit 1
  fi
  unset rc
done

echo 2 >"$TMP/failures-left"
got="$(cd "$TMP/flaky-work" && CMUX_TUI_CLIENT_FETCH_RETRY_SECONDS=0 "$RESOLVER" 2>"$TMP/flaky.err" || true)"
if [[ "$got" != "$C3" ]]; then
  echo "FAIL: transient deepen failures must be retried and resolve $C3, got '$got'"
  cat "$TMP/flaky.err"
  exit 1
fi
if ! grep -q 'retrying' "$TMP/flaky.err"; then
  echo "FAIL: a retried deepen must say so in the diagnostics"
  exit 1
fi

# A missing manifest is definitive: the walk past it must not sleep through retries.
# curl --retry-all-errors retried every 404 five times, 3 s apart, so each unpublished
# candidate cost 15 s here and in every release and nightly fallback.
rm "$STORE/$C3/manifest.json"
started=$SECONDS
got="$(cd "$TMP/full" && "$RESOLVER" --max-fallback 3 2>/dev/null)"
elapsed=$((SECONDS - started))
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: fallback past a missing manifest must resolve $C1, got '$got'"
  exit 1
fi
# The old behaviour took at least 15 s; the bound leaves room for a loaded runner.
if [[ $elapsed -gt 10 ]]; then
  echo "FAIL: skipping a missing manifest took ${elapsed}s; a 404 must not be retried"
  exit 1
fi

# The curl shim replays one scripted outcome per call from $TMP/curl-script, then runs
# the real curl once the script is empty: `dns` fails like a DNS blip (exit 6), and a
# status code answers like an HTTP server (curl exit 0, that code on stdout).
REAL_CURL="$(command -v curl)"
mkdir -p "$TMP/shim"
cat >"$TMP/shim/curl" <<SHIM
#!/usr/bin/env bash
script="$TMP/curl-script"
step="\$(head -n 1 "\$script")"
if [[ -z "\$step" ]]; then exec "$REAL_CURL" "\$@"; fi
tail -n +2 "\$script" >"\$script.next"
mv "\$script.next" "\$script"
if [[ "\$step" == dns ]]; then
  echo "curl: (6) Could not resolve host: files.cmux.com" >&2
  exit 6
fi
printf '%s' "\$step"
SHIM
chmod +x "$TMP/shim/curl"
printf '{"commit":"%s"}\n' "$C3" >"$STORE/$C3/manifest.json"
resolve_with_curl_script() {
  printf '%s\n' "$@" >"$TMP/curl-script"
  (cd "$TMP/full" && PATH="$TMP/shim:$PATH" CMUX_TUI_CLIENT_PROBE_RETRY_SECONDS=0 "$RESOLVER" --max-fallback 3 2>/dev/null)
}
expect_curl_script_drained() {
  if [[ -s "$TMP/curl-script" ]]; then
    echo "FAIL: the curl shim did not consume its script (test setup): $(tr '\n' ' ' <"$TMP/curl-script")"
    exit 1
  fi
}

# Transient failures (DNS, 5xx, 429) are retried, so they do not read as a missing
# manifest: C3 is published and must still win.
got="$(resolve_with_curl_script dns 503 429 || true)"
expect_curl_script_drained
if [[ "$got" != "$C3" ]]; then
  echo "FAIL: transient probe failures must be retried and resolve $C3, got '$got'"
  exit 1
fi

# HTTP 404 and 410 are definitive: the resolver moves past C3 at once, although a
# retry would have found it, and falls back to C1.
for missing in 404 410; do
  got="$(resolve_with_curl_script "$missing" || true)"
  expect_curl_script_drained
  if [[ "$got" != "$C1" ]]; then
    echo "FAIL: HTTP $missing must skip $C3 without a retry and fall back to $C1, got '$got'"
    exit 1
  fi
done

for bad in x -1; do
  rc=0
  (cd "$TMP/full" && CMUX_TUI_CLIENT_PROBE_RETRY_SECONDS="$bad" "$RESOLVER" >/dev/null 2>&1) || rc=$?
  if [[ $rc != 64 ]]; then
    echo "FAIL: CMUX_TUI_CLIENT_PROBE_RETRY_SECONDS='$bad' must exit 64 (usage error), got $rc"
    exit 1
  fi
done

# Regression (#14090): a PR branch touches cmux-tui, merges main into itself after main
# also touched cmux-tui, and lands through a merge-commit PR. The artifacts workflow
# publishes main's merge (M), never the branch-side merge (B). Plain history
# simplification follows the branch side, so B looked like the newest candidate and
# exact mode failed every reload build (run 36117899936, 52020d35 vs f4b331d15).
git init -q "$TMP/merge"
git -C "$TMP/merge" checkout -q -b main
mcommit() {
  mkdir -p "$(dirname "$TMP/merge/$2")"
  echo "$1" >"$TMP/merge/$2"
  git -C "$TMP/merge" add -A
  GIT_COMMITTER_DATE="$3" GIT_AUTHOR_DATE="$3" git -C "$TMP/merge" commit -q -m "$1"
  git -C "$TMP/merge" rev-parse HEAD
}
mcommit "base" cmux-tui/a.rs "2026-09-20T00:00:00" >/dev/null
git -C "$TMP/merge" checkout -q -b feature
mcommit "feature tui" cmux-tui/b.rs "2026-09-21T00:00:00" >/dev/null
git -C "$TMP/merge" checkout -q main
mcommit "main tui" cmux-tui/c.rs "2026-09-22T00:00:00" >/dev/null
git -C "$TMP/merge" checkout -q feature
GIT_COMMITTER_DATE="2026-09-23T00:00:00" git -C "$TMP/merge" merge -q --no-edit main
B="$(git -C "$TMP/merge" rev-parse HEAD)"
git -C "$TMP/merge" checkout -q main
GIT_COMMITTER_DATE="2026-09-24T00:00:00" git -C "$TMP/merge" merge -q --no-ff --no-edit feature
M="$(git -C "$TMP/merge" rev-parse HEAD)"
mcommit "app after" Sources/App.swift "2026-09-25T00:00:00" >/dev/null
MSTORE="$TMP/mstore"
mkdir -p "$MSTORE/$M"
printf '{"commit":"%s"}\n' "$M" >"$MSTORE/$M/manifest.json"
got="$(cd "$TMP/merge" && CMUX_TUI_CLIENT_MANIFEST_BASE="file://$MSTORE" "$RESOLVER" 2>"$TMP/merge.err")" || {
  echo "FAIL: exact mode must accept main's published merge $M for the branch-side merge $B"
  cat "$TMP/merge.err"
  exit 1
}
if [[ "$got" != "$M" ]]; then
  echo "FAIL: expected main's published merge $M, got '$got'"
  exit 1
fi
if grep -q '^::warning' "$TMP/merge.err"; then
  echo "FAIL: a commit with identical client inputs is not a fallback and must not warn"
  exit 1
fi
# A branch that merged main after the fact (like a PR branch) resolves the same way:
# its own merge commit shares main's inputs, so main's published merge stands in.
git -C "$TMP/merge" checkout -q -b later "$M"
mcommit "later app" Sources/Other.swift "2026-09-26T00:00:00" >/dev/null
got="$(cd "$TMP/merge" && CMUX_TUI_CLIENT_MANIFEST_BASE="file://$MSTORE" "$RESOLVER" 2>/dev/null)"
if [[ "$got" != "$M" ]]; then
  echo "FAIL: a branch off main must resolve main's published merge $M, got '$got'"
  exit 1
fi
# Different inputs still count as a fallback: dropping M's manifest leaves nothing with
# HEAD's content, so exact mode fails.
rm "$MSTORE/$M/manifest.json"
if (cd "$TMP/merge" && CMUX_TUI_CLIENT_MANIFEST_BASE="file://$MSTORE" "$RESOLVER" >/dev/null 2>&1); then
  echo "FAIL: exact mode must fail when no commit with HEAD's client inputs is published"
  exit 1
fi

echo "PASS: resolve-cmux-tui-client-commit picks the newest published cmux-tui commit, shallow or not"
