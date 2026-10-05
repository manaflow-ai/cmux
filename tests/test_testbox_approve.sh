#!/usr/bin/env bash
# scripts/blacksmith-testbox-approve.sh is RETIRED (2026-10-05): human approval
# of Testbox runs was removed on purpose and the cmux-ci App approves
# registered boxes. The helper must approve nothing, exit non-zero, and point
# to the wrapper ($HQ_TOOLS/scripts/testbox-warmup.sh), whatever it is given.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/scripts/blacksmith-testbox-approve.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"
# fake gh and blacksmith: record every call; the helper must make none.
for tool in gh blacksmith; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\n' "$tool" "$work" >"$bin/$tool"
  chmod +x "$bin/$tool"
done
fail() { echo "FAIL: $*" >&2; exit 1; }

for args in "tbx_01abc $(date +%s) comment" "tbx_01abc $(date +%s)" ""; do
  set +e
  # shellcheck disable=SC2086
  out="$(PATH="$bin:$PATH" timeout 20 "$helper" $args 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "the retired helper exited 0 for args '$args'"
  grep -q 'testbox-warmup.sh' <<<"$out" || fail "no pointer to the wrapper: $out"
  grep -q 'removed on purpose on 2026-10-05' <<<"$out" || fail "no reason given: $out"
  [[ ! -s "$work/calls" ]] || fail "the retired helper called: $(cat "$work/calls")"
done
echo "ok: the retired approve helper approves nothing and points to the wrapper"
