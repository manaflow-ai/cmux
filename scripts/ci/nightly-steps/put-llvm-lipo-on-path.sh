#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary and prepare-nightly-variant:
# "Put llvm-lipo on PATH as lipo" (Linux runners only).
#
# thin-app-bundle.sh, drop-cef-without-arch.sh and the job's checks call lipo.
# llvm-lipo's -thin output is Apple lipo's, byte for byte; its -archs prints a
# trailing space that the exact comparisons refuse, so a shim trims it. A
# runner image without llvm (a fresh fleet Linux VM) installs it first.
set -euo pipefail
llvm_lipo="$(ls /usr/lib/llvm-18/bin/llvm-lipo 2>/dev/null || command -v llvm-lipo || ls /usr/lib/llvm-*/bin/llvm-lipo 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -z "$llvm_lipo" ]; then
  sudo apt-get update -qq && sudo apt-get install -y -qq llvm >/dev/null
  llvm_lipo="$(command -v llvm-lipo || ls /usr/lib/llvm-*/bin/llvm-lipo | sort -V | tail -n 1)"
fi
bin="$RUNNER_TEMP/lipo-bin"
mkdir -p "$bin"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'for arg in "$@"; do'
  echo '  if [ "$arg" = -archs ]; then'
  echo "    out=\"\$('$llvm_lipo' \"\$@\")\" || exit \$?"
  echo "    printf '%s\\n' \"\$out\" | sed 's/[[:space:]]*\$//'"
  echo '    exit 0'
  echo '  fi'
  echo 'done'
  echo "exec '$llvm_lipo' \"\$@\""
} > "$bin/lipo"
chmod +x "$bin/lipo"
echo "$bin" >> "$GITHUB_PATH"
"$llvm_lipo" --version | head -n 2
