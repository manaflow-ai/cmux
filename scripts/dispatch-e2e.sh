#!/usr/bin/env bash
# Validated dispatcher for the hosted E2E workflow (test-e2e.yml).
#
# A test_filter that matches zero tests still costs a full CI dispatch+watch
# cycle before the run fails with "executed 0 tests". This wrapper validates
# every filter item against the local checkout first and refuses to dispatch
# on a miss, printing the nearest candidate classes instead.
#
# Usage:
#   scripts/dispatch-e2e.sh --ref <branch-or-sha> --filter "<Class or Class/method>[,more]" \
#     [--runner <runner>] [--record-video true|false] [--timeout <seconds>] \
#     [--job-timeout <minutes>] [--watch] [--dry-run]
#
# Filter items are comma-separated; each item dispatches its own workflow run.
# A bare "Class" or "Class/method" targets cmuxUITests (the workflow's
# back-compat default). Target-qualified "cmuxTests/Class[/method]" or
# "cmuxUITests/Class[/method]" is validated against that target's directory.
#
# Validation reads THIS checkout's test sources, so run it from the worktree
# that matches the ref you dispatch.
#
# Exit codes:
#   0  dispatched (and, with --watch, all runs passed)
#   1  usage error, dispatch failure, or watched run failed
#   2  validation failed (class or method not found)

set -euo pipefail

REPO="manaflow-ai/cmux"
WORKFLOW="test-e2e.yml"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

REF=""
FILTERS_RAW=""
RUNNER=""
RECORD_VIDEO=""
TEST_TIMEOUT=""
JOB_TIMEOUT=""
WATCH=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      [ $# -ge 2 ] || die "--ref needs a value"
      REF="$2"
      shift 2
      ;;
    --filter)
      [ $# -ge 2 ] || die "--filter needs a value"
      FILTERS_RAW="$2"
      shift 2
      ;;
    --runner)
      [ $# -ge 2 ] || die "--runner needs a value"
      RUNNER="$2"
      shift 2
      ;;
    --record-video)
      [ $# -ge 2 ] || die "--record-video needs true or false"
      RECORD_VIDEO="$2"
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout needs a value (per-test seconds)"
      TEST_TIMEOUT="$2"
      shift 2
      ;;
    --job-timeout)
      [ $# -ge 2 ] || die "--job-timeout needs a value (job minutes)"
      JOB_TIMEOUT="$2"
      shift 2
      ;;
    --watch)
      WATCH=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

[ -n "$REF" ] || die "--ref is required"
[ -n "$FILTERS_RAW" ] || die "--filter is required"
if [ -n "$RECORD_VIDEO" ] && [ "$RECORD_VIDEO" != "true" ] && [ "$RECORD_VIDEO" != "false" ]; then
  die "--record-video must be true or false"
fi
if [ -n "$TEST_TIMEOUT" ] && ! [[ "$TEST_TIMEOUT" =~ ^[0-9]+$ ]]; then
  die "--timeout must be an integer (seconds)"
fi
if [ -n "$JOB_TIMEOUT" ] && ! [[ "$JOB_TIMEOUT" =~ ^[0-9]+$ ]]; then
  die "--job-timeout must be an integer (minutes)"
fi

# --- validation -------------------------------------------------------------

# All class names declared under a test target directory.
list_classes() {
  local dir="$1"
  grep -rhoE '\bclass[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' --include='*.swift' "$dir" 2>/dev/null |
    awk '{print $2}' | sort -u
}

# Files declaring the given class.
class_files() {
  local dir="$1" cls="$2"
  grep -rlE "class[[:space:]]+${cls}\b" --include='*.swift' "$dir" 2>/dev/null || true
}

# Files declaring the class OR an extension of it (methods may live in either).
related_files() {
  local dir="$1" cls="$2"
  grep -rlE "(class|extension)[[:space:]]+${cls}\b" --include='*.swift' "$dir" 2>/dev/null || true
}

