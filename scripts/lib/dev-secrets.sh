# shellcheck shell=bash
# Sourceable helper that loads dogfood/agent Stack credentials for DEBUG dev
# builds and exposes them as CMUX_UITEST_STACK_EMAIL / CMUX_UITEST_STACK_PASSWORD
# (the env vars the app's existing DEBUG sign-in hook reads).
#
# A complete email+password pair is resolved from ONE source, never mixed
# across sources. Explicit profiles prevent a personal device build from
# silently borrowing the shared agent identity. The automatic profile retains
# the legacy dogfood-first chain for compatibility:
#   1. file ~/.secrets/cmuxterm-dev.env  dogfood keys (CMUX_DOGFOOD_STACK_*)
#   2. file ~/.secrets/cmux.env          dogfood keys (CMUX_DOGFOOD_STACK_*)
#   3. env  CMUX_DOGFOOD_STACK_EMAIL / CMUX_DOGFOOD_STACK_PASSWORD
#   4. file ~/.secrets/cmuxterm-dev.env  uitest  keys (CMUX_UITEST_STACK_*)
#   5. file ~/.secrets/cmux.env          uitest  keys (CMUX_UITEST_STACK_*)
#   6. env  CMUX_UITEST_STACK_EMAIL / CMUX_UITEST_STACK_PASSWORD
#
# The dogfood account (a personal dogfood login) is preferred so dev builds sign
# in as the human, not the shared agent.
#
# Usage:
#   source "scripts/lib/dev-secrets.sh"
#   cmux_dev_secrets_load                         # legacy automatic profile
#   cmux_dev_secrets_load --profile personal      # dogfood keys only
#   cmux_dev_secrets_load --profile agent         # UI-test keys only
#   cmux_dev_secrets_load --agent                 # compatibility alias
#
# After a successful load, CMUX_UITEST_STACK_EMAIL / CMUX_UITEST_STACK_PASSWORD
# are exported. The email is echoed (so the operator can see who they signed in
# as); the password is NEVER printed.
#
# Returns non-zero (and prints guidance) when no usable credentials are found.

