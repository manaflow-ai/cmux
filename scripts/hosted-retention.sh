#!/usr/bin/env bash

# Shared by verify-cmux-tui-hosted.sh and the behavior-level retention tests.
# The function runs in a subshell so its EXIT trap cannot change the caller's
# cleanup policy.

cmux_hosted_retention_cleanup_scratch_dir=""
cmux_hosted_retention_cleanup_quarantine_root=""
cmux_hosted_retention_cleanup_lock_dir=""
cmux_hosted_retention_cleanup_lock_marker=""
cmux_hosted_retention_cleanup_lock_token=""
cmux_hosted_retention_cleanup_lock_acquired=0

cmux_hosted_retention_error() {
  echo "error: hosted artifact retention: $*" >&2
  return 2
}

cmux_hosted_retention_command_available() {
  local command_name="$1"
  if [[ "$command_name" == */* ]]; then
    [[ -x "$command_name" ]]
  else
    command -v "$command_name" >/dev/null 2>&1
  fi
}

cmux_hosted_retention_bounded_integer() {
  local value="$1"
  local maximum="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  # The length check keeps the arithmetic comparison below within the shell's
  # integer range. Both values are at most five digits in this function.
  if (( ${#value} > ${#maximum} )); then
    return 1
  fi
  if (( ${#value} == ${#maximum} )) && (( value > maximum )); then
    return 1
  fi
}

cmux_hosted_retention_mtime() {
  local candidate_path="$1"
  local stat_command="${CMUX_TUI_HOSTED_RETENTION_STAT:-stat}"
  local output

  if ! cmux_hosted_retention_command_available "$stat_command"; then
    return 1
  fi

  # GNU stat uses -c for file fields. BSD/macOS stat uses -f. Probe the GNU
  # form first because GNU -f means filesystem status and can succeed while
  # returning a mount point instead of a file timestamp.
  if output="$("$stat_command" -c '%Y' "$candidate_path" 2>/dev/null)"; then
    [[ "$output" =~ ^-?[0-9]+$ ]] || return 1
    printf '%s\n' "$output"
    return 0
  fi
  if output="$("$stat_command" -f '%m' "$candidate_path" 2>/dev/null)"; then
    [[ "$output" =~ ^-?[0-9]+$ ]] || return 1
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

cmux_hosted_retention_hash_file() {
  local input_file="$1"
  local digest

  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$input_file" | awk 'NR == 1 { print $1 }')" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$input_file" | awk 'NR == 1 { print $1 }')" || return 1
  else
    return 1
  fi

  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

cmux_hosted_retention_lsof_state() {
  local lsof_command="$1"
  local target_path="$2"
  local output_file="$3"
  local error_file="$4"
  local lsof_status
  local lsof_record
  local lsof_name
  local saw_name=0

  if "$lsof_command" -F n -- "$target_path" > "$output_file" 2> "$error_file"; then
    lsof_status=0
  else
    lsof_status=$?
  fi
  if [[ -s "$error_file" || "$lsof_status" -gt 1 ]]; then
    return 2
  fi

  while IFS= read -r lsof_record; do
    case "$lsof_record" in
      n*)
        saw_name=1
        lsof_name="${lsof_record#n}"
        [[ "$lsof_name" == "$target_path" ]] || return 2
        ;;
      p*|f*)
        # lsof always emits the PID field, and versions 4.88 through 4.93.2
        # also emit a file-descriptor field even when only names are asked.
        ;;
      *)
        return 2
        ;;
    esac
  done < "$output_file"

  if [[ -s "$output_file" && "$saw_name" -eq 0 ]]; then
    return 2
  fi
  if (( lsof_status == 0 )) && [[ ! -s "$output_file" ]]; then
    return 2
  fi
  if [[ "$saw_name" -eq 1 ]]; then
    return 0
  fi
  return 1
}

cmux_hosted_retention_run() (
  if [[ $# -ne 2 ]]; then
    cmux_hosted_retention_error "expected current artifact directory and current commit"
    exit $?
  fi

  local current_artifact_dir="$1"
  local artifact_root
  local current_commit="$2"
  local retention_count="${CMUX_TUI_HOSTED_RETENTION_COUNT:-}"
  local retention_dry_run="${CMUX_TUI_HOSTED_RETENTION_DRY_RUN:-0}"
  local retention_confirmed="${CMUX_TUI_HOSTED_RETENTION_CONFIRM:-0}"
  local max_candidates_limit=10000
  local max_candidates="${CMUX_TUI_HOSTED_RETENTION_MAX_CANDIDATES:-$max_candidates_limit}"
  local uid
  local scratch_dir
  local preview_file
  local preview_tmp
  local candidate_paths_file
  local candidate_order_file
  local plan_file
  local preview_hash
  local preview_timestamp
  local preview_line_count
  local preview_line
  local now
  local candidate_dir
  local candidate_commit
  local candidate_mtime
  local candidate_count=0
  local candidate_action
  local retained=0
  local lsof_command="${CMUX_TUI_HOSTED_RETENTION_LSOF:-lsof}"
  local lsof_status
  local lsof_record
  local active_path
  local active_commit
  local lsof_target_count=0
  local lsof_output_file
  local lsof_error_file
  local active_commits_file
  local cleanup_commits_file
  local decision_file
  local candidate_index
  local decision
  local decision_commit
  local old_umask
  local candidate_binary
  local lock_dir=""
  local lock_marker=""
  local lock_token=""
  local quarantine_root=""
  local quarantine_dir=""
  local quarantine_binary=""
  local recheck_output_file
  local recheck_error_file
  local recheck_status

  # Retention is opt-in. Keep the existing verification path unchanged when
  # no retention count is supplied.
  if [[ -z "$retention_count" ]]; then
    echo "Hosted artifact retention disabled (set a positive retention count to enable)" >&2
    exit 0
  fi
  if ! cmux_hosted_retention_bounded_integer "$max_candidates" "$max_candidates_limit"; then
    cmux_hosted_retention_error "candidate scan limit must be a positive integer no greater than $max_candidates_limit"
    exit $?
  fi
  if ! cmux_hosted_retention_bounded_integer "$retention_count" "$max_candidates"; then
    cmux_hosted_retention_error "retention count must be a positive integer no greater than $max_candidates"
    exit $?
  fi
  case "$retention_dry_run" in
    0|1) ;;
    *)
      cmux_hosted_retention_error "dry-run mode must be 0 or 1"
      exit $?
      ;;
  esac
  if [[ "$retention_dry_run" == 0 && "$retention_confirmed" != 1 ]]; then
    cmux_hosted_retention_error "destructive cleanup requires a confirmation after a dry-run preview"
    exit $?
  fi
  if [[ ! "$current_commit" =~ ^[0-9a-f]{40}$ ]]; then
    cmux_hosted_retention_error "current commit is not a lowercase 40-character SHA"
    exit $?
  fi
  if [[ ! -d "$current_artifact_dir" || -L "$current_artifact_dir" ]]; then
    cmux_hosted_retention_error "current artifact directory is missing or is a symbolic link"
    exit $?
  fi
  if ! current_artifact_dir="$(cd "$current_artifact_dir" && pwd -P)"; then
    cmux_hosted_retention_error "cannot resolve current artifact directory"
    exit $?
  fi
  if [[ "${current_artifact_dir##*/}" != "$current_commit" || ! -O "$current_artifact_dir" ]]; then
    cmux_hosted_retention_error "current artifact directory does not match the current commit"
    exit $?
  fi
  if ! artifact_root="$(cd "$current_artifact_dir/.." && pwd -P)"; then
    cmux_hosted_retention_error "cannot resolve artifact root"
    exit $?
  fi
  if [[ ! -d "$artifact_root" || ! -O "$artifact_root" ]]; then
    cmux_hosted_retention_error "artifact root is not owned by the current user"
    exit $?
  fi
  if ! uid="$(id -u)"; then
    cmux_hosted_retention_error "cannot resolve the current user"
    exit $?
  fi

  old_umask="$(umask)"
  umask 077
  if ! scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-hosted-retention.XXXXXX")"; then
    umask "$old_umask"
    cmux_hosted_retention_error "cannot create retention scratch space"
    exit $?
  fi
  umask "$old_umask"
  cmux_hosted_retention_cleanup_scratch_dir="$scratch_dir"
  cmux_hosted_retention_cleanup_quarantine_root=""
  cmux_hosted_retention_cleanup_lock_dir=""
  cmux_hosted_retention_cleanup_lock_marker=""
  cmux_hosted_retention_cleanup_lock_token=""
  cmux_hosted_retention_cleanup_lock_acquired=0
  # shellcheck disable=SC2329 # invoked by the EXIT trap below
  cmux_hosted_retention_cleanup() {
    if [[ -n "$cmux_hosted_retention_cleanup_quarantine_root" && -d "$cmux_hosted_retention_cleanup_quarantine_root" && ! -L "$cmux_hosted_retention_cleanup_quarantine_root" ]]; then
      rmdir -- "$cmux_hosted_retention_cleanup_quarantine_root" >/dev/null 2>&1 || true
    fi
    if [[ "$cmux_hosted_retention_cleanup_lock_acquired" -eq 1 && -n "$cmux_hosted_retention_cleanup_lock_dir" && -d "$cmux_hosted_retention_cleanup_lock_dir" && ! -L "$cmux_hosted_retention_cleanup_lock_dir" && -f "$cmux_hosted_retention_cleanup_lock_marker" && ! -L "$cmux_hosted_retention_cleanup_lock_marker" && -O "$cmux_hosted_retention_cleanup_lock_marker" ]]; then
      if [[ "$(<"$cmux_hosted_retention_cleanup_lock_marker")" == "$cmux_hosted_retention_cleanup_lock_token" ]]; then
        rm -f -- "$cmux_hosted_retention_cleanup_lock_marker" >/dev/null 2>&1 || true
        rmdir -- "$cmux_hosted_retention_cleanup_lock_dir" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -n "$cmux_hosted_retention_cleanup_scratch_dir" ]]; then
      rm -rf -- "$cmux_hosted_retention_cleanup_scratch_dir"
    fi
  }
  trap cmux_hosted_retention_cleanup EXIT

  preview_file="$artifact_root/.retention-preview"
  candidate_paths_file="$scratch_dir/candidate-paths"
  candidate_order_file="$scratch_dir/candidate-order"
  plan_file="$scratch_dir/plan"

  if ! find "$artifact_root" \
    -mindepth 1 -maxdepth 1 -type d -user "$uid" -print0 > "$candidate_paths_file"; then
    cmux_hosted_retention_error "cannot enumerate artifact directories"
    exit $?
  fi

  hosted_artifact_order=()
  while IFS= read -r -d '' candidate_dir; do
    candidate_commit="${candidate_dir##*/}"
    [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || continue
    candidate_count=$((candidate_count + 1))
    if (( candidate_count > max_candidates )); then
      cmux_hosted_retention_error "candidate scan exceeded the bounded limit of $max_candidates"
      exit $?
    fi
    candidate_mtime="$(cmux_hosted_retention_mtime "$artifact_root/$candidate_commit")" || {
      cmux_hosted_retention_error "cannot read an artifact modification time"
      exit $?
    }
    hosted_artifact_order+=("$candidate_mtime"$'\t'"$candidate_commit")
  done < "$candidate_paths_file"

  hosted_artifact_commits=()
  if ((${#hosted_artifact_order[@]} > 0)); then
    if ! printf '%s\n' "${hosted_artifact_order[@]}" \
      | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r > "$candidate_order_file"; then
      cmux_hosted_retention_error "cannot order artifact directories"
      exit $?
    fi
    while IFS=$'\t' read -r candidate_mtime candidate_commit; do
      [[ "$candidate_mtime" =~ ^-?[0-9]+$ ]] || {
        cmux_hosted_retention_error "artifact ordering returned an invalid timestamp"
        exit $?
      }
      [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || {
        cmux_hosted_retention_error "artifact ordering returned an invalid commit"
        exit $?
      }
      hosted_artifact_commits+=("$candidate_commit")
    done < "$candidate_order_file"
  fi

  hosted_artifact_actions=()
  for candidate_commit in "${hosted_artifact_commits[@]}"; do
    if [[ "$candidate_commit" == "$current_commit" ]]; then
      candidate_action="keep-current"
    elif (( retained < retention_count )); then
      retained=$((retained + 1))
      candidate_action="keep-recent"
    else
      candidate_action="delete"
    fi
    hosted_artifact_actions+=("$candidate_action")
  done

  {
    printf 'cmux-hosted-retention-plan-v1\n'
    printf 'current-commit\t%s\n' "$current_commit"
    printf 'retention-count\t%s\n' "$retention_count"
    printf 'candidate-limit\t%s\n' "$max_candidates"
    for candidate_index in "${!hosted_artifact_commits[@]}"; do
      printf 'candidate\t%s\t%s\n' \
        "${hosted_artifact_commits[$candidate_index]}" \
        "${hosted_artifact_actions[$candidate_index]}"
    done
  } > "$plan_file" || {
    cmux_hosted_retention_error "cannot build the retention plan"
    exit $?
  }
  preview_hash="$(cmux_hosted_retention_hash_file "$plan_file")" || {
    cmux_hosted_retention_error "cannot hash the retention plan"
    exit $?
  }

  if [[ "$retention_dry_run" == 1 ]]; then
    now="$(date +%s)" || {
      cmux_hosted_retention_error "cannot create a preview timestamp"
      exit $?
    }
    [[ "$now" =~ ^[0-9]+$ ]] || {
      cmux_hosted_retention_error "preview timestamp is invalid"
      exit $?
    }
    if [[ -L "$preview_file" ]]; then
      cmux_hosted_retention_error "preview path is a symbolic link"
      exit $?
    fi
    if [[ -e "$preview_file" && ! -O "$preview_file" ]]; then
      cmux_hosted_retention_error "preview path is not owned by the current user"
      exit $?
    fi
    preview_tmp="$scratch_dir/preview"
    if ! (umask 077 && printf '%s\t%s\n' "$preview_hash" "$now" > "$preview_tmp"); then
      cmux_hosted_retention_error "cannot write the retention preview"
      exit $?
    fi
    if ! mv -f -- "$preview_tmp" "$preview_file"; then
      cmux_hosted_retention_error "cannot publish the retention preview"
      exit $?
    fi
  else
    if [[ ! -f "$preview_file" || -L "$preview_file" || ! -O "$preview_file" ]]; then
      cmux_hosted_retention_error "a fresh retention preview is required"
      exit $?
    fi
    preview_line_count="$(wc -l < "$preview_file" | tr -d '[:space:]')" || {
      cmux_hosted_retention_error "cannot read the retention preview"
      exit $?
    }
    if [[ "$preview_line_count" != 1 ]]; then
      cmux_hosted_retention_error "retention preview format is invalid"
      exit $?
    fi
    preview_line="$(<"$preview_file")" || {
      cmux_hosted_retention_error "cannot read the retention preview"
      exit $?
    }
    if [[ "$preview_line" != "$preview_hash"$'\t'* ]]; then
      cmux_hosted_retention_error "retention preview does not match the current deletion plan"
      exit $?
    fi
    preview_timestamp="${preview_line#*$'\t'}"
    if [[ -z "$preview_timestamp" || "$preview_timestamp" == *$'\t'* || ! "$preview_timestamp" =~ ^[0-9]+$ ]]; then
      cmux_hosted_retention_error "retention preview timestamp is invalid"
      exit $?
    fi
    now="$(date +%s)" || {
      cmux_hosted_retention_error "cannot read the current time"
      exit $?
    }
    if [[ ! "$now" =~ ^[0-9]+$ ]] || ! awk -v now="$now" -v timestamp="$preview_timestamp" \
      'BEGIN { exit !(timestamp <= now && now - timestamp <= 600) }'; then
      cmux_hosted_retention_error "retention preview is expired or from the future"
      exit $?
    fi
  fi

  cleanup_commits=()
  for candidate_index in "${!hosted_artifact_commits[@]}"; do
    if [[ "${hosted_artifact_actions[$candidate_index]}" == delete ]]; then
      cleanup_commits+=("${hosted_artifact_commits[$candidate_index]}")
    fi
  done

  if ((${#cleanup_commits[@]} == 0)); then
    exit 0
  fi
  if [[ "$retention_dry_run" == 1 ]]; then
    for candidate_commit in "${cleanup_commits[@]}"; do
      echo "Would remove hosted artifact: $artifact_root/$candidate_commit" >&2
    done
    exit 0
  fi

  if ! cmux_hosted_retention_command_available "$lsof_command"; then
    cmux_hosted_retention_error "cannot prove artifacts are inactive because lsof is unavailable"
    exit $?
  fi

  lock_dir="$artifact_root/.retention.lock"
  lock_marker="$lock_dir/owner"
  lock_token="$(printf '%s:%s' "$$" "$scratch_dir")"
  cmux_hosted_retention_cleanup_lock_dir="$lock_dir"
  cmux_hosted_retention_cleanup_lock_marker="$lock_marker"
  cmux_hosted_retention_cleanup_lock_token="$lock_token"
  if [[ -e "$lock_dir" || -L "$lock_dir" ]] || ! (umask 077 && mkdir "$lock_dir"); then
    cmux_hosted_retention_error "another retention cleanup is already running"
    exit $?
  fi
  if ! (umask 077 && printf '%s\n' "$lock_token" > "$lock_marker"); then
    rmdir -- "$lock_dir" >/dev/null 2>&1 || true
    cmux_hosted_retention_error "cannot initialize the retention cleanup lock"
    exit $?
  fi
  cmux_hosted_retention_cleanup_lock_acquired=1

  if ! quarantine_root="$(umask 077 && mktemp -d "$artifact_root/.retention-quarantine.XXXXXX")"; then
    cmux_hosted_retention_error "cannot create the retention quarantine"
    exit $?
  fi
  if [[ ! -d "$quarantine_root" || -L "$quarantine_root" || ! -O "$quarantine_root" ]]; then
    cmux_hosted_retention_error "retention quarantine is not owned by the current user"
    exit $?
  fi
  cmux_hosted_retention_cleanup_quarantine_root="$quarantine_root"

  lsof_targets=()
  for candidate_commit in "${cleanup_commits[@]}"; do
    candidate_binary="$artifact_root/$candidate_commit/cmux-tui"
    if [[ ! -f "$candidate_binary" || -L "$candidate_binary" ]]; then
      cmux_hosted_retention_error "artifact binary changed before activity check"
      exit $?
    fi
    lsof_targets+=("$candidate_binary")
    lsof_target_count=$((lsof_target_count + 1))
  done

  active_commits_file="$scratch_dir/active-commits"
  : > "$active_commits_file"
  if (( lsof_target_count > 0 )); then
    lsof_output_file="$scratch_dir/lsof-output"
    lsof_error_file="$scratch_dir/lsof-error"
    if "$lsof_command" -F n -- "${lsof_targets[@]}" > "$lsof_output_file" 2> "$lsof_error_file"; then
      lsof_status=0
    else
      lsof_status=$?
    fi
    if [[ -s "$lsof_error_file" || "$lsof_status" -gt 1 ]]; then
      cmux_hosted_retention_error "lsof could not establish artifact activity"
      exit $?
    fi
    while IFS= read -r lsof_record; do
      case "$lsof_record" in
        n*)
          active_path="${lsof_record#n}"
          if [[ "$active_path" != "$artifact_root"/*/cmux-tui ]]; then
            continue
          fi
          active_commit="${active_path%/cmux-tui}"
          active_commit="${active_commit##*/}"
          [[ "$active_commit" =~ ^[0-9a-f]{40}$ ]] || {
            cmux_hosted_retention_error "lsof returned an unexpected artifact path"
            exit $?
          }
          printf '%s\n' "$active_commit" >> "$active_commits_file"
          ;;
        p*|f*)
          # lsof always emits the PID field, and versions 4.88 through 4.93.2
          # also emit a file-descriptor field even when only names are asked.
          ;;
        *)
          cmux_hosted_retention_error "lsof returned an invalid activity record"
          exit $?
          ;;
      esac
    done < "$lsof_output_file"
    if [[ -s "$lsof_output_file" && ! -s "$active_commits_file" ]]; then
      cmux_hosted_retention_error "lsof returned no usable artifact names"
      exit $?
    fi
    if (( lsof_status == 0 )) && [[ ! -s "$lsof_output_file" ]]; then
      cmux_hosted_retention_error "lsof returned no activity records"
      exit $?
    fi
  fi
  LC_ALL=C sort -u "$active_commits_file" -o "$active_commits_file" || {
    cmux_hosted_retention_error "cannot normalize lsof activity records"
    exit $?
  }

  cleanup_commits_file="$scratch_dir/cleanup-commits"
  decision_file="$scratch_dir/decisions"
  printf '%s\n' "${cleanup_commits[@]}" > "$cleanup_commits_file"
  if ! awk '
    FILENAME == ARGV[1] { active[$0] = 1; next }
    { print (($0 in active) ? "active" : "inactive") "\t" $0 }
  ' "$active_commits_file" "$cleanup_commits_file" > "$decision_file"; then
    cmux_hosted_retention_error "cannot build the activity decision"
    exit $?
  fi

  recheck_output_file="$scratch_dir/recheck-output"
  recheck_error_file="$scratch_dir/recheck-error"
  while IFS=$'\t' read -r decision decision_commit; do
    case "$decision" in
      active)
        echo "Keeping active hosted artifact: $artifact_root/$decision_commit/cmux-tui" >&2
        ;;
      inactive)
        candidate_dir="$artifact_root/$decision_commit"
        candidate_binary="$candidate_dir/cmux-tui"
        if [[ ! -d "$candidate_dir" || -L "$candidate_dir" || ! -O "$candidate_dir" || ! -f "$candidate_binary" || -L "$candidate_binary" || ! -O "$candidate_binary" ]]; then
          cmux_hosted_retention_error "artifact changed before entering quarantine"
          exit $?
        fi
        quarantine_dir="$quarantine_root/$decision_commit"
        if [[ -e "$quarantine_dir" || -L "$quarantine_dir" ]]; then
          cmux_hosted_retention_error "retention quarantine path already exists"
          exit $?
        fi
        if ! mv -- "$candidate_dir" "$quarantine_dir"; then
          cmux_hosted_retention_error "cannot quarantine an inactive artifact"
          exit $?
        fi
        quarantine_binary="$quarantine_dir/cmux-tui"
        if [[ ! -d "$quarantine_dir" || -L "$quarantine_dir" || ! -O "$quarantine_dir" || ! -f "$quarantine_binary" || -L "$quarantine_binary" || ! -O "$quarantine_binary" ]]; then
          if [[ ! -e "$candidate_dir" && ! -L "$candidate_dir" && -d "$quarantine_dir" && ! -L "$quarantine_dir" ]]; then
            mv -- "$quarantine_dir" "$candidate_dir" >/dev/null 2>&1 || true
          fi
          cmux_hosted_retention_error "artifact changed after entering quarantine"
          exit $?
        fi

        if cmux_hosted_retention_lsof_state \
          "$lsof_command" "$quarantine_binary" "$recheck_output_file" "$recheck_error_file"; then
          recheck_status=0
        else
          recheck_status=$?
        fi
        case "$recheck_status" in
          0)
            if [[ -e "$candidate_dir" || -L "$candidate_dir" ]]; then
              cmux_hosted_retention_error "artifact path was recreated while checking activity"
              exit $?
            fi
            if ! mv -- "$quarantine_dir" "$candidate_dir"; then
              cmux_hosted_retention_error "cannot restore an active artifact"
              exit $?
            fi
            echo "Keeping active hosted artifact: $candidate_dir/cmux-tui" >&2
            ;;
          1)
            if [[ -e "$candidate_dir" || -L "$candidate_dir" ]]; then
              cmux_hosted_retention_error "artifact path was recreated while checking activity"
              exit $?
            fi
            if [[ ! -d "$quarantine_dir" || -L "$quarantine_dir" || ! -O "$quarantine_dir" || ! -f "$quarantine_binary" || -L "$quarantine_binary" || ! -O "$quarantine_binary" ]]; then
              cmux_hosted_retention_error "artifact changed after activity check"
              exit $?
            fi
            if ! rm -rf -- "$quarantine_dir"; then
              cmux_hosted_retention_error "cannot remove an inactive artifact"
              exit $?
            fi
            echo "Removed hosted artifact: $candidate_dir" >&2
            ;;
          *)
            if [[ ! -e "$candidate_dir" && ! -L "$candidate_dir" && -d "$quarantine_dir" && ! -L "$quarantine_dir" && -O "$quarantine_dir" ]]; then
              mv -- "$quarantine_dir" "$candidate_dir" >/dev/null 2>&1 || true
            fi
            cmux_hosted_retention_error "lsof could not establish quarantined artifact activity"
            exit $?
            ;;
        esac
        ;;
      *)
        cmux_hosted_retention_error "activity decision is invalid"
        exit $?
        ;;
    esac
  done < "$decision_file"
  exit 0
)
