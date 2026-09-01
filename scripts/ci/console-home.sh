#!/usr/bin/env bash
# Resolve a console user's complete NFS home path, including spaces.

cmux_console_home() {
  local user="${1:?console user is required}"
  {
    dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null || true
  } | sed -n 's/^[[:space:]]*NFSHomeDirectory:[[:space:]]*//p' | head -n 1
}