# Validate an explicitly selected credentials file before any caller bakes its
# path into a tagged app or reads it. The file must be an absolute, regular,
# non-symlink file owned by the current uid with no group/world permissions.
cmux_dev_secrets_validate_file() {
  local file="${1:-}" owner permissions
  [[ "$file" == /* ]] || {
    echo "error: credentials file path must be absolute" >&2
    return 2
  }
  [[ -f "$file" && ! -L "$file" ]] || {
    echo "error: credentials file must be a regular non-symlink file" >&2
    return 2
  }
  owner="$(stat -f '%u' "$file" 2>/dev/null || true)"
  permissions="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
  [[ "$owner" == "$(id -u)" ]] || {
    echo "error: credentials file must be owned by the current user" >&2
    return 2
  }
  [[ "$permissions" =~ ^[0-7]{3,4}$ ]] || {
    echo "error: could not validate credentials file permissions" >&2
    return 2
  }
  if (( (8#$permissions & 8#077) != 0 )); then
    echo "error: credentials file must not grant group or world permissions (use chmod 600)" >&2
    return 2
  fi
}

# Read a single KEY=value out of a .env file without sourcing it (so we never
# execute arbitrary secret-file contents). Mirrors DebugDogfoodCredentialResolver.
# parseEnvFile: trims the line, skips blank/`#`-comment lines, trims the key and
# value around the first `=`, and strips ONE layer of matching surrounding single
# or double quotes. Prints the parsed value, or nothing.
cmux_dev_secrets__read_key() {
  local file="$1" key="$2" line lkey lval
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading/trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == '#'* || "$line" != *'='* ]] && continue
    lkey="${line%%=*}"
    lval="${line#*=}"
    # Trim key and value.
    lkey="${lkey#"${lkey%%[![:space:]]*}"}"; lkey="${lkey%"${lkey##*[![:space:]]}"}"
    lval="${lval#"${lval%%[![:space:]]*}"}"; lval="${lval%"${lval##*[![:space:]]}"}"
    [[ "$lkey" == "$key" ]] || continue
    # Strip one layer of matching surrounding quotes (len >= 2).
    if [[ ${#lval} -ge 2 ]]; then
      if [[ "$lval" == '"'*'"' || "$lval" == "'"*"'" ]]; then
        lval="${lval:1:${#lval}-2}"
      fi
    fi
    printf '%s' "$lval"
    return 0
  done < "$file"
  return 0
}

# Load dev sign-in credentials into CMUX_UITEST_STACK_EMAIL / _PASSWORD.
#
#   cmux_dev_secrets_load [--profile personal|agent|automatic]
#                         [--expected-account email]
#                         [--credentials-file /absolute/0600/file]
#
# Without --agent, the full 6-step chain above runs (dogfood account preferred).
# With --agent, only the agent (uitest) sources are used (env CMUX_UITEST_STACK_*,
# then ~/.secrets/cmux.env uitest keys), for agent-driven flows that must not
# borrow a human's dogfood login.
# Try to resolve a COMPLETE (email + password) credential pair from one source,
# so a partial higher-precedence source never combines with a lower one. Sets
# the caller's `email`/`password` and returns 0 on a full pair, else 1.
#
#   cmux_dev_secrets__try_pair email_var pw_var <getter...>
#
# The getter is invoked as `<getter> EMAIL` and `<getter> PASSWORD`; it must echo
# the value (or nothing). Both must be non-empty for the pair to be accepted.
cmux_dev_secrets__try_pair() {
  local email_var="$1" pw_var="$2"; shift 2
  local e p
  e="$("$@" EMAIL)"
  p="$("$@" PASSWORD)"
  if [[ -n "$e" && -n "$p" ]]; then
    printf -v "$email_var" '%s' "$e"
    printf -v "$pw_var" '%s' "$p"
    return 0
  fi
  return 1
}

cmux_dev_secrets_load() {
  local profile="automatic" explicit_file="" expected_account=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) profile="agent"; shift ;;
      --profile)
        profile="${2:-}"
        [[ -n "$profile" ]] || { echo "error: --profile requires a value" >&2; return 2; }
        shift 2
        ;;
      --expected-account)
        expected_account="${2:-}"
        [[ -n "$expected_account" ]] || { echo "error: --expected-account requires an email" >&2; return 2; }
        shift 2
        ;;
      --credentials-file)
        explicit_file="${2:-}"
        [[ -n "$explicit_file" ]] || { echo "error: --credentials-file requires a path" >&2; return 2; }
        shift 2
        ;;
      *) echo "error: unknown credential-loader option '$1'" >&2; return 2 ;;
    esac
  done

  case "$profile" in
    personal|agent|automatic) ;;
    *) echo "error: invalid auth profile '$profile' (expected personal, agent, or automatic)" >&2; return 2 ;;
  esac
  [[ -z "$explicit_file" ]] || cmux_dev_secrets_validate_file "$explicit_file" || return $?

  local home_dir="${HOME:-}"
  local dogfood_file="${home_dir}/.secrets/cmuxterm-dev.env"
  local agent_file="${home_dir}/.secrets/cmux.env"
  local email="" password="" resolved_profile=""

  # shellcheck disable=SC2329
  cmux_dev_secrets__dev_file_dogfood() {
    case "$1" in EMAIL) cmux_dev_secrets__read_key "$dogfood_file" CMUX_DOGFOOD_STACK_EMAIL ;; PASSWORD) cmux_dev_secrets__read_key "$dogfood_file" CMUX_DOGFOOD_STACK_PASSWORD ;; esac
  }
  # shellcheck disable=SC2329
  cmux_dev_secrets__agent_file_dogfood() {
    case "$1" in EMAIL) cmux_dev_secrets__read_key "$agent_file" CMUX_DOGFOOD_STACK_EMAIL ;; PASSWORD) cmux_dev_secrets__read_key "$agent_file" CMUX_DOGFOOD_STACK_PASSWORD ;; esac
  }
  # shellcheck disable=SC2329
  cmux_dev_secrets__env_dogfood() {
    case "$1" in EMAIL) printf '%s' "${CMUX_DOGFOOD_STACK_EMAIL:-}" ;; PASSWORD) printf '%s' "${CMUX_DOGFOOD_STACK_PASSWORD:-}" ;; esac
  }
  # shellcheck disable=SC2329
  cmux_dev_secrets__dev_file_uitest() {
    case "$1" in EMAIL) cmux_dev_secrets__read_key "$dogfood_file" CMUX_UITEST_STACK_EMAIL ;; PASSWORD) cmux_dev_secrets__read_key "$dogfood_file" CMUX_UITEST_STACK_PASSWORD ;; esac
  }
  # shellcheck disable=SC2329
  cmux_dev_secrets__agent_file_uitest() {
    case "$1" in EMAIL) cmux_dev_secrets__read_key "$agent_file" CMUX_UITEST_STACK_EMAIL ;; PASSWORD) cmux_dev_secrets__read_key "$agent_file" CMUX_UITEST_STACK_PASSWORD ;; esac
  }
  # shellcheck disable=SC2329
  cmux_dev_secrets__env_uitest() {
    case "$1" in EMAIL) printf '%s' "${CMUX_UITEST_STACK_EMAIL:-}" ;; PASSWORD) printf '%s' "${CMUX_UITEST_STACK_PASSWORD:-}" ;; esac
  }

  if [[ -n "$explicit_file" ]]; then
    # shellcheck disable=SC2329
    cmux_dev_secrets__explicit_dogfood() {
      case "$1" in EMAIL) cmux_dev_secrets__read_key "$explicit_file" CMUX_DOGFOOD_STACK_EMAIL ;; PASSWORD) cmux_dev_secrets__read_key "$explicit_file" CMUX_DOGFOOD_STACK_PASSWORD ;; esac
    }
    # shellcheck disable=SC2329
    cmux_dev_secrets__explicit_uitest() {
      case "$1" in EMAIL) cmux_dev_secrets__read_key "$explicit_file" CMUX_UITEST_STACK_EMAIL ;; PASSWORD) cmux_dev_secrets__read_key "$explicit_file" CMUX_UITEST_STACK_PASSWORD ;; esac
    }
    if [[ "$profile" != "agent" ]] \
        && cmux_dev_secrets__try_pair email password cmux_dev_secrets__explicit_dogfood; then
      resolved_profile="personal"
    elif [[ "$profile" != "personal" ]] \
        && cmux_dev_secrets__try_pair email password cmux_dev_secrets__explicit_uitest; then
      resolved_profile="agent"
    fi
  elif [[ "$profile" == "personal" ]]; then
    if cmux_dev_secrets__try_pair email password cmux_dev_secrets__dev_file_dogfood \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__agent_file_dogfood \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__env_dogfood; then
      resolved_profile="personal"
    fi
  elif [[ "$profile" == "agent" ]]; then
    if cmux_dev_secrets__try_pair email password cmux_dev_secrets__dev_file_uitest \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__agent_file_uitest \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__env_uitest; then
      resolved_profile="agent"
    fi
  else
    if cmux_dev_secrets__try_pair email password cmux_dev_secrets__dev_file_dogfood \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__agent_file_dogfood \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__env_dogfood; then
      resolved_profile="personal"
    elif cmux_dev_secrets__try_pair email password cmux_dev_secrets__dev_file_uitest \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__agent_file_uitest \
        || cmux_dev_secrets__try_pair email password cmux_dev_secrets__env_uitest; then
      resolved_profile="agent"
    fi
  fi

  if [[ -z "$email" || -z "$password" ]]; then
    if [[ "$profile" == "personal" ]]; then
      echo "error: personal auth profile requires complete CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD values${explicit_file:+ in $explicit_file}" >&2
      echo "error: run scripts/setup-team-dev.sh once to configure ~/.secrets/cmuxterm-dev.env" >&2
    elif [[ "$profile" == "agent" ]]; then
      echo "error: agent auth profile requires complete CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD values${explicit_file:+ in $explicit_file}" >&2
      echo "error: configure the shared agent pair in ~/.secrets/cmuxterm-dev.env" >&2
    elif [[ -n "$explicit_file" ]]; then
      echo "error: explicit credentials file does not contain a complete supported credential pair" >&2
    else
      echo "error: no dev sign-in credentials found; run scripts/setup-team-dev.sh" >&2
    fi
    return 2
  fi

  local normalized_email normalized_expected
  normalized_email="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | xargs)"
  normalized_expected="$(printf '%s' "$expected_account" | tr '[:upper:]' '[:lower:]' | xargs)"
  if [[ -n "$normalized_expected" && "$normalized_expected" != "$normalized_email" ]]; then
    echo "error: expected auth account '$normalized_expected', but profile '$resolved_profile' resolved '$normalized_email'" >&2
    return 2
  fi

  CMUX_UITEST_STACK_EMAIL="$email"
  CMUX_UITEST_STACK_PASSWORD="$password"
  CMUX_DEV_AUTH_PROFILE="$resolved_profile"
  CMUX_DEV_AUTH_ACCOUNT="$normalized_email"
  export CMUX_DEV_AUTH_PROFILE CMUX_DEV_AUTH_ACCOUNT
  if [[ -n "$explicit_file" ]]; then
    export -n CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD
    unset CMUX_DOGFOOD_STACK_EMAIL CMUX_DOGFOOD_STACK_PASSWORD
  else
    export CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD
  fi
  if [[ -n "$explicit_file" ]]; then
    echo "==> dev sign-in profile: $resolved_profile ([redacted])"
  else
    echo "==> dev sign-in profile: $resolved_profile ($CMUX_DEV_AUTH_ACCOUNT)"
  fi
  return 0
}
