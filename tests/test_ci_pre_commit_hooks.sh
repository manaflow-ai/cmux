#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$TMP_DIR/repo"

mkdir -p "$REPO/scripts" "$REPO/.github" "$REPO/.githooks"
cp "$ROOT_DIR/scripts/swift_file_length_budget.py" "$REPO/scripts/swift_file_length_budget.py"
cp "$ROOT_DIR/.githooks/pre-commit" "$REPO/.githooks/pre-commit"
cat >"$REPO/.github/swift-file-length-budget.tsv" <<'EOF'
# cmux-owned Swift file length budget.
# Format: max_lines<TAB>relative path
EOF

git -C "$REPO" init --quiet
git -C "$REPO" config core.hooksPath .githooks
git -C "$REPO" config user.email "ci@example.com"
git -C "$REPO" config user.name "CI"

mkdir -p "$REPO/Sources" "$REPO/docs"
printf 'not swift\n' >"$REPO/docs/note.txt"
python3 - "$REPO/Sources/ExistingLarge.swift" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("".join(f"existing line {index}\n" for index in range(500)), encoding="utf-8")
PY
printf '500\tSources/ExistingLarge.swift\n' >>"$REPO/.github/swift-file-length-budget.tsv"
git -C "$REPO" add .github/swift-file-length-budget.tsv docs/note.txt
git -C "$REPO" add Sources/ExistingLarge.swift
git -C "$REPO" commit --quiet -m "initial fixture"

if ! (cd "$REPO" && .githooks/pre-commit >"$TMP_DIR/no-swift.out" 2>&1); then
  echo "pre-commit hook should ignore commits without staged Swift files" >&2
  cat "$TMP_DIR/no-swift.out" >&2
  exit 1
fi

printf '# cmux-owned Swift file length budget.\n# Format: max_lines<TAB>relative path\n' >"$REPO/.github/swift-file-length-budget.tsv"
git -C "$REPO" add .github/swift-file-length-budget.tsv
printf 'unstaged local shrink\n' >"$REPO/Sources/ExistingLarge.swift"

if (cd "$REPO" && .githooks/pre-commit >"$TMP_DIR/bad-budget-only.out" 2>&1); then
  echo "pre-commit hook should reject staged budget-only regressions" >&2
  exit 1
fi

if ! grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/bad-budget-only.out"; then
  echo "expected full file length checker failure for staged budget change" >&2
  cat "$TMP_DIR/bad-budget-only.out" >&2
  exit 1
fi

git -C "$REPO" checkout -- .github/swift-file-length-budget.tsv
git -C "$REPO" reset --quiet .github/swift-file-length-budget.tsv
git -C "$REPO" checkout -- Sources/ExistingLarge.swift

python3 - "$REPO/Sources/NewLarge.swift" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("".join(f"line {index}\n" for index in range(500)), encoding="utf-8")
PY

git -C "$REPO" add Sources/NewLarge.swift

printf 'working tree is smaller than the staged blob\n' >"$REPO/Sources/NewLarge.swift"
printf '500\tSources/NewLarge.swift\n' >"$REPO/.github/swift-file-length-budget.tsv"
rm "$REPO/.github/swift-file-length-budget.tsv"

if (cd "$REPO" && .githooks/pre-commit >"$TMP_DIR/large-swift.out" 2>&1); then
  echo "pre-commit hook should reject over-budget staged Swift files" >&2
  exit 1
fi

if ! grep -Fq 'Swift file length budget exceeded' "$TMP_DIR/large-swift.out"; then
  echo "expected file length checker failure from pre-commit hook" >&2
  cat "$TMP_DIR/large-swift.out" >&2
  exit 1
fi

if ! grep -Fq 'new Sources/NewLarge.swift' "$TMP_DIR/large-swift.out"; then
  echo "expected staged Swift file path in pre-commit output" >&2
  cat "$TMP_DIR/large-swift.out" >&2
  exit 1
fi
