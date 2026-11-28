#!/usr/bin/env bash
# scripts/ci/tests/run-webviews-tests-deadline.test.sh: react-apps-base-early runs files red on the base, and the slow
# ones fail at their 450-900 s limits one at a time; 41 of 73 runs (11-21 09:30-16:50Z) hit the job limit still
# testing and left no verdict. With CMUX_WEB_TEST_STOP_AT, run-webviews-tests.sh starts no file past it, stops a
# running file at it, and leaves both out of the results (NOT RUN, and the run fails), keeping every finished verdict.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
git_fixture_trap_exit 'rm -rf "$WORK"'
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# a-fast passes at once, b-slow would run 60 s, c-later and the gallery dev-server file come after the deadline.
repo="$WORK/repo"
mkdir -p "$repo/webviews/test" "$WORK/bin"
for name in a-fast b-slow c-later; do echo "// $name" > "$repo/webviews/test/$name.test.ts"; done
printf '// gallery\nconst config = "vite.config.gallery-dev.ts";\n' > "$repo/webviews/test/d-gallery.test.ts"
git -C "$repo" init -q
git -C "$repo" add -A

cat > "$WORK/bin/bun" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  *a-fast*) echo "(pass) fast"; exit 0 ;;
  *) sleep 60; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/bun"

started=$(date +%s)
status=0
(cd "$repo/webviews" && PATH="$WORK/bin:$PATH" CMUX_WEB_TEST_JOBS=1 CMUX_WEB_TEST_RETRIES=0 \
  CMUX_WEB_TEST_RESULTS="$WORK/results.json" CMUX_WEB_TEST_STOP_AT=$((started + 4)) \
  bash "$ROOT/scripts/ci/run-webviews-tests.sh") > "$WORK/out" 2>&1 || status=$?
took=$(($(date +%s) - started))

[ "$status" -ne 0 ] || fail "a run that left files untested must not pass"
[ "$took" -lt 30 ] || fail "the run must end at its deadline (plus the 10 s kill grace), took ${took}s"
grep -q "^PASS test/a-fast.test.ts" "$WORK/out" || fail "a file finished before the deadline keeps its verdict"
grep -q "^NOT RUN test/b-slow.test.ts: stopped at CMUX_WEB_TEST_STOP_AT" "$WORK/out" || fail "the running file is stopped at the deadline"
grep -q "^NOT RUN test/c-later.test.ts: past CMUX_WEB_TEST_STOP_AT" "$WORK/out" || fail "no file starts past the deadline"
grep -q "^NOT RUN test/d-gallery.test.ts: past CMUX_WEB_TEST_STOP_AT" "$WORK/out" || fail "no dev-server file warms past the deadline"
grep -q "^TIMEOUT test/b-slow" "$WORK/out" && fail "a file the deadline stopped is not a TIMEOUT verdict"
python3 - "$WORK/results.json" <<'PY' || fail "results must hold a-fast only: $(cat "$WORK/results.json")"
import json, sys
names = json.load(open(sys.argv[1]))
files = {str(name).split(" > ", 1)[0] for name in names}
sys.exit(0 if files == {"test/a-fast.test.ts"} else 1)
PY

# A red file whose retry the deadline stops keeps its first run's FAIL and log, and the run still prints its summary:
# the retry left no log, and reading it under set -e ended the run with no failure shown (batch 46058976708 shard 3).
repo2="$WORK/repo2"
mkdir -p "$repo2/webviews/test" "$WORK/bin2"
echo "// r-red" > "$repo2/webviews/test/r-red.test.ts"
git -C "$repo2" init -q
git -C "$repo2" add -A
cat > "$WORK/bin2/bun" <<EOF
#!/usr/bin/env bash
if [ -e "$WORK/r-red-ran" ]; then sleep 60; exit 1; fi
touch "$WORK/r-red-ran"
echo "(fail) r-red names its failure"
exit 1
EOF
chmod +x "$WORK/bin2/bun"
status=0
(cd "$repo2/webviews" && PATH="$WORK/bin2:$PATH" CMUX_WEB_TEST_JOBS=1 CMUX_WEB_TEST_RETRIES=1 \
  CMUX_WEB_TEST_RESULTS="$WORK/results2.json" CMUX_WEB_TEST_STOP_AT=$(($(date +%s) + 4)) \
  bash "$ROOT/scripts/ci/run-webviews-tests.sh") > "$WORK/out2" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "a red file stays red when its retry is stopped"
grep -q "No such file" "$WORK/out2" && fail "the stopped retry's missing log must not be read"
grep -q "^### webviews tests: 1 files, 1 failed" "$WORK/out2" || fail "the run prints its summary after a stopped retry"
grep -q "r-red names its failure" "$WORK/out2" || fail "the first run's log is printed in the summary"
grep -q "^FAIL test/r-red.test.ts (limit" "$WORK/out2" || fail "the first run's FAIL is the file's verdict"
grep -q "^  NOT RUN test/r-red" "$WORK/out2" && fail "a file with a first-run verdict is not listed as not run"
[ -s "$WORK/results2.json" ] || fail "the results are written after a stopped retry"
[ "$fails" -eq 0 ] || cat "$WORK/out2" >&2

if [ "$fails" -ne 0 ]; then
  cat "$WORK/out" >&2
  exit 1
fi
echo "run-webviews-tests-deadline: ok"
