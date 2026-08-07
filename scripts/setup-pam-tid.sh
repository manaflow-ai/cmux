#!/bin/bash
# Enable Touch ID for sudo through Apple's update-surviving sudo_local policy.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

pam_file=/etc/pam.d/sudo_local
pam_template=/etc/pam.d/sudo_local.template

if [[ ! -f "$pam_file" ]]; then
  if [[ ! -f "$pam_template" ]]; then
    echo "Missing $pam_template; this macOS installation does not provide sudo_local." >&2
    exit 1
  fi
  cp "$pam_template" "$pam_file"
fi

if grep -Eq '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so([[:space:]]|$)' "$pam_file"; then
  echo "Touch ID for sudo is already enabled in $pam_file."
  exit 0
fi

if grep -Eq '^[[:space:]]*#[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so([[:space:]]|$)' "$pam_file"; then
  sed -i '' -E \
    's/^[[:space:]]*#[[:space:]]*(auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so.*)$/\1/' \
    "$pam_file"
else
  printf '\nauth       sufficient     pam_tid.so\n' >> "$pam_file"
fi

echo "Touch ID for sudo enabled in $pam_file:"
grep -nE '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so([[:space:]]|$)' "$pam_file"
