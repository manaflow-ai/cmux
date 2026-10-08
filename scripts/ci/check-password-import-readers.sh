#!/usr/bin/env bash
# Verify that a Release app does not contain the browser password readers.
set -euo pipefail

binary="${1:?usage: $0 /path/to/cmux}"
if hits="$(grep -a -l -e nssPrivate -e ChromiumLoginDataReader -e FirefoxPasswordCrypto "$binary")"; then
  printf 'the notary test build still carries password readers:\n%s\n' "$hits" >&2
  exit 1
fi

echo "password-import readers absent from $binary"
