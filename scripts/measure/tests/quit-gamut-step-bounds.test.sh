#!/usr/bin/env bash
# Exercise the actual A/B entry point without a Mac, network, or app build.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"
measure="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf -- "$tmp"'
mkdir -p "$tmp/repo/scripts/measure" "$tmp/repo/scripts/ci" "$tmp/repo/scripts/cmux-next" "$tmp/bin"
cp "$measure/quit-gamut.sh" "$tmp/repo/scripts/measure/"
cp "$measure/../ci/timeout.sh" "$tmp/repo/scripts/ci/"
touch "$tmp/repo/scripts/cmux-next/resolve-acpmux.sh" "$tmp/repo/scripts/cmux-next/bundle-screen-sharing-helper.sh"
cat > "$tmp/repo/scripts/measure/nightly-fresh-launch.sh" <<'LIB'
build_dmg() {
  echo "build detail $2" >> "$1/build-$2.log"
  if [[ "$CASE" == build_timeout ]]; then sleep 30; fi
  [[ "$CASE" == second_side && "$2" == base ]] && return 0
  return 7
}
main "$@"; exit $?
LIB
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TRACE"
case "$*" in
  'rev-parse HEAD') echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  'rev-parse --is-shallow-repository') echo "$SHALLOW" ;;
  'cat-file '*) exit 1 ;;
  *' fetch '*)
    echo 'fetch progress'
    [[ "$CASE" == fetch_timeout ]] && sleep 30
    [[ "$CASE" == fetch_failure ]] && exit 9
    exit 0 ;;
  *' checkout '*)
    # Historical commits need not contain the carrier's timeout helper.
    : > scripts/ci/timeout.sh
    exit 0 ;;
  *) exit 88 ;;
esac
GIT
printf '#!/usr/bin/env bash\necho fixture\n' > "$tmp/bin/sysctl"
cp "$tmp/bin/sysctl" "$tmp/bin/sw_vers"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" TRACE="$tmp/trace"
fail() { echo "FAIL quit-gamut-step-bounds: $*" >&2; exit 1; }
run_case() {
  export CASE="$1" SHALLOW="$2" CI_TIMEOUT_IMPL="$3"
  local expected="$4" rc started=$SECONDS
  : > "$TRACE"
  cp "$measure/../ci/timeout.sh" "$tmp/repo/scripts/ci/timeout.sh"
  set +e
  # An outer bound also detects leaked children that keep tee/command-substitution pipes open.
  output="$(cd "$tmp/repo" && GAMUT_FETCH_TIMEOUT_S=1 GAMUT_BUILD_TIMEOUT_S=1 \
    "$measure/../ci/timeout.sh" --kill-after=1 10 bash scripts/measure/quit-gamut.sh \
    base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    head=cccccccccccccccccccccccccccccccccccccccc 2>&1)"
  rc=$?
  set -e
  [[ "$rc" == "$expected" ]] || fail "$CASE/$CI_TIMEOUT_IMPL status $rc, want $expected: $output"
  (( SECONDS - started < 8 )) || fail "$CASE left a pipe/child open: $output"
  grep -q 'fetch progress' <<< "$output" || fail 'fetch progress missing'
  grep -q 'fetch progress' "$tmp/repo/.build/quit-gamut/fetch-bbbbbbbbbbbb.log" || fail 'fetch log missing'
  if [[ "$SHALLOW" == true ]]; then
    grep -q -- '--depth=1' "$TRACE" || fail 'shallow fetch lost depth'
  else
    if grep -q -- '--depth=1' "$TRACE"; then fail 'full fetch became shallow'; fi
  fi
  case "$CASE" in
    fetch_*)
      local fetch_rc=9
      [[ "$CASE" == fetch_timeout ]] && fetch_rc=124
      grep -q "finished rc=$fetch_rc" <<< "$output" || fail 'fetch status missing'
      if grep -q ' checkout ' "$TRACE"; then fail 'checkout after failed fetch'; fi ;;
    *)
      grep -q 'checkout --quiet --detach aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$TRACE" || fail 'carrier checkout not restored'
      grep -q 'build detail base' <<< "$output" || fail 'build tail missing'
      grep -q "finished rc=$expected" <<< "$output" || fail 'build status missing'
      if [[ "$CASE" == second_side ]]; then
        grep -q 'build detail head' <<< "$output" || fail 'head build did not run'
      fi ;;
  esac
  echo "ok $CASE shallow=$SHALLOW timeout=$CI_TIMEOUT_IMPL"
}
run_case build_failure false auto 7
run_case second_side true auto 7
run_case fetch_failure false auto 3
for implementation in auto perl; do
  run_case fetch_timeout true "$implementation" 3
  run_case build_timeout false "$implementation" 124
done
echo 'quit-gamut-step-bounds: ok'
