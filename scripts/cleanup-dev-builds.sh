#!/usr/bin/env bash
# Clean up tagged dev-build artifacts created by scripts/reload.sh.
#
# Each `./scripts/reload.sh --tag <tag>` produces:
#   ~/Library/Developer/Xcode/DerivedData/cmux-<tag>/      (multi-GB)
#   /tmp/cmux-<tag>/                                       (build scratch)
#   /tmp/cmux-debug-<tag>.sock                             (control socket)
#   /tmp/cmux-debug-<tag>.log                              (debug log)
#   /tmp/cmux-reload-<tag>.log                             (build log)
#   ~/Library/Application Support/cmux/cmuxd-dev-<tag>.sock (cmuxd socket)
#
# This script removes those artifacts for tags that are safe to clean.
# Safety rules (always on):
#   - Skip any tag whose `cmux DEV <tag>` app is currently running.
#   - Skip the tag pointed at by /tmp/cmux-last-cli-path (most recent reload).
#   - Skip tags pinned by cmux-manager in
#     ~/.cache/cmux-manager-loop/pinned-tags.txt.
#   - Skip tags referenced by an open cmux PR's dogfood URL
#     (http://127.0.0.1:17320/<tag>) in its body, comments, or commits.
#
# The GitHub scan is a safety source, not an optimization. If it cannot run,
# the script fails closed and skips every tag for this run.
# A worktree merely existing on the same name is not treated as a
# protection. Use --keep TAG when you want to preserve a build whose
# worktree you still have around, or --older-than DAYS to skip anything
# you have touched recently.
#
# Defaults to dry-run. Pass --apply to actually delete.
#
# Filters:
#   --older-than <DAYS>   Only touch tags whose DerivedData mtime is at
#                         least DAYS days old.
#   --keep <TAG>          Protect a tag (repeatable).
#   --apply               Delete instead of preview.
#
# Examples:
#   ./scripts/cleanup-dev-builds.sh
#   ./scripts/cleanup-dev-builds.sh --older-than 7
#   ./scripts/cleanup-dev-builds.sh --keep sidebar-lazy --keep txtbox --apply

set -euo pipefail

DERIVED_DATA_ROOT="${CMUX_CLEANUP_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
APP_SUPPORT_DIR="${CMUX_CLEANUP_APP_SUPPORT_DIR:-$HOME/Library/Application Support/cmux}"
LAST_CLI_PATH_FILE="${CMUX_CLEANUP_LAST_CLI_PATH:-/tmp/cmux-last-cli-path}"
PINNED_TAGS_FILE="${CMUX_CLEANUP_PINNED_TAGS_FILE:-$HOME/.cache/cmux-manager-loop/pinned-tags.txt}"
GH_BIN="${CMUX_CLEANUP_GH_BIN:-gh}"
PR_REPOSITORY="${CMUX_CLEANUP_PR_REPOSITORY:-manaflow-ai/cmux}"

readonly TAG_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly DOGFOOD_URL_PATTERN='http://127\.0\.0\.1:17320/[A-Za-z0-9][A-Za-z0-9._-]*'

apply=0
older_than_days=0
keep_tags=()

usage() {
    awk '/^# / && !/^#!/ {sub(/^# ?/, ""); print; next} /^set -euo/ {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) apply=1; shift ;;
        --older-than)
            older_than_days="${2:?--older-than requires DAYS}"
            shift 2
            ;;
        --keep)
            keep_tags+=("${2:?--keep requires TAG}")
            shift 2
            ;;
        -h|--help) usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 2 ;;
    esac
done

# ---- discovery --------------------------------------------------------------

# Tags come from DerivedData dirs named cmux-<tag>. Authoritative because
# reload.sh always creates one there.
discover_tags() {
    [[ -d "$DERIVED_DATA_ROOT" ]] || return 0
    local d name
    for d in "$DERIVED_DATA_ROOT"/cmux-*/; do
        # The glob leaves the literal pattern if no matches exist on macOS.
        [[ -d "$d" ]] || continue
        name="${d%/}"
        name="${name##*/}"
        printf '%s\n' "${name#cmux-}"
    done
}

