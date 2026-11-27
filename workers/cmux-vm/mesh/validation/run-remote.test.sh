#!/usr/bin/env bash
# run-remote.sh must send only files Git tracks: an untracked .env, key or
# .cmux-scratch file in this directory never reaches the WireGuard host (cx-44j.25).
# Local-to-local: ssh is a no-op stand-in and rsync drops the host: prefix.
# Fixture files only. Run: bash workers/cmux-vm/mesh/validation/run-remote.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
src="$tmp/repo/validation" remote="$tmp/remote" bin="$tmp/bin"
mkdir -p "$src/wgprobe" "$remote/mesh-validation/out" "$bin"
cp "$HERE/run-remote.sh" "$src/"
echo 'console.log(1)' > "$src/05-stateful.ts"
echo 'package main' > "$src/wgprobe/main.go"
git -C "$tmp/repo" init -q && git -C "$tmp/repo" add -A && git -C "$tmp/repo" -c user.name=t -c user.email=t@t commit -qm base
mkdir -p "$src/.cmux-scratch"
for f in .env web.env.local prod.key cert.pem .cmux-scratch/notes.txt untracked-new.ts; do echo FIXTURE-NOT-A-SECRET > "$src/$f"; done
cat > "$bin/ssh" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$bin/rsync" <<'SH'
#!/usr/bin/env bash
out=()
for a in "$@"; do case "$a" in -*) out+=("$a") ;; *:*) out+=("${a#*:}") ;; *) out+=("$a") ;; esac; done
exec /usr/bin/rsync "${out[@]}"
SH
chmod +x "$bin/ssh" "$bin/rsync"
echo FIXTURE > "$tmp/key"
(cd "$remote" && PATH="$bin:$PATH" MESH_KEY_FILE="$tmp/key" MESH_RUN_ID=t bash "$src/run-remote.sh" 05-stateful.ts)
got="$(cd "$remote/mesh-validation" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"
want="05-stateful.ts run-remote.sh wgprobe/main.go "
[[ "$got" == "$want" ]] || { echo "FAIL: sent [$got], want [$want]" >&2; exit 1; }
echo "ok: only tracked files were sent"
