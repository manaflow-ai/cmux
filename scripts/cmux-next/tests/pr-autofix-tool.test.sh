#!/usr/bin/env bash
# scripts/cmux-next/pr-autofix apply N: takes the pr-autofix-patch artifact of the
# newest finished PR autofix run of the pull request's head, applies it only to
# a clean checkout of that head and only when it applies cleanly, and commits
# and pushes it to the pull request's branch. A fake gh answers the GitHub reads;
# the push goes to a local bare remote. No network.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TOOL="$ROOT_DIR/scripts/cmux-next/pr-autofix"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pr-autofix-tool.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2 2>/dev/null || true; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# The base branch carries the real apply script and its tables. A pull request on lane/x
# changes an unformatted webviews file and replaces the apply script with one that would
# run its own code and apply anything: the tool must run the base's copy.
git init -q --bare "$tmp/acme/widgets.git"
git init -q -b feat-cmux-next "$tmp/work"
cd "$tmp/work"
mkdir -p webviews/src .github/workflows scripts/cmux-next
printf 'export const a = 1;\n' > webviews/src/a.ts
printf 'on: push\n' > .github/workflows/x.yml
for name in pr-autofix pr-autofix-apply.sh settings-exports.txt generated_outputs.py; do
  cp "$ROOT_DIR/scripts/cmux-next/$name" scripts/cmux-next/
done
git add -A && git commit -q -m base
git remote add origin "$tmp/acme/widgets.git"
git push -q origin feat-cmux-next
git checkout -q -b lane/x
printf 'export const   a = 2;\n' > webviews/src/a.ts
printf '#!/usr/bin/env bash\ntouch "%s/pwned"\ngit -C "$2" apply "$1"\n' "$tmp" > scripts/cmux-next/pr-autofix-apply.sh
git commit -q -am change
git push -q origin lane/x
# Run as a lane does, from the pull request's checkout, beside its replaced apply script.
TOOL="$tmp/work/scripts/cmux-next/pr-autofix"
head_sha="$(git rev-parse HEAD)"

make_artifact() { # NAME FILE CONTENT -> $tmp/NAME.zip holding pr-autofix.patch for FILE
  printf '%s' "$3" > "$2"
  mkdir -p "$tmp/$1"
  git diff > "$tmp/$1/pr-autofix.patch"
  git checkout -q -- "$2"
  (cd "$tmp/$1" && python3 -I -m zipfile -c "$tmp/$1.zip" pr-autofix.patch)
}
make_artifact fmt webviews/src/a.ts $'export const a = 2;\n'
make_artifact workflow .github/workflows/x.yml $'on: pull_request\n'

cat > "$tmp/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"--jq .headRefOid"*) echo "\${FAKE_HEAD:-$head_sha}" ;;
  *"--jq .headRefName"*) echo lane/x ;;
  *"--jq .isCrossRepository"*) echo "\${FAKE_CROSS:-false}" ;;
  *"--jq .baseRefName"*) echo feat-cmux-next ;;
  *"/runs?head_sha="*) echo "\${FAKE_RUN-42}" ;;
  *"/runs/42/artifacts"*) echo "\${FAKE_ARTIFACT-7}" ;;
  *"/artifacts/7/zip"*) cat "$tmp/\${FAKE_ZIP:-fmt}.zip" ;;
  *--paginate*) echo "fake gh: --paginate is refused by the gh quota" >&2; exit 3 ;;
  *"/pulls/5/files?per_page=100&page=1"*) printf '%s\n' webviews/src/a.ts --file-- .github/workflows/x.yml --file-- ;;
  *"/pulls/5/files?"*) ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/gh"
export CMUX_PR_AUTOFIX_GH="$tmp/gh"
TOOL_ARGS=(--repo acme/widgets)
pr_autofix() { "$TOOL" apply 5 "${TOOL_ARGS[@]}" "$@"; }

# origin pushes somewhere else (a fork): refused before anything is applied.
if pr_autofix --repo other/widgets >"$tmp/out" 2>&1; then fail "an origin that is not the PR's repo must be refused"; fi
grep -q "not other/widgets" "$tmp/out" || fail "the refusal must name the repository"

# An expired artifact is not "no repairs".
if FAKE_ARTIFACT=expired pr_autofix >"$tmp/out" 2>&1; then fail "an expired artifact must fail"; fi
grep -q "expired" "$tmp/out" || fail "must say the artifact expired"

# Not the pull request's head: refused, nothing committed.
git checkout -q HEAD^
if pr_autofix >"$tmp/out" 2>&1; then fail "a checkout off the PR head must be refused"; fi
grep -q "not #5's head" "$tmp/out" || fail "the refusal must name the PR head"
git checkout -q lane/x

# A fork's pull request: its author applies the artifact.
if FAKE_CROSS=true pr_autofix >"$tmp/out" 2>&1; then fail "a fork's pull request must be refused"; fi

# No finished run yet, and a run that made no repairs.
if FAKE_RUN= pr_autofix >"$tmp/out" 2>&1; then fail "no finished run must fail"; fi
grep -q "no finished PR autofix run" "$tmp/out" || fail "must say no run finished"
FAKE_ARTIFACT= pr_autofix >"$tmp/out" 2>&1 || fail "a run without repairs is not an error"
grep -q "made no repairs" "$tmp/out" || fail "must say the run made no repairs"

# A patch to a workflow file is not an autofix output: refused, nothing committed.
if FAKE_ZIP=workflow pr_autofix >"$tmp/out" 2>&1; then fail "a workflow patch must be refused"; fi
grep -q "refused: .github/workflows/x.yml" "$tmp/out" || fail "the refusal must name the workflow"
[[ "$(git rev-parse HEAD)" == "$head_sha" && -z "$(git status --porcelain)" ]] || fail "a refused patch must change nothing"

# Uncommitted changes: refused.
printf 'x\n' >> webviews/src/a.ts
if pr_autofix >"$tmp/out" 2>&1; then fail "a dirty checkout must be refused"; fi
git checkout -q -- webviews/src/a.ts

# The repair: applied, committed on the head and pushed to the branch.
pr_autofix >"$tmp/out" 2>&1 || fail "the repair must apply"
grep -q "applied: webviews/src/a.ts" "$tmp/out" || fail "must name the applied file"
[[ "$(cat webviews/src/a.ts)" == "export const a = 2;" ]] || fail "the file must be formatted"
[[ "$(git rev-parse HEAD^)" == "$head_sha" ]] || fail "the repair must be one commit on the head"
git log -1 --format=%B | grep -q "actions/runs/42" || fail "the commit must name its run"
if git log -1 --format=%B | grep -q '^Autofix-Run: '; then fail "no Autofix-Run trailer (it skips later exports)"; fi
[[ "$(git --git-dir="$tmp/acme/widgets.git" rev-parse lane/x)" == "$(git rev-parse HEAD)" ]] || fail "the commit must be pushed"

# The repaired head's patch from the old run no longer applies: refused as stale.
if FAKE_HEAD="$(git rev-parse HEAD)" pr_autofix --no-push >"$tmp/out" 2>&1; then fail "a stale patch must be refused"; fi
grep -q "does not apply cleanly" "$tmp/out" || fail "must say the patch does not apply"

[[ ! -e "$tmp/pwned" ]] || fail "the pull request's own apply script ran; only the base's copy may"

echo "PASS: pr-autofix apply"
