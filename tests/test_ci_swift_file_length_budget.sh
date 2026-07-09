#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FIXTURE="$TMP_DIR/repo"
BUDGET="$TMP_DIR/budget.tsv"

python3 - "$FIXTURE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def write_lines(path: pathlib.Path, count: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"line {index}\n" for index in range(count)), encoding="utf-8")

write_lines(root / "Sources" / "Big.swift", 5)
write_lines(root / "Sources" / "Small.swift", 4)
write_lines(root / "Sources" / "vendor" / "Ignored.swift", 100)
write_lines(root / "CLI" / "Tool.swift", 6)
write_lines(root / "Packages" / "Fixture" / "Sources" / "Fixture.swift", 7)
write_lines(root / "Packages" / "Fixture" / ".build" / "checkouts" / "Ignored.swift", 100)
PY

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 \
  --write-budget

git -C "$FIXTURE" init -q
git -C "$FIXTURE" add .
git -C "$FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm baseline
BASE_REF="$(git -C "$FIXTURE" rev-parse HEAD)"

if ! grep -Fq $'5\tSources/Big.swift' "$BUDGET"; then
  echo "expected tracked Sources file" >&2
  exit 1
fi

if ! grep -Fq $'6\tCLI/Tool.swift' "$BUDGET"; then
  echo "expected tracked CLI file" >&2
  exit 1
fi

if ! grep -Fq $'7\tPackages/Fixture/Sources/Fixture.swift' "$BUDGET"; then
  echo "expected tracked Packages file" >&2
  exit 1
fi

if grep -Fq 'Sources/Small.swift' "$BUDGET"; then
  echo "small file should not be included" >&2
  exit 1
fi

if grep -Fq 'vendor' "$BUDGET"; then
  echo "ignored source should not be included" >&2
  exit 1
fi

if grep -Fq '.build' "$BUDGET"; then
  echo "SwiftPM build output should not be included" >&2
  exit 1
fi

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5

mkdir -p "$FIXTURE/.github"
(
  cd "$TMP_DIR"
  python3 "$ROOT_DIR/scripts/swift_file_length_budget.py" \
    --repo-root "$FIXTURE" \
    --budget .github/relative-budget.tsv \
    --threshold 5 \
    --write-budget
)

if [ ! -f "$FIXTURE/.github/relative-budget.tsv" ]; then
  echo "expected relative budget path to resolve inside repo root" >&2
  exit 1
fi

if [ -f "$TMP_DIR/.github/relative-budget.tsv" ]; then
  echo "relative budget path should not resolve from current directory" >&2
  exit 1
fi

python3 - "$FIXTURE/Sources/NewLarge.swift" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("".join(f"new line {index}\n" for index in range(5)), encoding="utf-8")
PY

if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 >"$TMP_DIR/new-file.out" 2>&1; then
  echo "expected new untracked file failure" >&2
  exit 1
fi

if ! grep -Fq 'new Sources/NewLarge.swift' "$TMP_DIR/new-file.out"; then
  echo "expected new untracked file output" >&2
  cat "$TMP_DIR/new-file.out" >&2
  exit 1
fi

if ! grep -Fq 'budget=untracked threshold=5' "$TMP_DIR/new-file.out"; then
  echo "expected untracked budget output" >&2
  cat "$TMP_DIR/new-file.out" >&2
  exit 1
fi

rm "$FIXTURE/Sources/NewLarge.swift"

printf 'new growth\n' >>"$FIXTURE/Sources/Big.swift"

if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 >"$TMP_DIR/fail.out" 2>&1; then
  echo "expected file length budget failure" >&2
  exit 1
fi

if ! grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/fail.out"; then
  echo "expected budget failure output" >&2
  cat "$TMP_DIR/fail.out" >&2
  exit 1
fi

if ! grep -Fq '+1 Sources/Big.swift' "$TMP_DIR/fail.out"; then
  echo "expected file growth delta" >&2
  cat "$TMP_DIR/fail.out" >&2
  exit 1
fi

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 \
  --base-ref "$BASE_REF" \
  --incidental-growth 1 \
  --hard-cap 10 >"$TMP_DIR/incidental.out"

if ! grep -Fq 'Incidental growth allowed by PR gate' "$TMP_DIR/incidental.out"; then
  echo "expected incidental growth output" >&2
  cat "$TMP_DIR/incidental.out" >&2
  exit 1
fi

