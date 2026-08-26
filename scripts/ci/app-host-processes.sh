#!/usr/bin/env bash

# Process ownership for CI app hosts is established by two independent facts:
# an app-authored receipt outside its redirected HOME and lsof's executable
# vnode for the live PID. Nothing in this file reads a process command line.

cmux_select_app_host_lsof() {
  if [ "${CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER:-0}" = "1" ]; then
    case "${CMUX_APP_HOST_LSOF:-}" in
      /*) ;;
      *)
        echo "FAIL: app-host test lsof override must be an absolute path" >&2
        return 1
        ;;
    esac
    if [ ! -x "$CMUX_APP_HOST_LSOF" ]; then
      echo "FAIL: app-host test lsof override is not executable" >&2
      return 1
    fi
    CMUX_SELECTED_APP_HOST_LSOF="$CMUX_APP_HOST_LSOF"
    return 0
  fi

  CMUX_SELECTED_APP_HOST_LSOF=/usr/sbin/lsof
  if [ ! -x "$CMUX_SELECTED_APP_HOST_LSOF" ]; then
    echo "FAIL: /usr/sbin/lsof is unavailable for app-host verification" >&2
    return 1
  fi
}

cmux_run_app_host_lsof() {
  "$CMUX_SELECTED_APP_HOST_LSOF" -w "$@"
}

cmux_validate_app_host_key() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      return 0
      ;;
    *)
      echo "FAIL: app-host receipt key is invalid" >&2
      return 1
      ;;
  esac
}

cmux_validate_app_host_receipt_dir() {
  local receipt_dir="$1"
  case "$receipt_dir" in
    /)
      echo "FAIL: app-host receipt directory cannot be the filesystem root" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "FAIL: app-host receipt directory must be absolute" >&2
      return 1
      ;;
  esac
  if [ -L "$receipt_dir" ] || [ ! -d "$receipt_dir" ]; then
    echo "FAIL: app-host receipt directory is unavailable" >&2
    return 1
  fi

  local resolved_receipt_dir
  resolved_receipt_dir="$(cd "$receipt_dir" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host receipt directory could not be resolved" >&2
    return 1
  }
  if [ "${receipt_dir%/}" != "$resolved_receipt_dir" ]; then
    echo "FAIL: app-host receipt directory changed identity" >&2
    return 1
  fi
  CMUX_VALIDATED_APP_HOST_RECEIPT_DIR="$resolved_receipt_dir"
}

cmux_validate_app_host_derived_data() {
  local derived_data_path="$1"
  case "$derived_data_path" in
    /)
      echo "FAIL: app-host DerivedData path cannot be the filesystem root" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "FAIL: app-host DerivedData path must be absolute" >&2
      return 1
      ;;
  esac
  if [ -L "$derived_data_path" ] || [ ! -d "$derived_data_path" ]; then
    echo "FAIL: app-host DerivedData path is unavailable" >&2
    return 1
  fi

  local resolved_derived_data
  resolved_derived_data="$(cd "$derived_data_path" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host DerivedData path could not be resolved" >&2
    return 1
  }
  if [ "${derived_data_path%/}" != "$resolved_derived_data" ]; then
    echo "FAIL: app-host DerivedData path changed identity" >&2
    return 1
  fi
  CMUX_VALIDATED_APP_HOST_DERIVED_DATA="$resolved_derived_data"
}

# Return success only for the one executable layout produced by an Xcode
# DerivedData root. The configuration component is exactly one path segment.
cmux_app_host_executable_is_scoped() {
  local derived_data_path="$1"
  local executable="$2"
  local products_prefix remainder configuration
  products_prefix="${derived_data_path%/}/Build/Products/"
  case "$executable" in
    "$products_prefix"*) remainder="${executable#"$products_prefix"}" ;;
    *) return 1 ;;
  esac
  configuration="${remainder%%/*}"
  if [ -z "$configuration" ] || [ "$configuration" = "." ] || [ "$configuration" = ".." ]; then
    return 1
  fi
  [ "$remainder" = "$configuration/cmux DEV.app/Contents/MacOS/cmux DEV" ]
}

cmux_validate_app_host_executable_scope() {
  local derived_data_path="$1"
  local executable="$2"
  cmux_validate_app_host_derived_data "$derived_data_path" || return 1
  if ! cmux_app_host_executable_is_scoped \
    "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA" "$executable"; then
    echo "FAIL: app-host receipt executable is outside the supplied DerivedData target" >&2
    return 1
  fi
  if [ -L "$executable" ]; then
    echo "FAIL: app-host receipt executable is a symlink" >&2
    return 1
  fi

  # When the product still exists, reject symlinked parent components too.
  local executable_parent resolved_executable_parent
  executable_parent="$(dirname "$executable")"
  if [ -d "$executable_parent" ]; then
    resolved_executable_parent="$(cd "$executable_parent" 2>/dev/null && pwd -P)" || {
      echo "FAIL: app-host executable parent could not be resolved" >&2
      return 1
    }
    if [ "$resolved_executable_parent" != "$executable_parent" ]; then
      echo "FAIL: app-host executable parent changed identity" >&2
      return 1
    fi
  fi
}

cmux_read_app_host_receipt() {
  local receipt_file="$1"
  local expected_key="$2"
  cmux_validate_app_host_key "$expected_key" || return 1
  if [ -L "$receipt_file" ] || [ ! -f "$receipt_file" ]; then
    echo "FAIL: app-host process receipt is unavailable" >&2
    return 1
  fi

  local line line_number receipt_version receipt_key receipt_pid receipt_executable receipt_fd
  line_number=0
  receipt_version=""
  receipt_key=""
  receipt_pid=""
  receipt_executable=""
  receipt_fd=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line_number" in
      1) receipt_version="${line#version=}"; [ "$line" != "$receipt_version" ] || receipt_version="" ;;
      2) receipt_key="${line#key=}"; [ "$line" != "$receipt_key" ] || receipt_key="" ;;
      3) receipt_pid="${line#pid=}"; [ "$line" != "$receipt_pid" ] || receipt_pid="" ;;
      4) receipt_executable="${line#executable=}"; [ "$line" != "$receipt_executable" ] || receipt_executable="" ;;
      5) receipt_fd="${line#receipt_fd=}"; [ "$line" != "$receipt_fd" ] || receipt_fd="" ;;
      *)
        echo "FAIL: app-host process receipt has unexpected fields" >&2
        return 1
        ;;
    esac
  done < "$receipt_file"

  if [ "$line_number" -ne 5 ] || [ "$receipt_version" != "2" ]; then
    echo "FAIL: app-host process receipt version is invalid" >&2
    return 1
  fi
  if [ "$receipt_key" != "$expected_key" ]; then
    echo "FAIL: app-host process receipt key does not match the run identity" >&2
    return 1
  fi
  case "$receipt_pid" in
    ''|0*|*[!0-9]*)
      echo "FAIL: app-host process receipt PID is invalid" >&2
      return 1
      ;;
  esac
  if [ "$(basename "$receipt_file")" != "app-host-$receipt_pid.receipt" ]; then
    echo "FAIL: app-host process receipt filename does not match its PID" >&2
    return 1
  fi
  case "$receipt_executable" in
    /*) ;;
    *)
      echo "FAIL: app-host process receipt executable must be absolute" >&2
      return 1
      ;;
  esac
  case "$receipt_fd" in
    ''|0[0-9]*|*[!0-9]*)
      echo "FAIL: app-host process receipt descriptor is invalid" >&2
      return 1
      ;;
  esac

  CMUX_PARSED_APP_HOST_RECEIPT_PID="$receipt_pid"
  CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE="$receipt_executable"
  CMUX_PARSED_APP_HOST_RECEIPT_FD="$receipt_fd"
}

# Set CMUX_APP_HOST_PRIMARY_EXECUTABLE. Return 2 when the PID has no text vnode,
# which means the receipt is stale. Return 1 for malformed lsof output.
cmux_app_host_primary_executable() {
  local pid="$1"
  cmux_select_app_host_lsof || return 1

  local output status line reported_pid first_executable
  if output="$(cmux_run_app_host_lsof -a -p "$pid" -d txt -Ffn)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 1 ] && [ -z "$output" ]; then
      return 2
    fi
    echo "FAIL: lsof could not inspect app-host PID $pid" >&2
    return 1
  fi

  reported_pid=""
  first_executable=""
  while IFS= read -r line; do
    case "$line" in
      p*)
        if [ -n "$reported_pid" ] || [ "${line#p}" != "$pid" ]; then
          echo "FAIL: lsof returned an unexpected app-host PID" >&2
          return 1
        fi
        reported_pid="${line#p}"
        ;;
      ftxt) ;;
      n*)
        if [ -z "$reported_pid" ]; then
          echo "FAIL: lsof returned an executable without a PID" >&2
          return 1
        fi
        if [ -z "$first_executable" ]; then
          first_executable="${line#n}"
        fi
        ;;
      '') ;;
      *)
        echo "FAIL: lsof returned malformed app-host process data" >&2
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$output")
  if [ "$reported_pid" != "$pid" ] || [ -z "$first_executable" ]; then
    echo "FAIL: lsof did not return an executable vnode for app-host PID $pid" >&2
    return 1
  fi
  # macOS appends this literal suffix when the process still owns the vnode
  # after its product tree was removed. The receipt records the launch path.
  CMUX_APP_HOST_PRIMARY_EXECUTABLE="${first_executable% (deleted)}"
}

# Prove that this process incarnation still owns the exact receipt it authored.
# Return 2 if the PID disappeared during verification and 1 for a live process
# without the recorded descriptor or for malformed lsof output.
cmux_app_host_receipt_descriptor_is_open() {
  local pid="$1"
  local receipt_fd="$2"
  local receipt_file="$3"
  cmux_select_app_host_lsof || return 1

  local output status line reported_pid reported_fd reported_access reported_path
  if output="$(cmux_run_app_host_lsof \
    -a -p "$pid" -d "$receipt_fd" -Fafn -- "$receipt_file")"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 1 ] && ! /bin/kill -0 "$pid" 2>/dev/null; then
      return 2
    fi
    echo "FAIL: live app-host PID $pid does not hold its process receipt" >&2
    return 1
  fi

  reported_pid=""
  reported_fd=""
  reported_access=""
  reported_path=""
  while IFS= read -r line; do
    case "$line" in
      p*)
        if [ -n "$reported_pid" ] || [ "${line#p}" != "$pid" ]; then
          echo "FAIL: lsof returned an unexpected receipt owner PID" >&2
          return 1
        fi
        reported_pid="${line#p}"
        ;;
      f*)
        if [ -z "$reported_pid" ] \
          || [ -n "$reported_fd" ] \
          || [ "${line#f}" != "$receipt_fd" ]; then
          echo "FAIL: lsof returned an unexpected receipt descriptor" >&2
          return 1
        fi
        reported_fd="${line#f}"
        ;;
      a*)
        # lsof's machine protocol reports descriptor and access separately as
        # `f9` and `aw`; only the human-readable table combines them as `9w`.
        if [ -z "$reported_pid" ] \
          || [ -n "$reported_access" ] \
          || [ "${line#a}" != "w" ]; then
          echo "FAIL: lsof returned an unexpected receipt access mode" >&2
          return 1
        fi
        reported_access="${line#a}"
        ;;
      n*)
        if [ -z "$reported_fd" ] \
          || [ -z "$reported_access" ] \
          || [ -n "$reported_path" ]; then
          echo "FAIL: lsof returned an unexpected receipt path" >&2
          return 1
        fi
        reported_path="${line#n}"
        ;;
      '') ;;
      *)
        echo "FAIL: lsof returned malformed receipt descriptor data" >&2
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$output")
  if [ "$reported_pid" != "$pid" ] \
    || [ "$reported_fd" != "$receipt_fd" ] \
    || [ "$reported_access" != "w" ] \
    || [ "$reported_path" != "$receipt_file" ]; then
    echo "FAIL: live app-host PID $pid does not hold its exact process receipt" >&2
    return 1
  fi
}

# Return 0 for an exact live identity, 2 for a stale receipt, and 1 for any
# mismatch. Callers must never signal a PID after a 1 or 2 result.
cmux_verify_app_host_receipt() {
  local receipt_file="$1"
  local expected_key="$2"
  local derived_data_path="$3"
  cmux_read_app_host_receipt "$receipt_file" "$expected_key" || return 1

  local receipt_pid receipt_executable receipt_fd primary_status receipt_status
  receipt_pid="$CMUX_PARSED_APP_HOST_RECEIPT_PID"
  receipt_executable="$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE"
  receipt_fd="$CMUX_PARSED_APP_HOST_RECEIPT_FD"
  cmux_validate_app_host_executable_scope \
    "$derived_data_path" "$receipt_executable" || return 1

  if cmux_app_host_primary_executable "$receipt_pid"; then
    primary_status=0
  else
    primary_status=$?
  fi
  if [ "$primary_status" -eq 2 ]; then
    return 2
  fi
  if [ "$primary_status" -ne 0 ]; then
    return 1
  fi
  if [ "$CMUX_APP_HOST_PRIMARY_EXECUTABLE" != "$receipt_executable" ]; then
    echo "FAIL: app-host receipt does not match the PID executable vnode" >&2
    return 1
  fi
  if cmux_app_host_receipt_descriptor_is_open \
    "$receipt_pid" "$receipt_fd" "$receipt_file"; then
    receipt_status=0
  else
    receipt_status=$?
  fi
  if [ "$receipt_status" -eq 2 ]; then
    return 2
  fi
  if [ "$receipt_status" -ne 0 ]; then
    return 1
  fi
  CMUX_VERIFIED_APP_HOST_PID="$receipt_pid"
  CMUX_VERIFIED_APP_HOST_EXECUTABLE="$receipt_executable"
}

cmux_app_host_add_pid() {
  local current="$1"
  local pid="$2"
  case " $current " in
    *" $pid "*) CMUX_APP_HOST_UPDATED_PIDS="$current" ;;
    *) CMUX_APP_HOST_UPDATED_PIDS="${current:+$current }$pid" ;;
  esac
}

# Inspect the first text vnode for every visible process and retain only exact
# cmux DEV executable layouts beneath the supplied DerivedData root.
cmux_scan_app_host_target_pids() {
  local derived_data_path="$1"
  cmux_validate_app_host_derived_data "$derived_data_path" || return 1
  cmux_select_app_host_lsof || return 1

  local output status line current_pid first_executable target_pids scoped_executable
  if output="$(cmux_run_app_host_lsof -d txt -Ffn)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    echo "FAIL: lsof could not enumerate app-host executable vnodes" >&2
    return 1
  fi

  current_pid=""
  first_executable=""
  target_pids=""
  while IFS= read -r line; do
    case "$line" in
      p*)
        if [ -n "$current_pid" ] && [ -n "$first_executable" ]; then
          scoped_executable="${first_executable% (deleted)}"
          if cmux_app_host_executable_is_scoped \
            "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA" "$scoped_executable"; then
            cmux_app_host_add_pid "$target_pids" "$current_pid"
            target_pids="$CMUX_APP_HOST_UPDATED_PIDS"
          fi
        fi
        current_pid="${line#p}"
        case "$current_pid" in ''|0*|*[!0-9]*)
          echo "FAIL: lsof returned an invalid process identifier" >&2
          return 1
        esac
        first_executable=""
        ;;
      ftxt) ;;
      n*)
        if [ -z "$current_pid" ]; then
          echo "FAIL: lsof returned an executable without a PID" >&2
          return 1
        fi
        if [ -z "$first_executable" ]; then
          first_executable="${line#n}"
        fi
        ;;
      '') ;;
      *)
        echo "FAIL: lsof returned malformed process enumeration data" >&2
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$output")
  if [ -n "$current_pid" ] && [ -n "$first_executable" ]; then
    scoped_executable="${first_executable% (deleted)}"
    if cmux_app_host_executable_is_scoped \
      "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA" "$scoped_executable"; then
      cmux_app_host_add_pid "$target_pids" "$current_pid"
      target_pids="$CMUX_APP_HOST_UPDATED_PIDS"
    fi
  fi
  CMUX_APP_HOST_TARGET_PIDS="$target_pids"
}

# Print every live PID authorized by a matching receipt. If lsof sees any target
# app host without such a receipt, return failure and print nothing.
cmux_app_host_verified_pids() {
  local receipt_dir="$1"
  local expected_key="$2"
  local derived_data_path="$3"
  cmux_validate_app_host_receipt_dir "$receipt_dir" || return 1
  cmux_validate_app_host_key "$expected_key" || return 1
  cmux_validate_app_host_derived_data "$derived_data_path" || return 1

  local verified_pids receipt_file verify_status verified_pid target_pid
  verified_pids=""
  for receipt_file in "$CMUX_VALIDATED_APP_HOST_RECEIPT_DIR"/*.receipt; do
    [ -e "$receipt_file" ] || continue
    if cmux_verify_app_host_receipt \
      "$receipt_file" "$expected_key" "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA"; then
      verify_status=0
    else
      verify_status=$?
    fi
    if [ "$verify_status" -eq 2 ]; then
      continue
    fi
    if [ "$verify_status" -ne 0 ]; then
      return 1
    fi
    verified_pid="$CMUX_VERIFIED_APP_HOST_PID"
    cmux_app_host_add_pid "$verified_pids" "$verified_pid"
    verified_pids="$CMUX_APP_HOST_UPDATED_PIDS"
  done

  cmux_scan_app_host_target_pids "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA" || return 1
  for target_pid in $CMUX_APP_HOST_TARGET_PIDS; do
    case " $verified_pids " in
      *" $target_pid "*) ;;
      *)
        echo "FAIL: live app-host target PID $target_pid has no verified receipt" >&2
        return 1
        ;;
    esac
  done

  for verified_pid in $verified_pids; do
    printf '%s\n' "$verified_pid"
  done
}

cmux_wait_for_app_host_exit() {
  local pid="$1"
  local expected_executable="$2"
  local attempt primary_status
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if cmux_app_host_primary_executable "$pid"; then
      primary_status=0
    else
      primary_status=$?
    fi
    if [ "$primary_status" -eq 2 ]; then
      return 0
    fi
    if [ "$primary_status" -ne 0 ]; then
      return 1
    fi
    if [ "$CMUX_APP_HOST_PRIMARY_EXECUTABLE" != "$expected_executable" ]; then
      return 0
    fi
    /bin/sleep 0.1
    attempt=$((attempt + 1))
  done
  return 2
}

cmux_terminate_one_verified_app_host() {
  local receipt_file="$1"
  local expected_key="$2"
  local derived_data_path="$3"
  local missing_product_runner_root="${4:-}"
  local verify_status pid executable wait_status
  if [ -n "$missing_product_runner_root" ]; then
    if cmux_verify_stale_app_host_receipt \
      "$receipt_file" "$expected_key" "$missing_product_runner_root"; then
      verify_status=0
    else
      verify_status=$?
    fi
  elif cmux_verify_app_host_receipt \
    "$receipt_file" "$expected_key" "$derived_data_path"; then
    verify_status=0
  else
    verify_status=$?
  fi
  if [ "$verify_status" -eq 2 ]; then
    return 0
  fi
  if [ "$verify_status" -ne 0 ]; then
    return 1
  fi
  pid="$CMUX_VERIFIED_APP_HOST_PID"
  executable="$CMUX_VERIFIED_APP_HOST_EXECUTABLE"

  /bin/kill -TERM "$pid" 2>/dev/null || {
    if cmux_wait_for_app_host_exit "$pid" "$executable"; then
      wait_status=0
    else
      wait_status=$?
    fi
    [ "$wait_status" -eq 0 ] && return 0
    echo "FAIL: verified app-host PID $pid could not be terminated" >&2
    return 1
  }
  if cmux_wait_for_app_host_exit "$pid" "$executable"; then
    wait_status=0
  else
    wait_status=$?
  fi
  if [ "$wait_status" -eq 0 ]; then
    return 0
  fi
  if [ "$wait_status" -ne 2 ]; then
    return 1
  fi

  # Re-authenticate immediately before escalating the signal.
  if [ -n "$missing_product_runner_root" ]; then
    if cmux_verify_stale_app_host_receipt \
      "$receipt_file" "$expected_key" "$missing_product_runner_root"; then
      verify_status=0
    else
      verify_status=$?
    fi
  elif cmux_verify_app_host_receipt \
    "$receipt_file" "$expected_key" "$derived_data_path"; then
    verify_status=0
  else
    verify_status=$?
  fi
  if [ "$verify_status" -eq 2 ]; then
    return 0
  fi
  if [ "$verify_status" -ne 0 ]; then
    return 1
  fi
  /bin/kill -KILL "$pid" 2>/dev/null || true
  if cmux_wait_for_app_host_exit "$pid" "$executable"; then
    wait_status=0
  else
    wait_status=$?
  fi
  if [ "$wait_status" -ne 0 ]; then
    echo "FAIL: verified app-host PID $pid remained live after SIGKILL" >&2
    return 1
  fi
}

cmux_terminate_verified_app_hosts() {
  local receipt_dir="$1"
  local expected_key="$2"
  local derived_data_path="$3"
  local verified_pids pid receipt_file remaining_pids
  verified_pids="$(cmux_app_host_verified_pids \
    "$receipt_dir" "$expected_key" "$derived_data_path")" || return 1

  for pid in $verified_pids; do
    receipt_file="${receipt_dir%/}/app-host-$pid.receipt"
    cmux_terminate_one_verified_app_host \
      "$receipt_file" "$expected_key" "$derived_data_path" || return 1
  done

  remaining_pids="$(cmux_app_host_verified_pids \
    "$receipt_dir" "$expected_key" "$derived_data_path")" || return 1
  if [ -n "$remaining_pids" ]; then
    echo "FAIL: verified app-host processes remain after termination" >&2
    return 1
  fi
}

cmux_app_host_derived_data_from_executable() {
  local runner_root="$1"
  local executable="$2"
  local suffix derived_data_path resolved_runner_root
  suffix="/Build/Products/"
  resolved_runner_root="${runner_root%/}"
  case "$executable" in
    *"//"*|*"/./"*|*/.|*"/../"*|*/..) return 1 ;;
  esac
  case "$executable" in
    "$resolved_runner_root"/*"$suffix"*) ;;
    *) return 1 ;;
  esac
  derived_data_path="${executable%%"$suffix"*}"
  case "$derived_data_path" in
    "$resolved_runner_root"/*) ;;
    *) return 1 ;;
  esac
  cmux_app_host_executable_is_scoped \
    "$derived_data_path" "$executable" || return 1
  CMUX_APP_HOST_RECEIPT_DERIVED_DATA="$derived_data_path"
}

cmux_validate_app_host_runner_root() {
  local runner_root="$1"
  case "$runner_root" in
    /)
      echo "FAIL: app-host runner root cannot be the filesystem root" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "FAIL: app-host runner root must be absolute" >&2
      return 1
      ;;
  esac
  if [ -L "$runner_root" ] || [ ! -d "$runner_root" ]; then
    echo "FAIL: app-host runner root is unavailable" >&2
    return 1
  fi
  local resolved_runner_root
  resolved_runner_root="$(cd "$runner_root" 2>/dev/null && pwd -P)" || return 1
  if [ "${runner_root%/}" != "$resolved_runner_root" ]; then
    echo "FAIL: app-host runner root changed identity" >&2
    return 1
  fi
  CMUX_VALIDATED_APP_HOST_RUNNER_ROOT="$resolved_runner_root"
}

# This verifier deliberately does not require the DerivedData root to exist.
# A live process can retain its deleted executable vnode after Xcode products
# are removed. The canonical runner root, receipt path, and lsof vnode still
# provide independent lexical boundaries in that state.
cmux_verify_stale_app_host_receipt() {
  local receipt_file="$1"
  local expected_key="$2"
  local runner_root="$3"
  cmux_validate_app_host_runner_root "$runner_root" || return 1
  runner_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  cmux_read_app_host_receipt "$receipt_file" "$expected_key" || return 1

  local receipt_pid receipt_executable receipt_fd primary_status receipt_status
  receipt_pid="$CMUX_PARSED_APP_HOST_RECEIPT_PID"
  receipt_executable="$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE"
  receipt_fd="$CMUX_PARSED_APP_HOST_RECEIPT_FD"
  if ! cmux_app_host_derived_data_from_executable \
    "$runner_root" "$receipt_executable"; then
    echo "FAIL: stale app-host receipt executable is outside the runner work root" >&2
    return 1
  fi
  if cmux_app_host_primary_executable "$receipt_pid"; then
    primary_status=0
  else
    primary_status=$?
  fi
  if [ "$primary_status" -eq 2 ]; then
    return 2
  fi
  if [ "$primary_status" -ne 0 ]; then
    return 1
  fi
  if [ "$CMUX_APP_HOST_PRIMARY_EXECUTABLE" != "$receipt_executable" ]; then
    echo "FAIL: stale app-host receipt does not match the PID executable vnode" >&2
    return 1
  fi
  if cmux_app_host_receipt_descriptor_is_open \
    "$receipt_pid" "$receipt_fd" "$receipt_file"; then
    receipt_status=0
  else
    receipt_status=$?
  fi
  if [ "$receipt_status" -eq 2 ]; then
    return 2
  fi
  if [ "$receipt_status" -ne 0 ]; then
    return 1
  fi

  CMUX_VERIFIED_APP_HOST_PID="$receipt_pid"
  CMUX_VERIFIED_APP_HOST_EXECUTABLE="$receipt_executable"
}

cmux_record_runner_app_host_target() {
  local runner_root="$1"
  local pid="$2"
  local lsof_executable="$3"
  local executable="${lsof_executable% (deleted)}"
  if ! cmux_app_host_derived_data_from_executable \
    "$runner_root" "$executable"; then
    return 0
  fi
  local target_index="${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}"
  CMUX_APP_HOST_RUNNER_TARGET_PIDS[target_index]="$pid"
  CMUX_APP_HOST_RUNNER_TARGET_EXECUTABLES[target_index]="$executable"
}

# Enumerate process executable vnodes, not command lines. The first txt vnode
# in each lsof process record is the launched executable on macOS.
cmux_scan_runner_app_host_targets() {
  local runner_root="$1"
  cmux_validate_app_host_runner_root "$runner_root" || return 1
  runner_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  cmux_select_app_host_lsof || return 1

  local output status line current_pid first_executable
  if output="$(cmux_run_app_host_lsof -d txt -Ffn)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    echo "FAIL: lsof could not enumerate runner app-host executable vnodes" >&2
    return 1
  fi

  CMUX_APP_HOST_RUNNER_TARGET_PIDS=()
  CMUX_APP_HOST_RUNNER_TARGET_EXECUTABLES=()
  current_pid=""
  first_executable=""
  while IFS= read -r line; do
    case "$line" in
      p*)
        if [ -n "$current_pid" ] && [ -n "$first_executable" ]; then
          cmux_record_runner_app_host_target \
            "$runner_root" \
            "$current_pid" "$first_executable"
        fi
        current_pid="${line#p}"
        case "$current_pid" in ''|0*|*[!0-9]*)
          echo "FAIL: lsof returned an invalid runner process identifier" >&2
          return 1
        esac
        first_executable=""
        ;;
      ftxt) ;;
      n*)
        if [ -z "$current_pid" ]; then
          echo "FAIL: lsof returned a runner executable without a PID" >&2
          return 1
        fi
        if [ -z "$first_executable" ]; then
          first_executable="${line#n}"
        fi
        ;;
      '') ;;
      *)
        echo "FAIL: lsof returned malformed runner process data" >&2
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$output")
  if [ -n "$current_pid" ] && [ -n "$first_executable" ]; then
    cmux_record_runner_app_host_target \
      "$runner_root" \
      "$current_pid" "$first_executable"
  fi
}

cmux_app_host_scope_mtime() {
  local scope_path="$1"
  local mtime
  if mtime="$(/usr/bin/stat -f '%m' "$scope_path" 2>/dev/null)"; then
    :
  elif mtime="$(/usr/bin/stat -c '%Y' "$scope_path" 2>/dev/null)"; then
    :
  else
    echo "FAIL: app-host scope timestamp is unavailable" >&2
    return 1
  fi
  case "$mtime" in
    ''|*[!0-9]*)
      echo "FAIL: app-host scope timestamp is invalid" >&2
      return 1
      ;;
  esac
  CMUX_APP_HOST_SCOPE_MTIME="$mtime"
}

cmux_app_host_scope_file_identity() {
  local scope_path="$1"
  local identity
  if identity="$(/usr/bin/stat -f '%d:%i:%m' "$scope_path" 2>/dev/null)"; then
    :
  elif identity="$(/usr/bin/stat -c '%d:%i:%Y' "$scope_path" 2>/dev/null)"; then
    :
  else
    echo "FAIL: app-host scope file identity is unavailable" >&2
    return 1
  fi
  case "$identity" in
    *[!0-9:]*|:*|*:)
      echo "FAIL: app-host scope file identity is invalid" >&2
      return 1
      ;;
  esac
  CMUX_APP_HOST_SCOPE_FILE_IDENTITY="$identity"
}

# The newest confirmation may belong to a job that has prepared its scope but
# is still waiting for the canonical machine lock. Only authenticated v3 files
# owned by this account with private permissions participate. Shared /tmp debris
# cannot weaken newest-scope protection or authorize a process signal.
cmux_newest_app_host_confirmation_mtime() {
  local system_temp_root="$1"
  cmux_validate_app_host_runner_root "$system_temp_root" || return 1
  system_temp_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"

  local current_uid confirmation_file confirmation_name key
  local newest_mtime mtime initial_identity final_identity
  current_uid="$(/usr/bin/id -u)" || {
    echo "FAIL: app-host confirmation account is unavailable" >&2
    return 1
  }
  newest_mtime=0
  for confirmation_file in "$system_temp_root"/cmux-ah-*.confirm; do
    if [ -L "$confirmation_file" ] || [ ! -f "$confirmation_file" ]; then
      continue
    fi
    confirmation_name="${confirmation_file##*/}"
    key="${confirmation_name#cmux-ah-}"
    key="${key%.confirm}"
    if ! cmux_validate_app_host_key "$key" >/dev/null 2>&1 \
      || ! cmux_app_host_scope_file_identity \
        "$confirmation_file" >/dev/null 2>&1; then
      continue
    fi
    initial_identity="$CMUX_APP_HOST_SCOPE_FILE_IDENTITY"
    if ! cmux_validate_stale_app_host_confirmation \
      "$confirmation_file" "$system_temp_root" "$key" >/dev/null 2>&1 \
      || ! cmux_app_host_scope_metadata \
        "$confirmation_file" >/dev/null 2>&1 \
      || [ "$CMUX_APP_HOST_SCOPE_UID" != "$current_uid" ] \
      || [ "$CMUX_APP_HOST_SCOPE_MODE" != "600" ] \
      || ! cmux_app_host_scope_file_identity \
        "$confirmation_file" >/dev/null 2>&1; then
      continue
    fi
    final_identity="$CMUX_APP_HOST_SCOPE_FILE_IDENTITY"
    if [ "$final_identity" != "$initial_identity" ]; then
      continue
    fi
    mtime="${final_identity##*:}"
    if [ "$mtime" -gt "$newest_mtime" ]; then
      newest_mtime="$mtime"
    fi
  done
  CMUX_NEWEST_APP_HOST_CONFIRMATION_MTIME="$newest_mtime"
}

