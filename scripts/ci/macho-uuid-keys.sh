#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <Mach-O-or-dSYM-path>" >&2
  exit 2
fi

tool="${CMUX_DWARFDUMP_TOOL:-dwarfdump}"
"$tool" --uuid "$1" | awk '
  $1 == "UUID:" && NF >= 3 { print $2 "\t" $3 }
' | sort