artifact_paths_for_tag() {
    local tag="$1"
    printf '%s\n' \
        "$DERIVED_DATA_ROOT/cmux-${tag}" \
        "/tmp/cmux-${tag}" \
        "/tmp/cmux-${tag}.tar" \
        "/tmp/cmux-debug-${tag}.sock" \
        "/tmp/cmux-debug-${tag}.log" \
        "/tmp/cmux-reload-${tag}.log" \
        "$APP_SUPPORT_DIR/cmuxd-dev-${tag}.sock"
}

bytes_in_path() {
    local p="$1"
    [[ -e "$p" || -L "$p" ]] || { echo 0; return; }
    # du -sk reports KB, portable across macOS and Linux. Convert to bytes.
    local kb
    kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
    [[ -n "$kb" ]] || kb=0
    echo "$((kb * 1024))"
}

human_bytes() {
    local b="$1"
    awk -v b="$b" 'BEGIN {
        split("B KB MB GB TB", u);
        for (i = 1; b >= 1024 && i < 5; i++) b /= 1024;
        printf "%.1f %s", b, u[i];
    }'
}

derived_data_mtime_days() {
    local p="$1"
    [[ -e "$p" ]] || { echo -1; return; }
    local mtime
    mtime="$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null)"
    local now
    now="$(date +%s)"
    echo $(( (now - mtime) / 86400 ))
}

# ---- durable protection sources --------------------------------------------

# Keep the arrays indexed together instead of using an associative array: the
# macOS system Bash is still 3.2, which predates associative arrays.
protected_tags=()
protected_reasons=()
protection_degradation_reasons=()

