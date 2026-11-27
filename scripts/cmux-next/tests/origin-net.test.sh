#!/usr/bin/env bash
# A remote that does not answer is retried, then named as the network; it is never read as a ref
# the remote lacks (run 43113697713: a 20 s github.com outage on a nightly input runner read as a
# missing remote browser host source tag). And no script reads a remote in a way that swallows
# that failure: `git ls-remote ... || true` and `git ls-remote ... 2>/dev/null | ...` turn "no
# answer" into "no ref" (scripts/cmux-next/lib/origin-net.sh has the helpers that tell them apart).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }
# shellcheck source=scripts/cmux-next/lib/origin-net.sh
source "$ROOT/scripts/cmux-next/lib/origin-net.sh"
export ORIGIN_NET_SLEEP_S=0

# A stand-in git: ls-remote fails (exit 128, as an unreachable host does) until $TMP/answer-after
# calls, then prints the refs in $TMP/refs (none: an empty answer, exit 0).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$TMP/calls" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$TMP/calls"
if (( n <= \$(cat "$TMP/answer-after") )); then
  echo "fatal: unable to access 'https://github.com/manaflow-ai/cmux/': Failed to connect to github.com port 443" >&2
  exit 128
fi
cat "$TMP/refs" 2>/dev/null || true
EOF
chmod +x "$TMP/bin/git"
run() { # <failures before an answer> <refs or ""> -> sets out, err, status, calls
  rm -f "$TMP/calls"; echo "$1" > "$TMP/answer-after"; printf '%s' "$2" > "$TMP/refs"
  status=0
  out="$(PATH="$TMP/bin:$PATH" remote_refs "$TMP" origin refs/tags/x 2> "$TMP/err")" || status=$?
  err="$(cat "$TMP/err")"; calls="$(cat "$TMP/calls")"
}
tag="044877560be6ead1d76a464add312bef886d2024	refs/tags/cmux-rbh-src-044877560be"

# The tag is there and the remote answers at once.
run 0 "$tag"
[[ $status == 0 && $out == "$tag" && $calls == 1 ]] || fail "answered at once: status=$status calls=$calls out=$out"

# The remote does not answer twice, then does: the tag is found, nothing is missing.
run 2 "$tag"
[[ $status == 0 && $out == "$tag" && $calls == 3 ]] || fail "answered on try 3: status=$status calls=$calls out=$out"
grep -q "try 1 of 4" <<<"$err" || fail "a retry names its try: $err"

# The remote answers that it has no such tag: success with no lines (the caller says it is missing).
run 0 ""
[[ $status == 0 && -z $out && $calls == 1 ]] || fail "an empty answer is an answer: status=$status calls=$calls out=$out"

# The remote never answers: a failure that names the network, never an empty answer.
run 9 "$tag"
[[ $status == 128 && -z $out && $calls == 4 ]] || fail "never answered: status=$status calls=$calls out=$out"
grep -q "the remote did not answer" <<<"$err" || fail "names the network: $err"

# The notices script reads origin only through these helpers.
notices="$ROOT/scripts/cmux-next/generate-third-party-notices.sh"
# shellcheck disable=SC2016 # the literal text of the script's lines, not this shell's variables
grep -qF 'source "$ROOT/scripts/cmux-next/lib/origin-net.sh"' "$notices" || fail "notices sources origin-net.sh"
# shellcheck disable=SC2016
if grep -nF 'git -C "$ROOT" ls-remote' "$notices"; then fail "notices reads origin without remote_refs"; fi

