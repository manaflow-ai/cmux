#!/usr/bin/env bash
# launch-premain.sh's dmg=sha256:HEX: store_fetch takes the object through the controller's signed URL, else its own
# GET, and refuses bytes that are not HEX; gate prints one LP-GATE row per check, with an open assessment's context.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launch-premain.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
printf 'dmg bytes' >"$root/object"
hex="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$root/object")"

# Stand-ins: the controller answers /url with a signed URL (or nothing, with LP_NO_URL), and every download is
# $root/object (or other bytes, with LP_BAD).
curl() {
  local out="" url="" a
  while (($#)); do a="$1"; shift; case "$a" in -o) out="$1"; shift ;; -A|--connect-timeout|--max-time|--retry|--retry-delay) shift ;; -*) ;; *) url="$a" ;; esac; done
  echo "$url" >>"$root/urls"
  case "$url" in
    */url) [[ -n "${LP_NO_URL:-}" ]] && return 22; echo '{"url": "https://store.example/signed?x=1"}' ;;
    *) if [[ -n "${LP_BAD:-}" ]]; then printf 'other' >"$out"; else cp "$root/object" "$out"; fi ;;
  esac
}
shasum_out() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), sys.argv[1])' "$1"; }
spctl() { echo "spctl $*" >>"$root/calls"; echo "${@: -1}: accepted"; echo "source=Notarized Developer ID"; }
xcrun() { echo "xcrun $*" >>"$root/calls"; echo "The validate action worked!"; }

# shellcheck source=../launch-premain.sh
source "$script"
# The script calls /usr/bin/shasum by path; a Linux runner has none, so the stand-in replaces store_fetch's check line.
eval "$(declare -f store_fetch | sed 's#/usr/bin/shasum -a 256 "$file"#shasum_out "$file"#')"

store_fetch "$hex" "$root/a.dmg" || { echo "launch-premain store: the signed URL fetch failed" >&2; exit 1; }
cmp -s "$root/object" "$root/a.dmg" || { echo "launch-premain store: wrong bytes" >&2; exit 1; }
grep -q '^https://store.example/signed' "$root/urls" || { echo "launch-premain store: the signed URL was not used" >&2; exit 1; }

: >"$root/urls"
LP_NO_URL=1 store_fetch "$hex" "$root/b.dmg" || { echo "launch-premain store: the controller GET fallback failed" >&2; exit 1; }
grep -q "/v1/artifacts/sha256:$hex\$" "$root/urls" || { echo "launch-premain store: no controller GET" >&2; exit 1; }

if LP_BAD=1 store_fetch "$hex" "$root/c.dmg" >/dev/null; then echo "launch-premain store: took bytes not matching HEX" >&2; exit 1; fi

rows="$(gate dmg open "$root/a.dmg"; gate app exec "$root/x.app")"
[[ "$(grep -c '^LP-GATE ' <<<"$rows")" == 4 ]] || { echo "launch-premain gate: want 4 LP-GATE rows, got: $rows" >&2; exit 1; }
grep -q '^LP-GATE dmg spctl rc=0 PATH: accepted source=Notarized Developer ID' <<<"$rows" || { echo "launch-premain gate: dmg row: $rows" >&2; exit 1; }
grep -q -- '--type open --context context:primary-signature' "$root/calls" || { echo "launch-premain gate: open without its context" >&2; exit 1; }
grep -q -- '--type exec -vv' "$root/calls" || { echo "launch-premain gate: exec assessed with a context (or not at all)" >&2; exit 1; }

# fresh_keychain: a login keychain in the probe's home (launch-premain.swift's HOME_ROOT/h), each `security` step run
# as the console user with that home as HOME and CFFIXED_USER_HOME; main makes it before any launch (Keychain Not Found
# panels from arms h,a,d on cmux-austin-mini-1, 2026-11-18). launch-fresh-install.sh sources the same one.
console() { printf '%s\n' "$*" >>"$root/console"; }
OUT="$root" fresh_keychain "$root/h" || { echo "launch-premain keychain: fresh_keychain failed" >&2; exit 1; }
kc="$root/h/Library/Keychains/login.keychain-db"
grep -qxF "/bin/mkdir -p $root/h/Library/Keychains" "$root/console" || { echo "launch-premain keychain: no Keychains folder: $(cat "$root/console")" >&2; exit 1; }
for want in "create-keychain -p ''" "list-keychains -d user -s" "default-keychain -d user -s" "set-keychain-settings"; do
  grep -qF "/usr/bin/env HOME=$root/h CFFIXED_USER_HOME=$root/h /bin/sh -c exec /usr/bin/security $want \"\$0\" $kc" "$root/console" \
    || { echo "launch-premain keychain: missing '$want' scoped to the home: $(cat "$root/console")" >&2; exit 1; }
done
declare -f main | awk '/fresh_keychain "\$out\/home\/h"/ { k = NR } /launch open prime/ && !p { p = NR } END { exit !(k && p && k < p) }' \
  || { echo "launch-premain keychain: main does not make the probe home's keychain before its first launch" >&2; exit 1; }
echo "launch-premain store: ok"
