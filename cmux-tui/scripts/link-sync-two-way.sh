#!/usr/bin/env bash
# A real two-way sync between two folders on one machine: a headless cmux-tui
# daemon serves the "machine" folder, the real `link sync` CLI is the "Mac".
# Edits on both sides merge; a same-line edit is kept as a conflict file.
# Usage: BIN=target/debug/cmux-tui scripts/link-sync-two-way.sh  (exit 0 = every check held)
set -u
BIN=$(realpath "${BIN:?set BIN to a cmux-tui binary}")
P=$(mktemp -d /tmp/syncproof.XXXX)
mkdir -p "$P/vm/home/work" "$P/vm/state" "$P/vm/acpmux" "$P/vm/etc" "$P/mac/state"
chmod 700 "$P/vm/acpmux"
printf 'cmux-vm inputs=sync-proof\n' >"$P/vm/etc/image-stamp"
printf 'owner\n' >"$P/vm/etc/vm-kind"
chmod 644 "$P/vm/etc/image-stamp" "$P/vm/etc/vm-kind"
chmod 755 "$P/vm/etc"
SOCK="$P/vm/m.sock"
LOCAL="$P/mac/notes"
REMOTE="$P/vm/home/work/notes"
FAILED=0
server() {
  env -u ACPMUX_SOCKET -u CMUX_TAG HOME="$P/vm/home" SHELL=/bin/sh CMUX_TUI_STATE_DIR="$P/vm/state" \
    CMUX_TUI_CONFIG="$P/vm/state/config.json" ACPMUX_HOME="$P/vm/acpmux" CMUX_TEST_CLOUD_ETC="$P/vm/etc" \
    CMUX_VM_ID=vm-sync-proof CMUX_CODEROUTER_URL=http://127.0.0.1:9 \
    "$BIN" server "$@" --json --session sync-proof --socket "$SOCK" </dev/null
}
mac() {
  echo "\$ cmux-tui link sync $1 --socket \$SOCK \$LOCAL \$REMOTE"
  env -u ACPMUX_SOCKET -u CMUX_TAG CMUX_TUI_STATE_DIR="$P/mac/state" \
    "$BIN" link sync "$1" --socket "$SOCK" "$LOCAL" "$REMOTE"
  local status=$?
  echo "(exit $status)"
  return $status
}
show() { echo "\$ cat $2/$3"; cat "$1/$3"; }
check() {
  if eval "$2"; then echo "CHECK ok: $1"; else echo "CHECK FAILED: $1"; FAILED=1; fi
}
stop() { server stop --end-terminals >/dev/null 2>&1; }
trap stop EXIT

mkdir -p "$LOCAL"
printf 'line 1\nline 2\nline 3\nline 4\nline 5\n' >"$LOCAL/notes.txt"

echo "## 1. start the machine's daemon"
server ensure >/dev/null || { echo "daemon did not start"; exit 1; }
echo "## 2. first push, Mac -> machine"
mac push || FAILED=1
echo
echo "## 3. edits on both sides"
echo "Mac:     line 1 -> 'line 1 edited on the Mac'"
echo "machine: line 5 -> 'line 5 edited on the machine'"
sed -i 's/^line 1$/line 1 edited on the Mac/' "$LOCAL/notes.txt"
sed -i 's/^line 5$/line 5 edited on the machine/' "$REMOTE/notes.txt"
echo
echo "## 4. pull, machine -> Mac (three-way against the kept revision)"
mac pull || FAILED=1
show "$LOCAL" Mac notes.txt
check "Mac has both edits" "grep -qx 'line 1 edited on the Mac' '$LOCAL/notes.txt' && grep -qx 'line 5 edited on the machine' '$LOCAL/notes.txt'"
echo
echo "## 5. push the merge back, Mac -> machine"
mac push || FAILED=1
show "$REMOTE" machine notes.txt
check "both folders identical" "diff -r -x .cmux-sync.json '$LOCAL' '$REMOTE'"
echo
echo "## 6. the kept base: a head naming a content-addressed revision"
HEAD_FILE=$(ls "$P/mac/state/link-sync/"*.head)
ID=$(cat "$HEAD_FILE")
echo "head $(basename "$HEAD_FILE") -> $ID"
SUM=$(sha256sum "$P/mac/state/link-sync/revisions/$ID" | cut -d' ' -f1)
echo "sha256(revisions/$ID) = $SUM"
check "revision name is its sha256" "[ '$SUM' = '$ID' ]"
echo
echo "## 7. restart the machine's daemon, pull again"
stop
server ensure >/dev/null || { echo "daemon did not restart"; exit 1; }
OUT=$(mac pull)
echo "$OUT"
check "nothing to bring back after a restart" "echo '$OUT' | grep -q '\"written\":0' && echo '$OUT' | grep -q '\"deleted\":0'"
echo
echo "## 8. a same-line edit on both sides is a conflict, kept"
echo "Mac: line 3 -> 'line 3 from the Mac'; machine: line 3 -> 'line 3 from the machine'"
sed -i 's/^line 3$/line 3 from the Mac/' "$LOCAL/notes.txt"
sed -i 's/^line 3$/line 3 from the machine/' "$REMOTE/notes.txt"
mac pull && { echo "pull should stop on a conflict"; FAILED=1; }
show "$LOCAL" Mac notes.txt
echo "\$ ls Mac"; ls "$LOCAL"
CONFLICT=$(ls "$LOCAL" | grep cmux-sync-conflict | head -1)
[ -n "$CONFLICT" ] && show "$LOCAL" Mac "$CONFLICT"
check "the Mac's own line is untouched" "grep -qx 'line 3 from the Mac' '$LOCAL/notes.txt'"
check "the conflict is kept in a conflict file with both lines" "[ -n '$CONFLICT' ] && grep -q 'line 3 from the Mac' '$LOCAL/$CONFLICT' && grep -q 'line 3 from the machine' '$LOCAL/$CONFLICT'"
check "the machine's copy is untouched" "grep -qx 'line 3 from the machine' '$REMOTE/notes.txt'"
echo
[ $FAILED = 0 ] && echo "ALL CHECKS HELD" || echo "SOME CHECK FAILED"
exit $FAILED
