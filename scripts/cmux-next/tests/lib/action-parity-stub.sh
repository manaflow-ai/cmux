# The push tests exercise git publication with cargo replaced at its process boundary.
# A failure still leaves the remote untouched; no production switch can skip parity.
mkdir -p "$tmp/parity-bin"
cat > "$tmp/parity-bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${TOKEN:-}${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] || { echo 'cargo received a publication token' >&2; exit 91; }
for variable in "${!GIT_CONFIG_VALUE_@}"; do
  [[ -z "$variable" || "${!variable}" != *AUTHORIZATION* ]] || { echo 'cargo received Git publication credentials' >&2; exit 92; }
done
[[ " $* " == *" test "* && " $* " == *" --locked "* && " $* " == *" -p cmux-action-catalog "* && " $* " == *" --test swift_parity "* ]] || exit 90
if [[ -n "${STUB_ACTION_PARITY_LOG:-}" ]]; then git rev-parse HEAD >> "$STUB_ACTION_PARITY_LOG"; fi
# STUB_ACTION_PARITY_FAILS names a file of "SHA TEST" lines: at HEAD SHA (* for any head, !SHA for
# any other head) the stub reports TEST as FAILED, as cargo's test harness prints it, and exits 101.
if [[ -n "${STUB_ACTION_PARITY_FAILS:-}" ]]; then
  head="$(git rev-parse HEAD)" failed=0
  while read -r sha name; do
    [[ "$sha" == "$head" || "$sha" == '*' || ( "$sha" == '!'* && "$sha" != "!$head" ) ]] || continue
    echo "test $name ... FAILED"
    failed=1
  done < "$STUB_ACTION_PARITY_FAILS"
  ((failed == 0)) || exit 101
fi
# The push script checks the base tip in a linked worktree: that verdict is STUB_ACTION_PARITY_TIP_STATUS (green by default).
if [[ "$(git rev-parse --absolute-git-dir)" != "$(cd "$(git rev-parse --git-common-dir)" && pwd)" ]]; then
  exit "${STUB_ACTION_PARITY_TIP_STATUS:-0}"
fi
exit "${STUB_ACTION_PARITY_STATUS:-0}"
CARGO
chmod +x "$tmp/parity-bin/cargo"
export PATH="$tmp/parity-bin:$PATH"
