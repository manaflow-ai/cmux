#!/usr/bin/env bash
# Probes a `cmux-projection share-mount` of another machine's folder (cmux-projection src/share.rs):
# lists it, times the first and a cached read of readme.txt and the first read of big.bin, checks
# that secret entries are absent and that every write answers EROFS. The served folder is a fixture
# with readme.txt, logs/run.log, big.bin and fake secrets (.ssh/, api-token.txt, .env).
# Run on the mounting machine: scripts/measure/projection-share-probe.sh MOUNT [READY_FILE]
set -u
M=$1
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
[ -n "${2:-}" ] && { echo "## ready"; cat "$2"; }
echo "## listing"; ls -la "$M"
echo "## links (text only, never followed by the serving machine)"; for l in "$M"/*; do [ -L "$l" ] && echo "$l -> $(readlink "$l")"; done
s=$(date +%s%N); cat "$M/readme.txt"; echo "first_read_ms=$(ms "$s")"
s=$(date +%s%N); cat "$M/readme.txt" >/dev/null; echo "cached_read_ms=$(ms "$s")"
s=$(date +%s%N); sha256sum "$M/big.bin"; echo "big_first_read_ms=$(ms "$s")"
echo "## secrets absent"; for p in .ssh .ssh/id_ed25519 api-token.txt .env; do [ -e "$M/$p" ] && echo "PRESENT $p" || echo "absent $p"; done
echo "## writes"
touch "$M/new" 2>&1; ( echo x >> "$M/readme.txt" ) 2>&1; mkdir "$M/d" 2>&1; rm "$M/readme.txt" 2>&1; ln -s a "$M/l" 2>&1
echo "## mount"; grep " $M " /proc/mounts
