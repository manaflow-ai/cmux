#!/usr/bin/env bash
# First-run findings row 18: after "Don't Allow" to macOS's Desktop prompt, `ls ~/Desktop` in a cmux terminal printed
# only "Operation not permitted", with no hint how to grant it later. The app's zsh layer
# (Resources/cmux-cli-path/zsh/.zshenv) prints one line that names the folder and where to allow it, after a failed
# command that named the folder, when the folder itself is refused. Cases: a refused folder gets the hint once; a
# missing file in a readable folder, a refused folder no command named, and a command that succeeded get none.
# The user's .zshrc stands in for macOS's refusal (`_cmux_folder_access_probe`), as no test can deny a folder.
# Needs only zsh (no app build).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
layer="$ROOT/Resources/cmux-cli-path/zsh"
[[ -r "$layer/.zshenv" ]] || { echo "FAIL: $layer/.zshenv is missing" >&2; exit 1; }
zsh=$(command -v zsh) || { echo "SKIP: no zsh"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/Documents" "$TMP/user"
# macOS refuses Desktop only.
cat >"$TMP/user/.zshrc" <<'EOF'
_cmux_folder_access_probe() {
  [[ $1 == */Desktop ]] && { print -u2 -- "ls: $1: Operation not permitted"; return 1 }
  /bin/ls -- "$1"
}
PS1='> '
EOF

run() {
  printf '%s\n' "$@" | (cd "$TMP" && env -i HOME="$TMP/home" TERM=dumb PATH=/usr/bin:/bin \
    CMUX_CLI_ZSH_ZDOTDIR="$TMP/user" ZDOTDIR="$layer" "$zsh" -i 2>&1) || true
}

fail=0
check() {
  local name="$1" want="$2" out="$3" count
  count=$(grep -c 'cmux: macOS blocks this app from your' <<<"$out" || true)
  if [[ "$count" != "$want" ]]; then
    echo "FAIL: $name: want $want hint line(s), got $count" >&2; printf '%s\n' "$out" | tail -12 >&2; fail=1; return
  fi
  echo "PASS: $name"
}

out=$(run 'ls ~/Desktop' 'ls ~/Desktop/notes.txt' 'echo end')
check "a refused folder gets the hint once per shell" 1 "$out"
if [[ "$out" != *"your Desktop folder. To allow it, open System Settings > Privacy & Security > Files & Folders and turn on Desktop Folder for cmux."* ]]; then
  echo "FAIL: the hint names the folder and where to allow it" >&2; printf '%s\n' "$out" >&2; fail=1
else
  echo "PASS: the hint names the folder and where to allow it"
fi
check "a missing file in a readable folder" 0 "$(run 'ls ~/Documents/missing.txt' 'echo end')"
check "a failed command that named no folder" 0 "$(run 'ls /nonexistent-cmux' 'echo end')"
check "a command that named the folder and succeeded" 0 "$(run 'echo Desktop' 'echo end')"
exit "$fail"
