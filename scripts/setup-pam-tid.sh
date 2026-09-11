#!/bin/bash
# Enable Touch ID for sudo through Apple's update-surviving sudo_local policy.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Administrator privileges are required to enable Touch ID for sudo." >&2
  exit 1
fi

pam_file=/etc/pam.d/sudo_local
pam_template=/etc/pam.d/sudo_local.template

if [[ ! -f "$pam_file" ]]; then
  if [[ ! -f "$pam_template" ]]; then
    echo "Touch ID setup is unavailable on this macOS installation." >&2
    exit 1
  fi
  if ! cp "$pam_template" "$pam_file" 2>/dev/null; then
    echo "Touch ID setup could not update the sudo authentication policy." >&2
    exit 1
  fi
fi

if grep -Eq '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so([[:space:]]|$)' "$pam_file"; then
  echo "Touch ID for sudo is already enabled."
  exit 0
fi

if grep -Eq '^[[:space:]]*#[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so([[:space:]]|$)' "$pam_file"; then
  if ! sed -i '' -E \
      's/^[[:space:]]*#[[:space:]]*(auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so.*)$/\1/' \
      "$pam_file" 2>/dev/null; then
    echo "Touch ID setup could not update the sudo authentication policy." >&2
    exit 1
  fi
else
  if ! printf '\nauth       sufficient     pam_tid.so\n' >> "$pam_file" 2>/dev/null; then
    echo "Touch ID setup could not update the sudo authentication policy." >&2
    exit 1
  fi
fi

echo "Touch ID for sudo enabled."
