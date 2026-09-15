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

echo "PASS: resolve-cmux-tui-client-commit picks the newest published cmux-tui commit, shallow or not"