# Set CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE to 1 only for an authenticated v3
# scope that is old enough, is not current, and is not tied for newest.
cmux_classify_app_host_scope_recovery_eligibility() {
  local key="$1"
  local preserved_key="$2"
  local version="$3"
  local mtime="$4"
  local newest_mtime="$5"
  local now_epoch="$6"
  local minimum_age_seconds="$7"
  CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE=0

  if [ "$version" != "3" ] \
    || [ -z "$mtime" ] \
    || [ "$key" = "$preserved_key" ] \
    || [ "$mtime" -eq "$newest_mtime" ] \
    || [ "$mtime" -gt "$now_epoch" ]; then
    return 0
  fi
  if [ $((now_epoch - mtime)) -lt "$minimum_age_seconds" ]; then
    return 0
  fi
  CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE=1
}

# Validate a complete or confirmation-only process-free scope. Missing mutable
# roots are allowed because the confirmation is published before either mkdir;
# any root that does exist must retain its deterministic path, private mode,
# owner, type, and canonical identity.
cmux_validate_abandoned_app_host_scope() {
  local system_temp_root="$1"
  local key="$2"
  local expected_uid="$3"
  local app_host_home="$system_temp_root/cmux-ah-$key"
  local app_host_receipt_dir="$system_temp_root/cmux-ah-$key-receipts"
  local confirmation_file="$system_temp_root/cmux-ah-$key.confirm"

  cmux_validate_stale_app_host_confirmation \
    "$confirmation_file" "$system_temp_root" "$key" || return 1
  if [ "$CMUX_VALIDATED_STALE_APP_HOST_HOME" != "$app_host_home" ] \
    || [ "$CMUX_VALIDATED_STALE_APP_HOST_RECEIPT_DIR" != "$app_host_receipt_dir" ] \
    || [ "$CMUX_VALIDATED_STALE_APP_HOST_CONFIRMATION_FILE" != "$confirmation_file" ]; then
    echo "FAIL: abandoned app-host scope changed identity" >&2
    return 1
  fi

  local scope_path expected_mode resolved_scope
  for scope_path in \
    "$app_host_home" "$app_host_receipt_dir" "$confirmation_file"
  do
    if [ "$scope_path" != "$confirmation_file" ] \
      && [ ! -e "$scope_path" ] \
      && [ ! -L "$scope_path" ]; then
      continue
    fi
    if [ -L "$scope_path" ]; then
      echo "FAIL: abandoned app-host scope contains a root symlink" >&2
      return 1
    fi
    case "$scope_path" in
      "$confirmation_file")
        expected_mode=600
        [ -f "$scope_path" ] || {
          echo "FAIL: abandoned app-host confirmation changed type" >&2
          return 1
        }
        ;;
      *)
        expected_mode=700
        [ -d "$scope_path" ] || {
          echo "FAIL: abandoned app-host scope root changed type" >&2
          return 1
        }
        resolved_scope="$(cd "$scope_path" 2>/dev/null && pwd -P)" || {
          echo "FAIL: abandoned app-host scope root is unavailable" >&2
          return 1
        }
        if [ "$resolved_scope" != "$scope_path" ]; then
          echo "FAIL: abandoned app-host scope root changed identity" >&2
          return 1
        fi
        ;;
    esac
    cmux_app_host_scope_metadata "$scope_path" || return 1
    if [ "$CMUX_APP_HOST_SCOPE_UID" != "$expected_uid" ]; then
      echo "FAIL: abandoned app-host scope owner is not trusted" >&2
      return 1
    fi
    if [ "$CMUX_APP_HOST_SCOPE_MODE" != "$expected_mode" ]; then
      echo "FAIL: abandoned app-host scope permissions are not private" >&2
      return 1
    fi
  done

  CMUX_VALIDATED_ABANDONED_APP_HOST_HOME="$app_host_home"
  CMUX_VALIDATED_ABANDONED_APP_HOST_RECEIPT_DIR="$app_host_receipt_dir"
  CMUX_VALIDATED_ABANDONED_APP_HOST_CONFIRMATION_FILE="$confirmation_file"
}