# Direct-member lines of `class <cls>` / `extension <cls>` blocks across the
# given files, tracked by brace depth. Only depth-1 lines are emitted, so a
# same-file sibling class, a nested type's methods, or a function nested in a
# method body cannot satisfy a Class/method filter that XCTest would resolve
# to zero tests.
class_scoped_lines() {
  local cls="$1"
  shift
  [ $# -gt 0 ] || return 0
  awk -v cls="$cls" '
    FNR == 1 { inside = 0; depth = 0; seen_open = 0 }
    {
      if (!inside) {
        if ($0 ~ ("(^|[^A-Za-z0-9_])(class|extension)[[:space:]]+" cls "([^A-Za-z0-9_]|$)")) {
          inside = 1; depth = 0; seen_open = 0
        } else {
          next
        }
      }
      if (seen_open && depth == 1) print
      line = $0
      o = gsub(/{/, "", line)
      c = gsub(/}/, "", line)
      depth += o - c
      if (o > 0) seen_open = 1
      if (seen_open && depth <= 0) inside = 0
    }
  ' "$@"
}

# XCTest discovers only parameterless INSTANCE methods named test*; a static,
# class, private, or fileprivate func is never discovered and would dispatch a
# zero-test hosted run.
NON_INSTANCE_MODIFIERS='(^|[[:space:]])(static|private|fileprivate)[[:space:]]|class[[:space:]]+func'

# Nearest candidates for a missed name, best first.
suggest_names() {
  local query="$1"
  shift
  [ $# -gt 0 ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$query" "$@" <<'PY'
import difflib
import sys

query = sys.argv[1]
names = sys.argv[2:]
ranked = difflib.get_close_matches(query, names, n=5, cutoff=0.3)
q = query.lower()
for name in names:
    if name in ranked:
        continue
    n = name.lower()
    if q in n or n in q:
        ranked.append(name)
print("\n".join(ranked[:5]))
PY
  else
    printf '%s\n' "$@" | grep -i -- "$query" | head -5 || true
  fi
}

validate_item() {
  local item="$1"
  local target_dir="$ROOT/cmuxUITests"
  local target_name="cmuxUITests"
  local rest="$item"

  case "$item" in
    cmuxTests/*)
      target_dir="$ROOT/cmuxTests"
      target_name="cmuxTests"
      rest="${item#cmuxTests/}"
      ;;
    cmuxUITests/*)
      rest="${item#cmuxUITests/}"
      ;;
  esac

  local cls="${rest%%/*}"
  local method=""
  if [ "$rest" != "$cls" ]; then
    method="${rest#*/}"
  fi

  if ! [[ "$cls" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    die "invalid class name in filter item '$item'"
  fi
  if [ -n "$method" ] && ! [[ "$method" =~ ^[A-Za-z_][A-Za-z0-9_]*(\(\))?$ ]]; then
    die "invalid method name in filter item '$item'"
  fi
  [ -d "$target_dir" ] || die "test directory not found: $target_dir"

  local files
  files="$(class_files "$target_dir" "$cls")"
  if [ -z "$files" ]; then
    echo "error: no 'class $cls' found under $target_name/ for filter item '$item'" >&2
    local -a all_classes=()
    while IFS= read -r name; do
      if [ -n "$name" ]; then
        all_classes+=("$name")
      fi
    done < <(list_classes "$target_dir")
    local suggestions=""
    if [ "${#all_classes[@]}" -gt 0 ]; then
      suggestions="$(suggest_names "$cls" "${all_classes[@]}")"
    fi
    if [ -n "$suggestions" ]; then
      echo "nearest candidates:" >&2
      printf '%s\n' "$suggestions" | sed 's/^/  /' >&2
    fi
    exit 2
  fi

  if [ -n "$method" ]; then
    local method_bare="${method%()}"
    # XCTest only discovers parameterless instance methods named test*; any
    # other func would make the hosted -only-testing filter run zero tests.
    if [[ "$method_bare" != test* ]]; then
      echo "error: '$method_bare' is not an XCTest test method (must start with 'test'); the hosted filter would run zero tests" >&2
      exit 2
    fi
    local -a scope_files=()
    local file
    while IFS= read -r file; do
      [ -n "$file" ] && scope_files+=("$file")
    done < <(related_files "$target_dir" "$cls")
    local scoped
    scoped="$(class_scoped_lines "$cls" "${scope_files[@]}")"
    local found=0
    # grep must read the full stream (no -q): under pipefail, -q's early exit
    # SIGPIPEs printf and fails the pipeline even on a match. Empty parens
    # required: XCTest skips test methods that take parameters.
    if printf '%s\n' "$scoped" |
      grep -E "func[[:space:]]+${method_bare}[[:space:]]*\(\)" |
      grep -vE "$NON_INSTANCE_MODIFIERS" >/dev/null; then
      found=1
    fi
    if [ "$found" -eq 0 ]; then
      echo "error: no 'func $method_bare' found in class $cls for filter item '$item'" >&2
      local -a all_methods=()
      while IFS= read -r name; do
        if [ -n "$name" ]; then
          all_methods+=("$name")
        fi
      done < <(
        printf '%s\n' "$scoped" | grep -vE "$NON_INSTANCE_MODIFIERS" |
          grep -oE 'func[[:space:]]+test[A-Za-z0-9_]*' | awk '{print $2}' | sort -u
      )
      local suggestions=""
      if [ "${#all_methods[@]}" -gt 0 ]; then
        suggestions="$(suggest_names "$method_bare" "${all_methods[@]}")"
      fi
      if [ -n "$suggestions" ]; then
        echo "nearest candidates:" >&2
        printf '%s\n' "$suggestions" | sed 's/^/  /' >&2
      fi
      exit 2
    fi
  fi

  echo "ok: $item (class $cls${method:+, method ${method%()}} in $target_name/)"
}

# --- dispatch ---------------------------------------------------------------

dispatch_args_for() {
  local filter="$1" nonce="${2:-}"
  DISPATCH_ARGS=(workflow run "$WORKFLOW" --repo "$REPO" -f "ref=$REF" -f "test_filter=$filter")
  if [ -n "$nonce" ]; then
    DISPATCH_ARGS+=(-f "dispatch_id=$nonce")
  fi
  if [ -n "$RUNNER" ]; then
    DISPATCH_ARGS+=(-f "runner=$RUNNER")
  fi
  if [ -n "$RECORD_VIDEO" ]; then
    DISPATCH_ARGS+=(-f "record_video=$RECORD_VIDEO")
  fi
  if [ -n "$TEST_TIMEOUT" ]; then
    DISPATCH_ARGS+=(-f "test_timeout=$TEST_TIMEOUT")
  fi
  if [ -n "$JOB_TIMEOUT" ]; then
    DISPATCH_ARGS+=(-f "job_timeout=$JOB_TIMEOUT")
  fi
}

# Run ids that exist before dispatch, so the new run can be told apart.
existing_run_ids() {
  gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 30 \
    --json databaseId --jq '.[].databaseId' 2>/dev/null || true
}

# Resolve the just-dispatched run. When the workflow on main supports the
# dispatch_id input, the nonce is echoed into the run name and matching is
# exact. Otherwise fall back to the heuristic: a run that did not exist
# before dispatch whose run-name starts with the test_filter.
resolve_run_id() {
  local filter="$1" pre_ids="$2" nonce="${3:-}"
  local attempt id title
  for attempt in $(seq 1 15); do
    while IFS=$'\t' read -r id title; do
      [ -n "$id" ] || continue
      if [ -n "$nonce" ]; then
        case "$title" in
          *"[$nonce]"*)
            echo "$id"
            return 0
            ;;
        esac
        continue
      fi
      if printf '%s\n' "$pre_ids" | grep -qx "$id"; then
        continue
      fi
      case "$title" in
        "$filter on "*)
          echo "$id"
          return 0
          ;;
      esac
    done < <(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 30 \
      --json databaseId,displayTitle --jq '.[] | [.databaseId, .displayTitle] | @tsv' 2>/dev/null || true)
    if [ "$attempt" -lt 15 ]; then
      sleep 2
    fi
  done
  return 1
}

IFS=',' read -r -a FILTER_ITEMS <<<"$FILTERS_RAW"
CLEAN_ITEMS=()
for raw_item in "${FILTER_ITEMS[@]}"; do
  item="$(echo "$raw_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$item" ] || continue
  CLEAN_ITEMS+=("$item")
done
[ "${#CLEAN_ITEMS[@]}" -gt 0 ] || die "--filter contained no filter items"

for item in "${CLEAN_ITEMS[@]}"; do
  validate_item "$item"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: validation passed; would dispatch:"
  for item in "${CLEAN_ITEMS[@]}"; do
    dispatch_args_for "$item"
    printf 'gh'
    printf ' %q' "${DISPATCH_ARGS[@]}"
    printf '\n'
  done
  exit 0
fi

RUN_IDS=()
UNRESOLVED=0
DISPATCH_SEQ=0
for item in "${CLEAN_ITEMS[@]}"; do
  DISPATCH_SEQ=$((DISPATCH_SEQ + 1))
  nonce="d$(date +%s)-$$-$DISPATCH_SEQ"
  dispatch_args_for "$item" "$nonce"
  pre_ids="$(existing_run_ids)"
  echo "dispatching: $item @ $REF"
  if ! dispatch_err="$(gh "${DISPATCH_ARGS[@]}" 2>&1)"; then
    # The workflow definition on main may predate the dispatch_id input;
    # gh rejects unknown inputs with 422. Retry once without the nonce and
    # fall back to heuristic run resolution.
    if printf '%s' "$dispatch_err" | grep -qi "unexpected inputs"; then
      nonce=""
      dispatch_args_for "$item"
      gh "${DISPATCH_ARGS[@]}"
    else
      printf '%s\n' "$dispatch_err" >&2
      die "workflow dispatch failed for '$item'"
    fi
  fi
  if run_id="$(resolve_run_id "$item" "$pre_ids" "$nonce")"; then
    RUN_IDS+=("$run_id")
    echo "run: https://github.com/$REPO/actions/runs/$run_id"
  else
    UNRESOLVED=$((UNRESOLVED + 1))
    echo "warning: dispatched but could not resolve the new run id for '$item'." >&2
    echo "  gh run list --repo $REPO --workflow $WORKFLOW --limit 5" >&2
  fi
done

if [ "$WATCH" -eq 1 ]; then
  [ "${#RUN_IDS[@]}" -gt 0 ] || die "--watch requested but no run ids were resolved"
  FAILED=0
  for run_id in "${RUN_IDS[@]}"; do
    echo "watching run $run_id..."
    if ! gh run watch "$run_id" --repo "$REPO" --exit-status; then
      FAILED=1
    fi
  done
  if [ "$UNRESOLVED" -gt 0 ]; then
    # A watch that silently omits an unresolved run must not report success.
    echo "error: $UNRESOLVED dispatched run(s) could not be resolved and were not watched" >&2
    exit 1
  fi
  exit "$FAILED"
fi

if [ "$UNRESOLVED" -gt 0 ]; then
  echo "note: dispatch succeeded for all items; $UNRESOLVED run URL(s) could not be resolved" >&2
fi
