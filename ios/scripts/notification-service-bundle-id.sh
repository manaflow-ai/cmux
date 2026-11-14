#!/usr/bin/env bash
set -euo pipefail

# Apple does not make the original BETA extension ID available to our team.
# Keep the host app and its keychain identity while using the registered ID.
case "${1:?host bundle identifier required}" in
  dev.cmux.app.beta) printf '%s.NotificationServiceV2\n' "$1" ;;
  # cmux CLASSIC, the classic app's internal TestFlight record.
  dev.cmux.app.classic) printf '%s.NotificationService\n' "$1" ;;
  *) printf '%s.NotificationService\n' "$1" ;;
esac