git -C "$FIXTURE" add .
git -C "$FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm 'allow incidental growth'
UNCHANGED_BASE_REF="$(git -C "$FIXTURE" rev-parse HEAD)"

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 \
  --base-ref "$UNCHANGED_BASE_REF" \
  --incidental-growth 0 \
  --hard-cap 10 >"$TMP_DIR/unchanged-over-budget.out"

if grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/unchanged-over-budget.out"; then
  echo "unchanged over-budget file should pass in base-ref mode" >&2
  cat "$TMP_DIR/unchanged-over-budget.out" >&2
  exit 1
fi

mkdir -p "$FIXTURE/.github"
printf '6\tSources/Big.swift\n6\tCLI/Tool.swift\n7\tPackages/Fixture/Sources/Fixture.swift\n' >"$FIXTURE/.github/swift-file-length-budget.tsv"
git -C "$FIXTURE" add .github/swift-file-length-budget.tsv
git -C "$FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm 'record checked-in budget'
CHECKED_IN_BUDGET_REF="$(git -C "$FIXTURE" rev-parse HEAD)"

printf '5\tSources/Big.swift\n6\tCLI/Tool.swift\n7\tPackages/Fixture/Sources/Fixture.swift\n' >"$FIXTURE/.github/swift-file-length-budget.tsv"
if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$FIXTURE/.github/swift-file-length-budget.tsv" \
  --threshold 5 \
  --base-ref "$CHECKED_IN_BUDGET_REF" \
  --incidental-growth 0 \
  --hard-cap 10 >"$TMP_DIR/lowered-budget.out" 2>&1; then
  echo "expected lowered checked-in budget to fail base-ref check" >&2
  exit 1
fi

if ! grep -Fq 'budget lowered below actual count (base budget 6)' "$TMP_DIR/lowered-budget.out"; then
  echo "expected lowered-budget reason" >&2
  cat "$TMP_DIR/lowered-budget.out" >&2
  exit 1
fi

printf 'threshold crossing\n' >>"$FIXTURE/Sources/Small.swift"
printf '6\tSources/Big.swift\n5\tSources/Small.swift\n6\tCLI/Tool.swift\n7\tPackages/Fixture/Sources/Fixture.swift\n' >"$FIXTURE/.github/swift-file-length-budget.tsv"
python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$FIXTURE/.github/swift-file-length-budget.tsv" \
  --threshold 5 \
  --base-ref "$CHECKED_IN_BUDGET_REF" \
  --incidental-growth 1 \
  --hard-cap 10 >"$TMP_DIR/threshold-crossing.out"

if grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/threshold-crossing.out"; then
  echo "budgeted threshold crossing should pass base-ref check" >&2
  cat "$TMP_DIR/threshold-crossing.out" >&2
  exit 1
fi

sed -i.bak '$d' "$FIXTURE/Sources/Small.swift"
rm "$FIXTURE/Sources/Small.swift.bak"

if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 \
  --base-ref "$BASE_REF" \
  --incidental-growth 0 >"$TMP_DIR/growth-limit.out" 2>&1; then
  echo "expected incidental growth limit failure" >&2
  exit 1
fi

if ! grep -Fq 'PR growth +1 exceeds incidental allowance 0' "$TMP_DIR/growth-limit.out"; then
  echo "expected growth-limit reason" >&2
  cat "$TMP_DIR/growth-limit.out" >&2
  exit 1
fi

if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 \
  --base-ref "$BASE_REF" \
  --incidental-growth 1 \
  --hard-cap 5 >"$TMP_DIR/hard-cap.out" 2>&1; then
  echo "expected hard-cap failure" >&2
  exit 1
fi

if ! grep -Fq 'reason=hard cap 5' "$TMP_DIR/hard-cap.out"; then
  echo "expected hard-cap reason" >&2
  cat "$TMP_DIR/hard-cap.out" >&2
  exit 1
fi

printf 'extra growth\n' >>"$FIXTURE/Sources/Big.swift"
printf '7\tSources/Big.swift\n6\tCLI/Tool.swift\n7\tPackages/Fixture/Sources/Fixture.swift\n' >"$TMP_DIR/raised-budget.tsv"

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$TMP_DIR/raised-budget.tsv" \
  --threshold 5 \
  --base-ref "$BASE_REF" \
  --incidental-growth 1 >"$TMP_DIR/raised-budget-bypass.out"

if grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/raised-budget-bypass.out"; then
  echo "raised budget should accept explicit PR growth debt" >&2
  cat "$TMP_DIR/raised-budget-bypass.out" >&2
  exit 1
