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

  local line line_number receipt_version receipt_key receipt_pid receipt_executable
  line_number=0
  receipt_version=""
  receipt_key=""
  receipt_pid=""
  receipt_executable=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line_number" in
      1) receipt_version="${line#version=}"; [ "$line" != "$receipt_version" ] || receipt_version="" ;;
      2) receipt_key="${line#key=}"; [ "$line" != "$receipt_key" ] || receipt_key="" ;;
      3) receipt_pid="${line#pid=}"; [ "$line" != "$receipt_pid" ] || receipt_pid="" ;;
      4) receipt_executable="${line#executable=}"; [ "$line" != "$receipt_executable" ] || receipt_executable="" ;;
      *)
        echo "FAIL: app-host process receipt has unexpected fields" >&2
        return 1
        ;;
    esac
  done < "$receipt_file"

  if [ "$line_number" -ne 4 ] || [ "$receipt_version" != "1" ]; then
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

  CMUX_PARSED_APP_HOST_RECEIPT_PID="$receipt_pid"
  CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE="$receipt_executable"
}

# Set CMUX_APP_HOST_PRIMARY_EXECUTABLE. Return 2 when the PID has no text vnode,
# which means the receipt is stale. Return 1 for malformed lsof output.
cmux_app_host_primary_executable() {
  local pid="$1"
  cmux_select_app_host_lsof || return 1

  local output status line reported_pid first_executable
  if output="$("$CMUX_SELECTED_APP_HOST_LSOF" -a -p "$pid" -d txt -Fn 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 1 ]; then
      case "$output" in
        ""|"lsof: status error on $pid: No such process") return 2 ;;
      esac
    fi
    echo "FAIL: lsof could not inspect app-host PID $pid" >&2
    [ -z "$output" ] || echo "$output" >&2
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
  done <<EOF
$output
EOF
  if [ "$reported_pid" != "$pid" ] || [ -z "$first_executable" ]; then
    echo "FAIL: lsof did not return an executable vnode for app-host PID $pid" >&2
    return 1
  fi
  # macOS appends this literal suffix when the process still owns the vnode
  # after its product tree was removed. The receipt records the launch path.
  CMUX_APP_HOST_PRIMARY_EXECUTABLE="${first_executable% (deleted)}"
}

# Return 0 for an exact live identity, 2 for a stale receipt, and 1 for any
# mismatch. Callers must never signal a PID after a 1 or 2 result.
cmux_verify_app_host_receipt() {
  local receipt_file="$1"
  local expected_key="$2"
  local derived_data_path="$3"
  cmux_read_app_host_receipt "$receipt_file" "$expected_key" || return 1

  local receipt_pid receipt_executable primary_status
  receipt_pid="$CMUX_PARSED_APP_HOST_RECEIPT_PID"
  receipt_executable="$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE"
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
  if output="$("$CMUX_SELECTED_APP_HOST_LSOF" -d txt -Fn 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    echo "FAIL: lsof could not enumerate app-host executable vnodes" >&2
    [ -z "$output" ] || echo "$output" >&2
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
  done <<EOF
$output
EOF
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

  local receipt_pid receipt_executable primary_status
  receipt_pid="$CMUX_PARSED_APP_HOST_RECEIPT_PID"
  receipt_executable="$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE"
  if ! cmux_app_host_derived_data_from_executable \
    "$runner_root" "$receipt_executable"; then
    echo "FAIL: stale app-host receipt executable is outside the runner work root" >&2
    return 1
  fi
  local receipt_derived_data="$CMUX_APP_HOST_RECEIPT_DERIVED_DATA"

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

  CMUX_VERIFIED_APP_HOST_PID="$receipt_pid"
  CMUX_VERIFIED_APP_HOST_EXECUTABLE="$receipt_executable"
  CMUX_VERIFIED_APP_HOST_DERIVED_DATA="$receipt_derived_data"
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
  if output="$("$CMUX_SELECTED_APP_HOST_LSOF" -d txt -Fn 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    echo "FAIL: lsof could not enumerate runner app-host executable vnodes" >&2
    [ -z "$output" ] || echo "$output" >&2
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
  done <<EOF
$output
EOF
  if [ -n "$current_pid" ] && [ -n "$first_executable" ]; then
    cmux_record_runner_app_host_target \
      "$runner_root" \
      "$current_pid" "$first_executable"
  fi
}