# Match one runner-scoped live PID to one old prior-run authority scope. This
# is only an admission check. The caller completes a runner-wide preflight and
# revalidates every admitted authority before any signal is sent.
cmux_find_eligible_prior_app_host_receipt() {
  local runner_root="$1"
  local system_temp_root="$2"
  local preserved_key="$3"
  local target_pid="$4"
  local target_executable="$5"
  local newest_mtime="$6"
  local now_epoch="$7"
  local minimum_age_seconds="$8"

  local current_uid receipt_file receipt_dir receipt_dir_name expected_key
  local confirmation_file mtime confirmation_identity verify_status
  local matching_receipts matched_receipt matched_key matched_derived_data
  local matched_confirmation matched_confirmation_identity matched_confirmation_mtime
  current_uid="$(/usr/bin/id -u)" || {
    echo "FAIL: prior app-host cleanup account is unavailable" >&2
    return 1
  }
  matching_receipts=0
  matched_receipt=""
  matched_key=""
  matched_derived_data=""
  matched_confirmation=""
  matched_confirmation_identity=""
  matched_confirmation_mtime=""

  for receipt_file in \
    "$system_temp_root"/cmux-ah-*-receipts/"app-host-$target_pid.receipt"; do
    if [ ! -e "$receipt_file" ] && [ ! -L "$receipt_file" ]; then
      continue
    fi
    receipt_dir="$(dirname "$receipt_file")"
    cmux_validate_app_host_receipt_dir "$receipt_dir" || return 1
    receipt_dir_name="$(basename "$receipt_dir")"
    expected_key="${receipt_dir_name#cmux-ah-}"
    expected_key="${expected_key%-receipts}"
    cmux_validate_app_host_key "$expected_key" || return 1
    cmux_read_app_host_receipt "$receipt_file" "$expected_key" || return 1
    if [ "$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE" != "$target_executable" ]; then
      continue
    fi
    matching_receipts=$((matching_receipts + 1))
    if [ "$expected_key" = "$preserved_key" ]; then
      echo "FAIL: current app-host PID $target_pid was not authenticated by its current receipt set" >&2
      return 1
    fi

    cmux_validate_abandoned_app_host_scope \
      "$system_temp_root" "$expected_key" "$current_uid" || return 1
    if [ ! -d "$CMUX_VALIDATED_ABANDONED_APP_HOST_RECEIPT_DIR" ]; then
      echo "FAIL: prior app-host receipt root is unavailable" >&2
      return 1
    fi
    confirmation_file="$CMUX_VALIDATED_ABANDONED_APP_HOST_CONFIRMATION_FILE"
    cmux_app_host_scope_mtime "$confirmation_file" || return 1
    mtime="$CMUX_APP_HOST_SCOPE_MTIME"
    cmux_classify_app_host_scope_recovery_eligibility \
      "$expected_key" "$preserved_key" 3 "$mtime" "$newest_mtime" \
      "$now_epoch" "$minimum_age_seconds" || return 1
    if [ "$CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE" -ne 1 ]; then
      echo "FAIL: foreign app-host PID $target_pid is not eligible for prior-run recovery" >&2
      return 1
    fi
    cmux_app_host_scope_file_identity "$confirmation_file" || return 1
    confirmation_identity="$CMUX_APP_HOST_SCOPE_FILE_IDENTITY"

    if cmux_verify_stale_app_host_receipt \
      "$receipt_file" "$expected_key" "$runner_root"; then
      verify_status=0
    else
      verify_status=$?
    fi
    if [ "$verify_status" -eq 2 ]; then
      return 2
    fi
    if [ "$verify_status" -ne 0 ]; then
      return 1
    fi
    matched_receipt="$receipt_file"
    matched_key="$expected_key"
    matched_derived_data="$CMUX_APP_HOST_RECEIPT_DERIVED_DATA"
    matched_confirmation="$confirmation_file"
    matched_confirmation_identity="$confirmation_identity"
    matched_confirmation_mtime="$mtime"
  done

  if [ "$matching_receipts" -eq 0 ]; then
    # Avoid a false missing-receipt error if the target exited during preflight.
    if cmux_app_host_primary_executable "$target_pid"; then
      if [ "$CMUX_APP_HOST_PRIMARY_EXECUTABLE" != "$target_executable" ]; then
        return 2
      fi
    else
      verify_status=$?
      if [ "$verify_status" -eq 2 ]; then
        return 2
      fi
      return 1
    fi
    echo "FAIL: foreign app-host PID $target_pid has no eligible prior-run receipt" >&2
    return 1
  fi
  if [ "$matching_receipts" -ne 1 ]; then
    echo "FAIL: live app-host PID $target_pid has ambiguous prior-run receipts" >&2
    return 1
  fi

  CMUX_PRIOR_APP_HOST_RECEIPT="$matched_receipt"
  CMUX_PRIOR_APP_HOST_KEY="$matched_key"
  CMUX_PRIOR_APP_HOST_DERIVED_DATA="$matched_derived_data"
  CMUX_PRIOR_APP_HOST_CONFIRMATION_FILE="$matched_confirmation"
  CMUX_PRIOR_APP_HOST_CONFIRMATION_IDENTITY="$matched_confirmation_identity"
  CMUX_PRIOR_APP_HOST_CONFIRMATION_MTIME="$matched_confirmation_mtime"
}