fi

python3 - "$FIXTURE/Sources/NewBudgeted.swift" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("".join(f"budgeted new line {index}\n" for index in range(5)), encoding="utf-8")
PY
printf '5\tSources/NewBudgeted.swift\n7\tSources/Big.swift\n6\tCLI/Tool.swift\n7\tPackages/Fixture/Sources/Fixture.swift\n' >"$TMP_DIR/new-file-budget.tsv"

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$TMP_DIR/new-file-budget.tsv" \
  --threshold 5 \
  --base-ref "$BASE_REF" >"$TMP_DIR/new-file-budget-bypass.out"

if grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/new-file-budget-bypass.out"; then
  echo "budgeted new large file should pass base-ref check" >&2
  cat "$TMP_DIR/new-file-budget-bypass.out" >&2
  exit 1
fi

rm "$FIXTURE/Sources/NewBudgeted.swift"
sed -i.bak '$d' "$FIXTURE/Sources/Big.swift"
rm "$FIXTURE/Sources/Big.swift.bak"

printf 'not-a-valid-budget-line\n' >"$TMP_DIR/bad-budget.tsv"
if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$TMP_DIR/bad-budget.tsv" \
  --threshold 5 >"$TMP_DIR/bad.out" 2>&1; then
  echo "expected malformed budget failure" >&2
  exit 1
fi

if ! grep -Fq 'Error reading Swift file length budget' "$TMP_DIR/bad.out"; then
  echo "expected malformed budget error output" >&2
  cat "$TMP_DIR/bad.out" >&2
  exit 1
fi

if grep -Fq 'Traceback' "$TMP_DIR/bad.out"; then
  echo "malformed budget should not print a traceback" >&2
  cat "$TMP_DIR/bad.out" >&2
  exit 1
fi

printf '5\tSources/Big.swift\n6\tSources/Big.swift\n' >"$TMP_DIR/duplicate-budget.tsv"
if python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$TMP_DIR/duplicate-budget.tsv" \
  --threshold 5 >"$TMP_DIR/duplicate.out" 2>&1; then
  echo "expected duplicate budget failure" >&2
  exit 1
fi

if ! grep -Fq 'duplicate entry' "$TMP_DIR/duplicate.out"; then
  echo "expected duplicate budget error output" >&2
  cat "$TMP_DIR/duplicate.out" >&2
  exit 1
fi

if ! git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1; then
  echo "Skipping speculative merge-tree budget tests: git merge-tree --write-tree is unsupported by this git."
  exit 0
fi

RACE_FIXTURE="$TMP_DIR/race-repo"

python3 - "$RACE_FIXTURE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def write_lines(path: pathlib.Path, count: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"line {index}\n" for index in range(count)), encoding="utf-8")

write_lines(root / "Sources" / "Racy.swift", 40)
(root / ".github").mkdir(parents=True, exist_ok=True)
(root / ".github" / "test-budget.tsv").write_text("40\tSources/Racy.swift\n", encoding="utf-8")
(root / ".gitattributes").write_text("Sources/Racy.swift merge=keepFeature\n", encoding="utf-8")
(root / "README.md").write_text("base readme\n", encoding="utf-8")
PY

git -C "$RACE_FIXTURE" init -q
git -C "$RACE_FIXTURE" config merge.keepFeature.name 'keep feature side for race fixture'
git -C "$RACE_FIXTURE" config merge.keepFeature.driver 'cp %B %A'
git -C "$RACE_FIXTURE" add .
git -C "$RACE_FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm baseline
git -C "$RACE_FIXTURE" branch -M main
RACE_BASE="$(git -C "$RACE_FIXTURE" rev-parse HEAD)"

git -C "$RACE_FIXTURE" checkout -q -b feature
python3 - "$RACE_FIXTURE/Sources/Racy.swift" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    "".join(f"line {index}\n" for index in range(40))
    + "feature line 40\n"
    + "feature line 41\n",
    encoding="utf-8",
)
PY
git -C "$RACE_FIXTURE" add Sources/Racy.swift
git -C "$RACE_FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm 'grow racy file'