cmux_find_verified_stale_app_host_receipt() {
  local runner_root="$1"
  local receipt_root="$2"
  local target_pid="$3"
  local target_executable="$4"
  local receipt_file receipt_dir receipt_dir_name expected_key verify_status
  local matching_receipts=0
  local matched_receipt=""
  local matched_key=""
  local matched_derived_data=""

  for receipt_file in \
    "$receipt_root"/cmux-ah-*-receipts/"app-host-$target_pid.receipt"; do
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
    if ! cmux_app_host_derived_data_from_executable \
      "$runner_root" "$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE"; then
      echo "FAIL: stale app-host receipt executable is outside the runner work root" >&2
      return 1
    fi
    if [ "$CMUX_PARSED_APP_HOST_RECEIPT_EXECUTABLE" != "$target_executable" ]; then
      continue
    fi

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
    matching_receipts=$((matching_receipts + 1))
    matched_receipt="$receipt_file"
    matched_key="$expected_key"
    matched_derived_data="$CMUX_VERIFIED_APP_HOST_DERIVED_DATA"
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
    echo "FAIL: live app-host target PID $target_pid at $target_executable has no verified receipt beneath $receipt_root" >&2
    return 1
  fi
  if [ "$matching_receipts" -ne 1 ]; then
    echo "FAIL: live app-host target PID $target_pid has ambiguous verified receipts" >&2
    return 1
  fi

  CMUX_STALE_APP_HOST_RECEIPT="$matched_receipt"
  CMUX_STALE_APP_HOST_KEY="$matched_key"
  CMUX_STALE_APP_HOST_DERIVED_DATA="$matched_derived_data"
}

# Before a new test attempt, first authenticate every live runner-scoped app
# host. Only after the complete set has matching receipts may any PID be
# signaled. Deleted products remain verifiable through their retained vnodes.
cmux_terminate_stale_receipted_app_hosts() {
  local runner_root="$1"
  local receipt_root="$2"
  cmux_validate_app_host_runner_root "$runner_root" || return 1
  local resolved_runner_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"
  cmux_validate_app_host_runner_root "$receipt_root" || return 1
  local resolved_receipt_root="$CMUX_VALIDATED_APP_HOST_RUNNER_ROOT"

  cmux_scan_runner_app_host_targets "$resolved_runner_root" || return 1
  local target_count="${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}"
  local -a verified_receipts verified_keys verified_derived_data
  verified_receipts=()
  verified_keys=()
  verified_derived_data=()

  local target_index target_pid target_executable find_status verified_count
  verified_count=0
  target_index=0
  while [ "$target_index" -lt "$target_count" ]; do
    target_pid="${CMUX_APP_HOST_RUNNER_TARGET_PIDS[$target_index]}"
    target_executable="${CMUX_APP_HOST_RUNNER_TARGET_EXECUTABLES[$target_index]}"
    if cmux_find_verified_stale_app_host_receipt \
      "$resolved_runner_root" "$resolved_receipt_root" \
      "$target_pid" "$target_executable"; then
      find_status=0
    else
      find_status=$?
    fi
    if [ "$find_status" -eq 2 ]; then
      target_index=$((target_index + 1))
      continue
    fi
    if [ "$find_status" -ne 0 ]; then
      return 1
    fi
    verified_receipts[verified_count]="$CMUX_STALE_APP_HOST_RECEIPT"
    verified_keys[verified_count]="$CMUX_STALE_APP_HOST_KEY"
    verified_derived_data[verified_count]="$CMUX_STALE_APP_HOST_DERIVED_DATA"
    verified_count=$((verified_count + 1))
    target_index=$((target_index + 1))
  done

  # Signaling begins only after every target above has been authenticated.
  target_index=0
  while [ "$target_index" -lt "$verified_count" ]; do
    cmux_terminate_one_verified_app_host \
      "${verified_receipts[$target_index]}" \
      "${verified_keys[$target_index]}" \
      "${verified_derived_data[$target_index]}" \
      "$resolved_runner_root" || return 1
    target_index=$((target_index + 1))
  done

  cmux_scan_runner_app_host_targets "$resolved_runner_root" || return 1
  target_count="${#CMUX_APP_HOST_RUNNER_TARGET_PIDS[@]}"
  if [ "$target_count" -ne 0 ]; then
    target_pid="${CMUX_APP_HOST_RUNNER_TARGET_PIDS[0]}"
    target_executable="${CMUX_APP_HOST_RUNNER_TARGET_EXECUTABLES[0]}"
    if ! cmux_find_verified_stale_app_host_receipt \
      "$resolved_runner_root" "$resolved_receipt_root" \
      "$target_pid" "$target_executable"; then
      return 1
    fi
    echo "FAIL: verified app-host target PID $target_pid remained live after stale cleanup" >&2
    return 1
  fi
}
