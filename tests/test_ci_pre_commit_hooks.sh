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
git -C "$REPO" add docs/note.txt

if ! (cd "$REPO" && .githooks/pre-commit >"$TMP_DIR/no-swift.out" 2>&1); then
  echo "pre-commit hook should ignore commits without staged Swift files" >&2
  cat "$TMP_DIR/no-swift.out" >&2
  exit 1
fi

python3 - "$REPO/Sources/NewLarge.swift" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("".join(f"line {index}\n" for index in range(500)), encoding="utf-8")
PY

git -C "$REPO" add Sources/NewLarge.swift

printf 'working tree is smaller than the staged blob\n' >"$REPO/Sources/NewLarge.swift"

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
