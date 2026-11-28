#!/usr/bin/env bash
set -euo pipefail

# Probe common desktop-notification escape sequences.
# NOTE: cmux suppresses notifications when the app + surface are focused,
# so switch to another app/window while this runs.

esc=$'\033'
bel=$'\007'
st="${esc}\\"

send_seq() {
  local label="$1"
  local seq="$2"
  printf '\n[%s]\n' "$label"
  printf '%b' "$seq"
}

sleep_between() {
  # Ghostty rate limits notifications (~1/sec) and suppresses identical
  # content within a short window, so keep spacing + unique content.
  sleep 1.2
}

send_seq "OSC 9 (iTerm2) body-only, BEL terminator" "${esc}]9;cmux OSC 9 BEL $RANDOM${bel}"
sleep_between

send_seq "OSC 9 (iTerm2) body-only, ST terminator" "${esc}]9;cmux OSC 9 ST $RANDOM${st}"
sleep_between

send_seq "OSC 777 (rxvt) notify, BEL terminator" "${esc}]777;notify;cmux OSC 777 BEL $RANDOM;body ${RANDOM}${bel}"
sleep_between

send_seq "OSC 777 (rxvt) notify, ST terminator" "${esc}]777;notify;cmux OSC 777 ST $RANDOM;body ${RANDOM}${st}"

printf '\nDone.\n'
