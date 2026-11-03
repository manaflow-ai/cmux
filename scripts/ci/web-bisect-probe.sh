#!/usr/bin/env bash
# One probe of a coalesced web run's bisect (scripts/ci/web_coalesce.py bisect): check out COMMIT, build what the
# webview tests read there, and run only the files in FILES, writing their {name: passed} map to OUT.
#
#   web-bisect-probe.sh COMMIT FILES OUT
#
# Run from the repository root of a full-history checkout. The bisect job copies this script and the head's test
# runner (run-webviews-tests.sh and its helpers) to WEB_BISECT_RUNNER first, so every probe runs the same runner
# whatever commit is checked out, as react-apps-base-check does. A failed install or build leaves OUT unwritten:
# no verdict for that commit, never a red.
set -uo pipefail

commit="$1" files="$2" out="$3"
runner="${WEB_BISECT_RUNNER:?WEB_BISECT_RUNNER is required}"
rm -f "$out"
git checkout -q --force --detach "$commit" || exit 0
present="$out.files"
while IFS= read -r file; do
  if [ -n "$file" ] && git cat-file -e "HEAD:webviews/$file" 2>/dev/null; then
    printf '%s\n' "$file"
  fi
done < "$files" > "$present"
if [ ! -s "$present" ]; then
  printf '{}\n' > "$out"
  exit 0
fi
(cd webviews && bun install --frozen-lockfile) || exit 0
./scripts/cmux-next/build-web-bundles.sh --force || exit 0
(cd webviews && ./node_modules/.bin/playwright install --with-deps webkit) || exit 0
scripts/ci/ensure-system-chrome.sh || exit 0
cd webviews || exit 0
# The head shards' retry rule: a file counts red only when it also fails once more, alone.
CMUX_NEXT_STYLE_GUARDS=warn \
  CMUX_WEB_TEST_JOBS="${WEB_BISECT_JOBS:-4}" \
  CMUX_WEB_TEST_FILES="$(cat "$present")" \
  CMUX_WEB_TEST_RESULTS="$out" \
  env -u CMUX_WEB_TEST_SHARD -u CMUX_WEB_TEST_SHARD_COUNT -u CMUX_PR_CHANGED_FILES \
  bash "$runner/run-webviews-tests.sh" || true
