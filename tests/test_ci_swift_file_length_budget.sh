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
PY

python3 scripts/swift_file_length_budget.py \
  --repo-root "$FIXTURE" \
  --budget "$BUDGET" \
  --threshold 5 \
  --write-budget

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