# Reclaim only authenticated, process-free scopes older than the grace period.
# The current key and every scope tied for newest confirmation are preserved.
# All candidates are validated and previewed before the first deletion.
cmux_reclaim_abandoned_app_host_scopes() {
  local runner_root="$1"
  local system_temp_root="$2"
  local preserved_key="$3"
  local now_epoch="$4"
  local minimum_age_seconds="$5"
  shift 5

  cmux_validate_app_host_runner_root "$runner_root" || return 1
  runner_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  cmux_validate_app_host_runner_root "$system_temp_root" || return 1
  system_temp_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  cmux_validate_app_host_key "$preserved_key" || return 1
  case "$now_epoch:$minimum_age_seconds" in
    *[!0-9:]*|:*|*:)
      echo "FAIL: abandoned app-host scope age inputs are invalid" >&2
      return 1
      ;;
  esac

  cmux_scan_runner_app_host_targets "$runner_root" || return 1
  if [ "${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}" -ne 0 ]; then
    echo "FAIL: refusing abandoned scope reclamation while an app host is live" >&2
    return 1
  fi

  local current_uid confirmation_file confirmation_name key first_line
  local seen_keys key_count key_index newest_mtime candidate_count
  local mtime candidate_index scope_path
  local -a scope_keys scope_mtimes scope_versions candidate_keys candidate_mtimes
  current_uid="$(/usr/bin/id -u)" || {
    echo "FAIL: abandoned app-host cleanup account is unavailable" >&2
    return 1
  }
  scope_keys=()
  scope_mtimes=()
  scope_versions=()
  candidate_keys=()
  candidate_mtimes=()
  seen_keys=""
  key_count=0
  cmux_newest_app_host_confirmation_mtime "$system_temp_root" || return 1
  newest_mtime="$CMUX_NEWEST_APP_HOST_CONFIRMATION_MTIME"

  if [ "$#" -gt 0 ]; then
    for key in "$@"; do
      case " $seen_keys " in *" $key "*) continue ;; esac
      cmux_validate_app_host_key "$key" || return 1
      seen_keys="${seen_keys:+$seen_keys }$key"
      scope_keys[key_count]="$key"
      key_count=$((key_count + 1))
    done
  else
    for confirmation_file in "$system_temp_root"/cmux-ah-*.confirm; do
      if [ ! -e "$confirmation_file" ] && [ ! -L "$confirmation_file" ]; then
        continue
      fi
      confirmation_name="${confirmation_file##*/}"
      key="${confirmation_name#cmux-ah-}"
      key="${key%.confirm}"
      case " $seen_keys " in *" $key "*) continue ;; esac
      cmux_validate_app_host_key "$key" || return 1
      seen_keys="${seen_keys:+$seen_keys }$key"
      scope_keys[key_count]="$key"
      key_count=$((key_count + 1))
    done
  fi

  key_index=0
  while [ "$key_index" -lt "$key_count" ]; do
    key="${scope_keys[$key_index]}"
    confirmation_file="$system_temp_root/cmux-ah-$key.confirm"
    if [ -L "$confirmation_file" ]; then
      echo "FAIL: abandoned app-host confirmation is a symlink" >&2
      return 1
    fi
    if [ ! -f "$confirmation_file" ]; then
      key_index=$((key_index + 1))
      continue
    fi
    IFS= read -r first_line < "$confirmation_file" || {
      echo "FAIL: abandoned app-host confirmation could not be read" >&2
      return 1
    }
    cmux_app_host_scope_mtime "$confirmation_file" || return 1
    mtime="$CMUX_APP_HOST_SCOPE_MTIME"
    scope_mtimes[key_index]="$mtime"
    if [ "$first_line" != "version=3" ]; then
      echo "Preserving unsupported app-host confirmation: $confirmation_file"
      key_index=$((key_index + 1))
      continue
    fi
    scope_versions[key_index]=3
    key_index=$((key_index + 1))
  done

  candidate_count=0
  key_index=0
  while [ "$key_index" -lt "$key_count" ]; do
    key="${scope_keys[$key_index]}"
    mtime="${scope_mtimes[$key_index]:-}"
    cmux_classify_app_host_scope_recovery_eligibility \
      "$key" "$preserved_key" "${scope_versions[$key_index]:-}" \
      "$mtime" "$newest_mtime" "$now_epoch" "$minimum_age_seconds" \
      || return 1
    if [ "$CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE" -ne 1 ]; then
      key_index=$((key_index + 1))
      continue
    fi
    cmux_validate_abandoned_app_host_scope \
      "$system_temp_root" "$key" "$current_uid" || return 1
    candidate_keys[candidate_count]="$key"
    candidate_mtimes[candidate_count]="$mtime"
    candidate_count=$((candidate_count + 1))
    echo "Confirmed abandoned app-host cleanup candidate: $system_temp_root/cmux-ah-$key"
    key_index=$((key_index + 1))
  done

  # Recheck global liveness after candidate preflight and before mutation.
  cmux_scan_runner_app_host_targets "$runner_root" || return 1
  if [ "${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}" -ne 0 ]; then
    echo "FAIL: an app host became live before abandoned scope reclamation" >&2
    return 1
  fi

  candidate_index=0
  while [ "$candidate_index" -lt "$candidate_count" ]; do
    key="${candidate_keys[$candidate_index]}"
    cmux_validate_abandoned_app_host_scope \
      "$system_temp_root" "$key" "$current_uid" || return 1
    confirmation_file="$CMUX_VALIDATED_ABANDONED_APP_HOST_CONFIRMATION_FILE"
    cmux_app_host_scope_mtime "$confirmation_file" || return 1
    if [ "$CMUX_APP_HOST_SCOPE_MTIME" != "${candidate_mtimes[$candidate_index]}" ]; then
      echo "FAIL: abandoned app-host confirmation changed during cleanup" >&2
      return 1
    fi
    rm -rf -- "$CMUX_VALIDATED_ABANDONED_APP_HOST_HOME"
    rm -rf -- "$CMUX_VALIDATED_ABANDONED_APP_HOST_RECEIPT_DIR"
    rm -f -- "$confirmation_file"
    for scope_path in \
      "$CMUX_VALIDATED_ABANDONED_APP_HOST_HOME" \
      "$CMUX_VALIDATED_ABANDONED_APP_HOST_RECEIPT_DIR" \
      "$confirmation_file"
    do
      if [ -e "$scope_path" ] || [ -L "$scope_path" ]; then
        echo "FAIL: abandoned app-host scope remains after cleanup" >&2
        return 1
      fi
    done
    candidate_index=$((candidate_index + 1))
  done
}