add_protected_tag() {
    local tag="$1" reason="$2" i
    [[ "$tag" =~ $TAG_PATTERN ]] || return 0

    for ((i = 0; i < ${#protected_tags[@]}; i++)); do
        if [[ "${protected_tags[$i]}" == "$tag" ]]; then
            case ",${protected_reasons[$i]}," in
                *",$reason,"*) ;;
                *) protected_reasons[$i]="${protected_reasons[$i]}, $reason" ;;
            esac
            return 0
        fi
    done

    protected_tags+=("$tag")
    protected_reasons+=("$reason")
}

record_protection_degradation() {
    protection_degradation_reasons+=("$1")
}

contains() {
    local needle="$1"; shift
    for x in "$@"; do
        [[ "$x" == "$needle" ]] && return 0
    done
    return 1
}

extract_dogfood_tags() {
    # grep -o emits one match per URL, so multiple URLs on one PR field are
    # all considered. A missing match is healthy and must not trigger set -e.
    printf '%s\n' "$1" \
        | grep -Eo "$DOGFOOD_URL_PATTERN" \
        | sed 's#^.*/##' \
        | sed 's/[.,;:!?)]*$//' \
        | sort -u \
        || true
}

load_pinned_tags() {
    # A missing pin file means cmux-manager has not created any pins yet. An
    # unreadable path is different: a partial read could silently lose a live
    # handoff, so fail closed for this run.
    [[ -e "$PINNED_TAGS_FILE" ]] || return 0
    if [[ ! -f "$PINNED_TAGS_FILE" || ! -r "$PINNED_TAGS_FILE" ]]; then
        record_protection_degradation "pinned tags file is unreadable: $PINNED_TAGS_FILE"
        return 0
    fi

    local line trimmed
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="$line"
        # Ignore whitespace-only lines and comments while accepting the simple
        # one-tag-per-line format written by cmux-manager.
        trimmed="${trimmed#${trimmed%%[![:space:]]*}}"
        trimmed="${trimmed%${trimmed##*[![:space:]]}}"
        [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
        [[ "$trimmed" =~ $TAG_PATTERN ]] || continue
        add_protected_tag "$trimmed" "pinned tag"
    done < "$PINNED_TAGS_FILE"
}

load_open_pr_tags() {
    if ! command -v "$GH_BIN" >/dev/null 2>&1; then
        record_protection_degradation "GitHub CLI is unavailable ($GH_BIN)"
        return 0
    fi

    # GitHub's issue search indexes pull-request bodies and comments, so this
    # keeps the normal cleanup heartbeat to one bounded query instead of
    # downloading every open PR and every repository comment.
    local pr_records
    if ! pr_records="$(
            "$GH_BIN" api -X GET --paginate search/issues \
            -f "q=repo:$PR_REPOSITORY is:pr is:open \"http://127.0.0.1:17320/\"" \
            --jq '.items[] | [.number, (.body // "")] | @tsv' \
            2>/dev/null
    )"; then
        record_protection_degradation "open PR body/comment scan failed via $GH_BIN"
        return 0
    fi

    local number body tag
    while IFS=$'\t' read -r number body; do
        [[ -n "$number" ]] || continue
        while IFS= read -r tag; do
            [[ -n "$tag" ]] || continue
            add_protected_tag "$tag" "open PR dogfood URL"
        done < <(extract_dogfood_tags "$body")

        local comment_records
        if ! comment_records="$(
            "$GH_BIN" api --paginate \
                "repos/$PR_REPOSITORY/issues/$number/comments" \
                --jq '.[].body // empty' \
                2>/dev/null
        )"; then
            record_protection_degradation "open PR comment scan failed for #$number via $GH_BIN"
            return 0
        fi
        while IFS= read -r tag; do
            [[ -n "$tag" ]] || continue
            add_protected_tag "$tag" "open PR dogfood URL"
        done < <(extract_dogfood_tags "$comment_records")
    done <<< "$pr_records"

    # Search commit messages once, then ask GitHub which pull requests contain
    # each matching commit. This avoids one commits request per open PR while
    # still excluding URLs from merged or unrelated history.
    local commit_records
    if ! commit_records="$(
        "$GH_BIN" api -X GET --paginate search/commits \
            -f "q=repo:$PR_REPOSITORY \"http://127.0.0.1:17320/\"" \
            --jq '.items[] | [.sha, (.commit.message // "")] | @tsv' \
            2>/dev/null
    )"; then
        record_protection_degradation "open PR commit search failed via $GH_BIN"
        return 0
    fi

    local sha commit_message commit_pulls
    while IFS=$'\t' read -r sha commit_message; do
        [[ -n "$sha" ]] || continue
        if ! commit_pulls="$(
            "$GH_BIN" api --paginate \
                "repos/$PR_REPOSITORY/commits/$sha/pulls" \
                --jq '.[].state' \
                2>/dev/null
        )"; then
            record_protection_degradation "open PR association lookup failed for commit $sha"
            return 0
        fi
        [[ "$commit_pulls" == *open* ]] || continue
        while IFS= read -r tag; do
            [[ -n "$tag" ]] || continue
            add_protected_tag "$tag" "open PR dogfood URL"
        done < <(extract_dogfood_tags "$commit_message")
    done <<< "$commit_records"
}

load_protection_sources() {
    load_pinned_tags
    load_open_pr_tags
}

# ---- safety probes ----------------------------------------------------------

# Active tag (most recent reload) per the CLI symlink target. Match
# `/cmux-<tag>/` anywhere in the path so we cover paths under DerivedData,
# /tmp, or other locations reload.sh may emit.
active_tag=""
if [[ -r "$LAST_CLI_PATH_FILE" ]]; then
    last_path="$(cat "$LAST_CLI_PATH_FILE" 2>/dev/null || true)"
    if [[ "$last_path" =~ /cmux-([A-Za-z0-9._-]+)/ ]]; then
        active_tag="${BASH_REMATCH[1]}"
    fi
fi

# Running cmux DEV processes by tag (the app name embeds the tag).
running_tags=()
while IFS= read -r line; do
    # Match "cmux DEV <tag>" (with or without .app suffix).
    if [[ "$line" =~ cmux\ DEV\ ([A-Za-z0-9._-]+) ]]; then
        running_tags+=("${BASH_REMATCH[1]}")
    fi
done < <(pgrep -fl "cmux DEV " 2>/dev/null || true)

load_protection_sources

