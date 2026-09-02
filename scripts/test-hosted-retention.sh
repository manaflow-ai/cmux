#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/lib/hosted-retention-plan.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  if "$@" >"$tmp/unexpected-stdout" 2>"$tmp/expected-error"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

commit_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
commit_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
commit_c=cccccccccccccccccccccccccccccccccccccccc
commit_d=dddddddddddddddddddddddddddddddddddddddd
hosted="$tmp/hosted"
mkdir -p "$hosted/$commit_a" "$hosted/$commit_b" "$hosted/$commit_c" "$hosted/$commit_d"
touch -t 202401010101 "$hosted/$commit_a"
touch -t 202402020202 "$hosted/$commit_b"
touch -t 202403030303 "$hosted/$commit_c"
touch -t 202312120000 "$hosted/$commit_d"

plan="$tmp/plan"
"$helper" plan "$hosted" 1 "$commit_c" >"$plan"
grep -Fqx $'schema\t1' "$plan" || fail "plan schema is absent"
grep -Fqx $'count\t1' "$plan" || fail "retention count is not bound"
grep -Fqx $'current\t'$commit_c "$plan" || fail "current commit is not bound"
grep -Fqx $'candidate\t'$commit_b "$plan" || fail "retained candidate is not bound"
grep -Fqx $'victim\t'$commit_a "$plan" || fail "first victim is not bound"
grep -Fqx $'victim\t'$commit_d "$plan" || fail "second victim is not bound"

token="$tmp/token"
"$helper" token "$plan" 1000 >"$token"
"$helper" validate "$plan" "$token" 1599 600
expect_failure "$helper" validate "$plan" "$token" 1601 600
sed 's/^count\t1$/count\t2/' "$plan" >"$tmp/mismatch-plan"
expect_failure "$helper" validate "$tmp/mismatch-plan" "$token" 1500 600
"$helper" token "$plan" 2000 >"$tmp/fresh-token"
"$helper" validate "$plan" "$tmp/fresh-token" 2000 600

real_stat="$(command -v stat)"
mkdir "$tmp/gnu-bin"
cat >"$tmp/gnu-bin/stat" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-f" ]; then exit 1; fi
if [ "\${1:-}" = "-c" ] && [ "\${2:-}" = "%Y" ]; then
  shift 2
  if "$real_stat" -c '%Y' "\$@" 2>/dev/null; then exit 0; fi
  exec "$real_stat" -f '%m' "\$@"
fi
exec "$real_stat" "\$@"
EOF
chmod +x "$tmp/gnu-bin/stat"
PATH="$tmp/gnu-bin:$PATH" "$helper" plan "$hosted" 1 "$commit_c" >"$tmp/gnu-plan"
cmp -s "$plan" "$tmp/gnu-plan" || fail "GNU stat fallback changed the canonical plan"

expect_failure "$helper" plan "$hosted" 0 "$commit_c"
expect_failure "$helper" plan "$hosted" 1001 "$commit_c"
expect_failure "$helper" plan "$hosted" 999999999999999999999999999999999 "$commit_c"

active_bin="$hosted/$commit_a/cmux-tui"
printf 'active artifact\n' >"$active_bin"
mkdir "$tmp/active-bin"
cat >"$tmp/active-bin/lsof" <<'EOF'
#!/bin/sh
printf '4242\n'
EOF
chmod +x "$tmp/active-bin/lsof"
remove_token="$tmp/remove-token"
"$helper" token "$plan" "$(date +%s)" >"$remove_token"
expect_failure env PATH="$tmp/active-bin:$PATH" "$helper" remove "$hosted" "$commit_a" "$plan" "$remove_token" "$commit_c"
PATH="$tmp/active-bin:$PATH" CMUX_TUI_HOSTED_RETENTION_CONFIRM=1 "$helper" remove \
  "$hosted" "$commit_a" "$plan" "$remove_token" "$commit_c" >"$tmp/active-remove"
grep -Fqx $'active\t'$commit_a "$tmp/active-remove" || fail "active artifact was not reported"
[[ -d "$hosted/$commit_a" ]] || fail "active artifact was removed"

other_hosted="$tmp/other-hosted"
mkdir -p "$other_hosted/$commit_a"
expect_failure env PATH="$tmp/active-bin:$PATH" CMUX_TUI_HOSTED_RETENTION_CONFIRM=1 "$helper" remove \
  "$other_hosted" "$commit_a" "$plan" "$remove_token" "$commit_c"

cat >"$tmp/active-bin/lsof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/active-bin/lsof"
PATH="$tmp/active-bin:$PATH" CMUX_TUI_HOSTED_RETENTION_CONFIRM=1 "$helper" remove \
  "$hosted" "$commit_a" "$plan" "$remove_token" "$commit_c" >"$tmp/inactive-remove"
grep -Fqx $'removed\t'$commit_a "$tmp/inactive-remove" || fail "inactive artifact was not removed"
[[ ! -e "$hosted/$commit_a" ]] || fail "inactive artifact remains"

mkdir "$tmp/no-lsof-bin"
for command_name in find id sort stat shasum awk; do
  command_path="$(command -v "$command_name")"
  ln -s "$command_path" "$tmp/no-lsof-bin/$command_name"
done
expect_failure env PATH="$tmp/no-lsof-bin" /bin/bash "$helper" plan "$hosted" 1 "$commit_c"

echo 'hosted retention plan tests passed'