# Retry recovery always owns the immutable current run key. While holding the
# canonical machine lock, it may also admit a prior-run owner whose confirmation
# is authenticated, older than the current scope, and not newest. Every live PID
# and admitted confirmation is preflighted twice before any signal. Process-free
# scope deletion retains the reclamation grace and remains advisory after process
# safety is established.
cmux_recover_owned_app_host_attempt() {
  local receipt_dir="$1"
  local expected_key="$2"
  local derived_data_path="$3"
  local runner_root="$4"
  local system_temp_root="$5"
  local now_epoch="${6:-}"
  local reclamation_minimum_age_seconds="${7:-21600}"
  local live_recovery_minimum_age_seconds=0
  shift "$(( $# < 7 ? $# : 7 ))"

  if [ "${CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER:-0}" != "1" ] \
    && [ "${CMUX_APP_HOST_TEST_LOCK_ACTIVE:-0}" != "1" ]; then
    echo "FAIL: app-host recovery requires the canonical machine lock" >&2
    return 1
  fi

  cmux_validate_app_host_receipt_dir "$receipt_dir" || return 1
  receipt_dir="$CMUX_VALIDATED_APP_HOST_RECEIPT_DIR"
  cmux_validate_app_host_key "$expected_key" || return 1
  cmux_validate_app_host_derived_data "$derived_data_path" || return 1
  derived_data_path="$CMUX_VALIDATED_APP_HOST_DERIVED_DATA"
  cmux_validate_app_host_runner_root "$runner_root" || return 1
  runner_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  cmux_validate_app_host_runner_root "$system_temp_root" || return 1
  system_temp_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  if [ -z "$now_epoch" ]; then
    now_epoch="$(/bin/date +%s)" || return 1
  fi
  case "$now_epoch:$reclamation_minimum_age_seconds" in
    *[!0-9:]*|:*|*:)
      echo "FAIL: app-host recovery age inputs are invalid" >&2
      return 1
      ;;
  esac

  local requested_scope_count requested_scope_index
  local -a requested_scope_keys
  requested_scope_keys=()
  requested_scope_count=$#
  requested_scope_index=0
  while [ "$requested_scope_index" -lt "$requested_scope_count" ]; do
    requested_scope_keys[requested_scope_index]="$1"
    shift
    requested_scope_index=$((requested_scope_index + 1))
  done

  local verified_pids verified_pid verified_pid_tokens
  local target_count target_index target_pid target_executable
  local newest_mtime find_status prior_count current_uid
  local -a initial_target_pids initial_target_executables
  local -a prior_pids prior_executables prior_receipts prior_keys
  local -a prior_derived_data prior_confirmations prior_confirmation_identities
  local -a prior_confirmation_mtimes maintenance_keys
  verified_pids="$(cmux_app_host_verified_pids \
    "$receipt_dir" "$expected_key" "$derived_data_path")" || return 1
  verified_pid_tokens=""
  for verified_pid in $verified_pids; do
    verified_pid_tokens="${verified_pid_tokens:+$verified_pid_tokens }$verified_pid"
  done
  verified_pids="$verified_pid_tokens"
  cmux_newest_app_host_confirmation_mtime "$system_temp_root" || return 1
  newest_mtime="$CMUX_NEWEST_APP_HOST_CONFIRMATION_MTIME"
  cmux_scan_runner_app_host_targets "$runner_root" || return 1
  target_count="${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}"
  initial_target_pids=()
  initial_target_executables=()
  prior_pids=()
  prior_executables=()
  prior_receipts=()
  prior_keys=()
  prior_derived_data=()
  prior_confirmations=()
  prior_confirmation_identities=()
  prior_confirmation_mtimes=()
  prior_count=0
  target_index=0
  while [ "$target_index" -lt "$target_count" ]; do
    target_pid="${CMUX_APP_HOST_RUNNER_TARGET_PIDS[$target_index]}"
    target_executable="${CMUX_APP_HOST_RUNNER_TARGET_EXECUTABLES[$target_index]}"
    initial_target_pids[target_index]="$target_pid"
    initial_target_executables[target_index]="$target_executable"
    case " $verified_pids " in
      *" $target_pid "*)
        target_index=$((target_index + 1))
        continue
        ;;
    esac

    if cmux_find_eligible_prior_app_host_receipt \
      "$runner_root" "$system_temp_root" "$expected_key" \
      "$target_pid" "$target_executable" "$newest_mtime" \
      "$now_epoch" "$live_recovery_minimum_age_seconds"; then
      find_status=0
    else
      find_status=$?
    fi
    if [ "$find_status" -eq 2 ]; then
      echo "FAIL: runner app-host set changed during prior-owner preflight" >&2
      return 1
    fi
    if [ "$find_status" -ne 0 ]; then
      return 1
    fi
    prior_pids[prior_count]="$target_pid"
    prior_executables[prior_count]="$target_executable"
    prior_receipts[prior_count]="$CMUX_PRIOR_APP_HOST_RECEIPT"
    prior_keys[prior_count]="$CMUX_PRIOR_APP_HOST_KEY"
    prior_derived_data[prior_count]="$CMUX_PRIOR_APP_HOST_DERIVED_DATA"
    prior_confirmations[prior_count]="$CMUX_PRIOR_APP_HOST_CONFIRMATION_FILE"
    prior_confirmation_identities[prior_count]="$CMUX_PRIOR_APP_HOST_CONFIRMATION_IDENTITY"
    prior_confirmation_mtimes[prior_count]="$CMUX_PRIOR_APP_HOST_CONFIRMATION_MTIME"
    prior_count=$((prior_count + 1))
    target_index=$((target_index + 1))
  done

  # Preparation can publish a waiting scope outside the machine lock. Recheck
  # both the complete live target set and the global newest confirmation before
  # signaling current or prior owners.
  cmux_scan_runner_app_host_targets "$runner_root" || return 1
  if [ "${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}" -ne "$target_count" ]; then
    echo "FAIL: runner app-host set changed before recovery" >&2
    return 1
  fi
  target_index=0
  while [ "$target_index" -lt "$target_count" ]; do
    if [ "${CMUX_APP_HOST_RUNNER_TARGET_PIDS[$target_index]}" \
        != "${initial_target_pids[$target_index]}" ] \
      || [ "${CMUX_APP_HOST_RUNNER_TARGET_EXECUTABLES[$target_index]}" \
        != "${initial_target_executables[$target_index]}" ]; then
      echo "FAIL: runner app-host identity changed before recovery" >&2
      return 1
    fi
    target_index=$((target_index + 1))
  done
  cmux_newest_app_host_confirmation_mtime "$system_temp_root" || return 1
  if [ "$CMUX_NEWEST_APP_HOST_CONFIRMATION_MTIME" != "$newest_mtime" ]; then
    echo "FAIL: app-host confirmation set changed before recovery" >&2
    return 1
  fi

  current_uid="$(/usr/bin/id -u)" || {
    echo "FAIL: prior app-host cleanup account is unavailable" >&2
    return 1
  }
  target_index=0
  while [ "$target_index" -lt "$prior_count" ]; do
    cmux_validate_abandoned_app_host_scope \
      "$system_temp_root" "${prior_keys[$target_index]}" "$current_uid" \
      || return 1
    if [ "$CMUX_VALIDATED_ABANDONED_APP_HOST_CONFIRMATION_FILE" \
        != "${prior_confirmations[$target_index]}" ] \
      || [ ! -d "$CMUX_VALIDATED_ABANDONED_APP_HOST_RECEIPT_DIR" ]; then
      echo "FAIL: prior app-host authority changed before recovery" >&2
      return 1
    fi
    cmux_app_host_scope_mtime \
      "${prior_confirmations[$target_index]}" || return 1
    if [ "$CMUX_APP_HOST_SCOPE_MTIME" \
        != "${prior_confirmation_mtimes[$target_index]}" ]; then
      echo "FAIL: prior app-host confirmation changed before recovery" >&2
      return 1
    fi
    cmux_app_host_scope_file_identity \
      "${prior_confirmations[$target_index]}" || return 1
    if [ "$CMUX_APP_HOST_SCOPE_FILE_IDENTITY" \
        != "${prior_confirmation_identities[$target_index]}" ]; then
      echo "FAIL: prior app-host confirmation identity changed before recovery" >&2
      return 1
    fi
    cmux_classify_app_host_scope_recovery_eligibility \
      "${prior_keys[$target_index]}" "$expected_key" 3 \
      "${prior_confirmation_mtimes[$target_index]}" "$newest_mtime" \
      "$now_epoch" "$live_recovery_minimum_age_seconds" || return 1
    if [ "$CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE" -ne 1 ]; then
      echo "FAIL: prior app-host scope became ineligible before recovery" >&2
      return 1
    fi
    if cmux_verify_stale_app_host_receipt \
      "${prior_receipts[$target_index]}" \
      "${prior_keys[$target_index]}" "$runner_root"; then
      find_status=0
    else
      find_status=$?
    fi
    if [ "$find_status" -eq 2 ]; then
      echo "FAIL: prior app-host owner exited before recovery" >&2
      return 1
    fi
    if [ "$find_status" -ne 0 ] \
      || [ "$CMUX_VERIFIED_APP_HOST_PID" != "${prior_pids[$target_index]}" ] \
      || [ "$CMUX_VERIFIED_APP_HOST_EXECUTABLE" \
        != "${prior_executables[$target_index]}" ] \
      || [ "$CMUX_APP_HOST_RECEIPT_DERIVED_DATA" \
        != "${prior_derived_data[$target_index]}" ]; then
      echo "FAIL: prior app-host receipt changed before recovery" >&2
      return 1
    fi
    target_index=$((target_index + 1))
  done

  cmux_terminate_verified_app_hosts \
    "$receipt_dir" "$expected_key" "$derived_data_path" || return 1
  target_index=0
  while [ "$target_index" -lt "$prior_count" ]; do
    cmux_terminate_one_verified_app_host \
      "${prior_receipts[$target_index]}" \
      "${prior_keys[$target_index]}" \
      "${prior_derived_data[$target_index]}" \
      "$runner_root" || return 1
    target_index=$((target_index + 1))
  done

  cmux_scan_runner_app_host_targets "$runner_root" || return 1
  if [ "${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}" -ne 0 ]; then
    echo "FAIL: an app host remained live after authenticated retry recovery" >&2
    return 1
  fi

  maintenance_keys=()
  maintenance_keys[0]="$expected_key"
  target_count=1
  requested_scope_index=0
  while [ "$requested_scope_index" -lt "$requested_scope_count" ]; do
    maintenance_keys[target_count]="${requested_scope_keys[$requested_scope_index]}"
    target_count=$((target_count + 1))
    requested_scope_index=$((requested_scope_index + 1))
  done
  target_index=0
  while [ "$target_index" -lt "$prior_count" ]; do
    maintenance_keys[target_count]="${prior_keys[$target_index]}"
    target_count=$((target_count + 1))
    target_index=$((target_index + 1))
  done

  if [ "$requested_scope_count" -gt 0 ] \
    || [ "${CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER:-0}" = "1" ]; then
    cmux_reclaim_abandoned_app_host_scopes \
      "$runner_root" "$system_temp_root" "$expected_key" \
      "$now_epoch" "$reclamation_minimum_age_seconds" \
      "${maintenance_keys[@]}" || {
      echo "WARNING: abandoned app-host scope reclamation was skipped" >&2
      return 0
    }
  else
    cmux_reclaim_abandoned_app_host_scopes \
      "$runner_root" "$system_temp_root" "$expected_key" \
      "$now_epoch" "$reclamation_minimum_age_seconds" || {
      echo "WARNING: abandoned app-host scope reclamation was skipped" >&2
      return 0
    }
  fi
}

cmux_app_host_scope_metadata() {
  local scope_path="$1"
  local metadata
  if metadata="$(/usr/bin/stat -f '%u %Lp' "$scope_path" 2>/dev/null)"; then
    :
  elif metadata="$(/usr/bin/stat -c '%u %a' "$scope_path" 2>/dev/null)"; then
    :
  else
    echo "FAIL: stale app-host scope metadata is unavailable" >&2
    return 1
  fi
  CMUX_APP_HOST_SCOPE_UID="${metadata%% *}"
  CMUX_APP_HOST_SCOPE_MODE="${metadata#* }"
}