# ---- planning ---------------------------------------------------------------

declare -a plan_delete=()
declare -a plan_skip=()
total_bytes=0

while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    reasons=()

    if (( ${#protection_degradation_reasons[@]} > 0 )); then
        reasons+=("protection unavailable")
    fi

    if [[ "$tag" == "$active_tag" ]]; then
        reasons+=("active (most recent reload)")
    fi
    if contains "$tag" ${running_tags[@]+"${running_tags[@]}"}; then
        reasons+=("app running")
    fi
    if contains "$tag" ${keep_tags[@]+"${keep_tags[@]}"}; then
        reasons+=("--keep")
    fi
    for ((i = 0; i < ${#protected_tags[@]}; i++)); do
        if [[ "${protected_tags[$i]}" == "$tag" ]]; then
            reasons+=("${protected_reasons[$i]}")
            break
        fi
    done
    if (( older_than_days > 0 )); then
        age="$(derived_data_mtime_days "$DERIVED_DATA_ROOT/cmux-${tag}")"
        # age == -1 means the DerivedData dir is gone (e.g., manually
        # deleted while orphan sockets/logs remain). Treat as "no age
        # signal, age filter does not apply" so the residue still gets
        # cleaned. Otherwise apply the threshold normally.
        if (( age >= 0 && age < older_than_days )); then
            reasons+=("age ${age}d < ${older_than_days}d")
        fi
    fi

    tag_bytes=0
    while IFS= read -r p; do
        tag_bytes=$(( tag_bytes + $(bytes_in_path "$p") ))
    done < <(artifact_paths_for_tag "$tag")

    if (( ${#reasons[@]} == 0 )); then
        plan_delete+=("$tag|$tag_bytes")
        total_bytes=$(( total_bytes + tag_bytes ))
    else
        IFS=, ; reason_str="${reasons[*]}" ; IFS=$' \t\n'
        plan_skip+=("$tag|$tag_bytes|$reason_str")
    fi
done < <(discover_tags | sort)

# ---- output -----------------------------------------------------------------

printf 'cleanup-dev-builds  (mode: %s)\n\n' "$([[ $apply -eq 1 ]] && echo APPLY || echo DRY-RUN)"

if (( ${#protection_degradation_reasons[@]} > 0 )); then
    printf 'protection unavailable (failing closed):\n'
    for reason in "${protection_degradation_reasons[@]}"; do
        printf '  %s\n' "$reason"
    done
    echo
fi

if (( ${#plan_skip[@]} > 0 )); then
    printf 'skipping:\n'
    for entry in "${plan_skip[@]}"; do
        IFS='|' read -r tag bytes reason <<< "$entry"
        printf '  %-40s %10s  (%s)\n' "$tag" "$(human_bytes "$bytes")" "$reason"
    done
    echo
fi

if (( ${#plan_delete[@]} == 0 )); then
    printf 'nothing to clean.\n'
    exit 0
fi

printf 'would delete:\n'
for entry in "${plan_delete[@]}"; do
    IFS='|' read -r tag bytes <<< "$entry"
    printf '  %-40s %10s\n' "$tag" "$(human_bytes "$bytes")"
done
printf '\ntotal reclaimable: %s across %d tag(s)\n' "$(human_bytes "$total_bytes")" "${#plan_delete[@]}"

if (( apply == 0 )); then
    printf '\nDry run. Re-run with --apply to delete.\n'
    exit 0
fi

echo
echo 'applying...'
for entry in "${plan_delete[@]}"; do
    IFS='|' read -r tag _ <<< "$entry"
    while IFS= read -r p; do
        if [[ -e "$p" || -L "$p" ]]; then
            rm -rf -- "$p"
        fi
    done < <(artifact_paths_for_tag "$tag")
    printf '  removed: %s\n' "$tag"
done
# Estimated because total_bytes was measured during planning. If a
# concurrent process (e.g., Xcode's "Delete Derived Data") removed a
# planned path between then and now, rm -rf skips it but the byte
# count still includes those bytes.
printf '\nfreed (estimated): %s\n' "$(human_bytes "$total_bytes")"
