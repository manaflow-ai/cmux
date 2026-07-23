#!/usr/bin/env bash

cmux_dev_web_port_is_valid() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$port))
  (( numeric >= 1 && numeric <= 65535 ))
}

cmux_dev_web_port_is_positive() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$value))
  (( numeric > 0 ))
}

# Assign each tag a stable port in the reserved 3800-4799 dev range. POSIX
# cksum is stable across macOS and Linux, including local and cloud builders.
cmux_dev_web_port_for_tag() {
  local tag="$1"
  local checksum
  [[ -n "$tag" ]] || return 1
  checksum="$(printf '%s' "$tag" | cksum)"
  checksum="${checksum%% *}"
  [[ "$checksum" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((3800 + (checksum % 1000)))"
}

cmux_choose_dev_web_port() {
  local tag="$1"
  if cmux_dev_web_port_is_valid "${CMUX_PORT:-}"; then
    printf '%s\n' "$CMUX_PORT"
    return 0
  fi
  if cmux_dev_web_port_is_valid "${PORT:-}"; then
    printf '%s\n' "$PORT"
    return 0
  fi
  cmux_dev_web_port_for_tag "$tag"
}

cmux_choose_dev_web_port_range() {
  if cmux_dev_web_port_is_positive "${CMUX_PORT_RANGE:-}"; then
    printf '%s\n' "$CMUX_PORT_RANGE"
    return 0
  fi
  printf '1\n'
}

cmux_choose_dev_web_port_end() {
  local start="$1"
  local range="$2"
  if cmux_dev_web_port_is_valid "${CMUX_PORT_END:-}"; then
    printf '%s\n' "$CMUX_PORT_END"
    return 0
  fi
  local start_num=$((10#$start))
  local range_num=$((10#$range))
  local end=$((start_num + range_num - 1))
  if (( end > 65535 )); then
    end="$start_num"
  fi
  printf '%s\n' "$end"
}