# The remote browser host source (lib/rbh-source.sh): a full checkout lends its objects, so the
# remote sends only what the commit adds (nightly run 45796327994 lost 48 min to a lone depth-1
# fetch of the whole tree); a shallow checkout takes the lone fetch.
# shellcheck source=scripts/cmux-next/lib/rbh-source.sh
source "$ROOT/scripts/cmux-next/lib/rbh-source.sh"
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
r="$TMP/rbh"; mkdir -p "$r"
g init -q "$r/remote" && g -C "$r/remote" config uploadpack.allowAnySHA1InWant true
mkdir -p "$r/remote/cmux-tui/crates/host"
head -c 200000 /dev/urandom > "$r/remote/big.bin"
echo '[workspace]' > "$r/remote/cmux-tui/Cargo.toml"; echo 'one' > "$r/remote/cmux-tui/crates/host/lib.rs"
g -C "$r/remote" add -A && g -C "$r/remote" commit -qm one
old=$(g -C "$r/remote" rev-parse HEAD); big=$(g -C "$r/remote" rev-parse HEAD:big.bin)
g clone -q "file://$r/remote" "$r/full"
echo 'two' > "$r/remote/cmux-tui/crates/host/lib.rs" && g -C "$r/remote" commit -qam two
new=$(g -C "$r/remote" rev-parse HEAD)
# Already in the checkout: no fetch at all.
out=$(rbh_fetch_source "$r/full" "$r/a.git" "$old" "file://$r/gone" 2>&1) || fail "in checkout: $out"
[[ $(git -C "$r/a.git" rev-parse FETCH_HEAD) == "$old" && $(git -C "$r/a.git" rev-parse FETCH_HEAD:cmux-tui/crates/host/lib.rs) ]] || fail "in checkout: FETCH_HEAD"
# Newer than the checkout: fetched beside it; the big unchanged file stays lent, not sent.
out=$(rbh_fetch_source "$r/full" "$r/b.git" "$new" "file://$r/remote" 2>&1) || fail "beside: $out"
grep -q "beside this checkout's objects" <<<"$out" || fail "beside: $out"
[[ $(git -C "$r/b.git" rev-parse FETCH_HEAD) == "$new" ]] || fail "beside: FETCH_HEAD"
git -C "$r/b.git" archive FETCH_HEAD cmux-tui/Cargo.toml cmux-tui/crates | tar -t | grep -q crates/host/lib.rs || fail "beside: archive"
mv "$(git -C "$r/b.git" rev-parse --path-format=absolute --git-path objects/info/alternates)" "$r/alternates.off"
if git -C "$r/b.git" cat-file -e "$big" 2>/dev/null; then fail "beside: the remote sent a file the checkout had"; fi
# A shallow checkout lends nothing: the lone depth-1 fetch.
g clone -q --depth 1 "file://$r/remote" "$r/shallow"
echo 'three' > "$r/remote/cmux-tui/crates/host/lib.rs" && g -C "$r/remote" commit -qam three
third=$(g -C "$r/remote" rev-parse HEAD)
out=$(rbh_fetch_source "$r/shallow" "$r/c.git" "$third" "file://$r/remote" 2>&1) || fail "shallow: $out"
[[ ! -s "$(git -C "$r/c.git" rev-parse --path-format=absolute --git-path objects/info/alternates)" && $(git -C "$r/c.git" rev-parse FETCH_HEAD) == "$third" ]] || fail "shallow: lone fetch"
# A failed lent fetch falls back to the lone fetch (here it fails too, and says so).
out=$(ORIGIN_NET_TRIES=1 rbh_fetch_source "$r/full" "$r/d.git" "$third" "file://$r/gone" 2>&1) && fail "gone remote succeeded"
grep -q "fetching it alone" <<<"$out" || fail "fallback: $out"

# No script reads a remote and swallows its failure (code, not a comment that names the pattern).
swallowed="$(git -C "$ROOT" ls-files -z -- '*.sh' | (cd "$ROOT" && xargs -0 grep -nE '^[^#]*ls-remote[^#]*(\|\| *true|2> */dev/null *\|)') || true)"
[[ -z "$swallowed" ]] || fail "these read a remote and swallow its failure (use remote_refs from scripts/cmux-next/lib/origin-net.sh):" "$swallowed"
echo "origin-net: ok"