git -C "$RACE_FIXTURE" checkout -q main
python3 - "$RACE_FIXTURE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
(root / "Sources" / "Racy.swift").write_text(
    "".join(f"split line {index}\n" for index in range(6)),
    encoding="utf-8",
)
(root / ".github" / "test-budget.tsv").write_text("6\tSources/Racy.swift\n", encoding="utf-8")
(root / "README.md").write_text("main readme\n", encoding="utf-8")
PY
git -C "$RACE_FIXTURE" add Sources/Racy.swift .github/test-budget.tsv README.md
git -C "$RACE_FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm 'split racy file and lower budget'

git -C "$RACE_FIXTURE" checkout -q feature
RACE_MERGE_BASE="$(git -C "$RACE_FIXTURE" merge-base main feature)"
python3 scripts/swift_file_length_budget.py \
  --repo-root "$RACE_FIXTURE" \
  --budget .github/test-budget.tsv \
  --threshold 5 \
  --base-ref "$RACE_MERGE_BASE" \
  --incidental-growth 3 \
  --hard-cap 100 >"$TMP_DIR/race-old-behavior.out"

if python3 scripts/swift_file_length_budget.py \
  --repo-root "$RACE_FIXTURE" \
  --budget .github/test-budget.tsv \
  --threshold 5 \
  --base-ref "$RACE_MERGE_BASE" \
  --merge-ref main \
  --merge-head feature \
  --incidental-growth 3 \
  --hard-cap 100 >"$TMP_DIR/race-merge-ref.out" 2>&1; then
  echo "expected speculative merge budget check to catch racy growth" >&2
  cat "$TMP_DIR/race-merge-ref.out" >&2
  exit 1
fi

if ! grep -Fq 'Sources/Racy.swift' "$TMP_DIR/race-merge-ref.out"; then
  echo "expected speculative merge failure to name Racy.swift" >&2
  cat "$TMP_DIR/race-merge-ref.out" >&2
  exit 1
fi

if python3 scripts/swift_file_length_budget.py \
  --repo-root "$RACE_FIXTURE" \
  --budget .github/test-budget.tsv \
  --threshold 5 \
  --merge-ref main \
  --write-budget >"$TMP_DIR/race-write-budget.out" 2>&1; then
  echo "expected --write-budget with --merge-ref to fail" >&2
  exit 1
fi

if ! grep -Fq -- '--write-budget cannot be used with --merge-ref' "$TMP_DIR/race-write-budget.out"; then
  echo "expected --write-budget merge-ref argument error" >&2
  cat "$TMP_DIR/race-write-budget.out" >&2
  exit 1
fi

git -C "$RACE_FIXTURE" checkout -q -b conflict "$RACE_BASE"
printf 'feature readme\n' >"$RACE_FIXTURE/README.md"
git -C "$RACE_FIXTURE" add README.md
git -C "$RACE_FIXTURE" -c user.name='cmux CI' -c user.email='ci@example.invalid' commit -qm 'conflict on readme'

CONFLICT_MERGE_BASE="$(git -C "$RACE_FIXTURE" merge-base main conflict)"
set +e
python3 scripts/swift_file_length_budget.py \
  --repo-root "$RACE_FIXTURE" \
  --budget .github/test-budget.tsv \
  --threshold 5 \
  --base-ref "$CONFLICT_MERGE_BASE" \
  --incidental-growth 3 \
  --hard-cap 100 >"$TMP_DIR/conflict-plain.out" 2>&1
PLAIN_CONFLICT_STATUS=$?
python3 scripts/swift_file_length_budget.py \
  --repo-root "$RACE_FIXTURE" \
  --budget .github/test-budget.tsv \
  --threshold 5 \
  --base-ref "$CONFLICT_MERGE_BASE" \
  --merge-ref main \
  --merge-head conflict \
  --incidental-growth 3 \
  --hard-cap 100 >"$TMP_DIR/conflict-merge-ref.out" 2>&1
MERGE_REF_CONFLICT_STATUS=$?
set -e

if [ "$PLAIN_CONFLICT_STATUS" -ne "$MERGE_REF_CONFLICT_STATUS" ]; then
  echo "conflict fallback should produce the same exit code as plain base-ref evaluation" >&2
  echo "plain status: $PLAIN_CONFLICT_STATUS" >&2
  echo "merge-ref status: $MERGE_REF_CONFLICT_STATUS" >&2
  cat "$TMP_DIR/conflict-merge-ref.out" >&2
  exit 1
fi

if ! grep -Fq 'falling back to working-tree evaluation' "$TMP_DIR/conflict-merge-ref.out"; then
  echo "expected conflict fallback notice" >&2
  cat "$TMP_DIR/conflict-merge-ref.out" >&2
  exit 1
fi
