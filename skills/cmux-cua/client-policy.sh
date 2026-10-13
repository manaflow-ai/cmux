#!/usr/bin/env bash
# Shared Computer Use MCP client selection for the Claude and Codex wrappers.
#
# This file is bundled inside the signed cmux-cua resource and sourced by both
# wrappers. The only client is the cmux Computer Use helper the app installs
# into its tag-scoped directory: the app ships no second cmux-cua executable,
# and the daemon authenticates the Codex approval broker as that exact helper.
# It has no side effects until cmux_computer_use_resolve_client is called.

# The effective uid, read once from the kernel. Bash's $EUID is not usable here:
# macOS /bin/bash 3.2 takes EUID from the environment, and the uid decides which
# owner the trust check accepts. Cleared when sourced so the environment cannot
# seed it.
cmux_cua_client_uid=""
cmux_cua_client_effective_uid() {
    [[ -n "$cmux_cua_client_uid" ]] || cmux_cua_client_uid="$(/usr/bin/id -u 2>/dev/null || true)"
    [[ "$cmux_cua_client_uid" =~ ^[0-9]+$ ]]
}

# Print "<owner uid> <octal permissions>" for each path, one line per path, in
# a single stat process. The launch path used to spawn two stat processes (plus
# two subshells) per ancestor directory; under load each spawn costs tens of
# milliseconds of wall time before the agent starts.
cmux_computer_use_stat_owner_modes() {
    local stat_bin=/usr/bin/stat
    [[ -x "$stat_bin" ]] || stat_bin=/bin/stat
    [[ -x "$stat_bin" ]] || return 1
    "$stat_bin" -f '%u %Lp' "$@" 2>/dev/null || "$stat_bin" -c '%u %a' "$@" 2>/dev/null
}

# Succeed only when every "<owner> <mode>" line is owned by root or the current
# user, is neither group- nor world-writable, and the line count matches.
# Group write is as disqualifying as world write: write permission on a
# directory allows renaming the client away and dropping a replacement,
# regardless of the file's own permissions.
cmux_computer_use_owner_modes_are_trusted() {
    local output="$1"
    local expected_count="$2"
    local current_uid owner mode extra count=0
    cmux_cua_client_effective_uid || return 1
    current_uid="$cmux_cua_client_uid"
    while read -r owner mode extra; do
        [[ -z "$extra" && "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-9]+$ ]] || return 1
        [[ "$owner" == "0" || "$owner" == "$current_uid" ]] || return 1
        (( ((mode / 10) % 10 & 2) == 0 && (mode % 10 & 2) == 0 )) || return 1
        count=$((count + 1))
    done <<< "$output"
    (( count == expected_count ))
}

# The client binary must be a regular file (canonicalization has already
# resolved symlinks) and it and every ancestor directory must be owned by root
# or the current user and be neither group- nor world-writable: with write
# access another local user could swap the binary that runs under cmux's TCC
# identity. One stat process covers the file and all of its ancestors.
cmux_computer_use_trusted_client_path() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    local dir="${path%/*}"
    [[ "$dir" = /* ]] || return 1
    local -a paths=("$path")
    while :; do
        paths+=("$dir")
        [[ "$dir" == "/" ]] && break
        dir="${dir%/*}"
        [[ -n "$dir" ]] || dir="/"
    done
    local output
    output="$(cmux_computer_use_stat_owner_modes "${paths[@]}")" || return 1
    cmux_computer_use_owner_modes_are_trusted "$output" "${#paths[@]}"
}

cmux_computer_use_canonical_executable() {
    local candidate="$1"
    [[ "$candidate" = /* && -x "$candidate" ]] || return 1
    local path="$candidate"
    local hops=0
    while :; do
        local dir="${path%/*}"
        local base="${path##*/}"
        local dir_real
        dir_real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
        path="$dir_real/$base"
        [[ -L "$path" ]] || break
        (( hops < 16 )) || return 1
        local target
        target="$(/usr/bin/readlink "$path" 2>/dev/null || readlink "$path" 2>/dev/null)" || return 1
        if [[ "$target" = /* ]]; then
            path="$target"
        else
            path="$dir_real/$target"
        fi
        hops=$((hops + 1))
    done
    [[ -x "$path" ]] || return 1
    printf '%s' "$path"
}

cmux_computer_use_resolve_client() {
    # The client is the exact app-installed cmux-cua helper selected by cmux.
    # Codex compatibility mode brokers per-app approval, and the daemon
    # verifies that broker as the executable already serving the cmux-owned
    # socket, then verifies the broker's parent as signed OpenAI Codex.
    local installed_client client_real
    installed_client="${CMUX_CUA_CLIENT_PATH:-}"
    # Older app launches and CI-hosted wrapper invocations may not inherit the
    # app's exported client path. Reconstruct the same app-owned location from
    # the runtime scope, then apply the identical canonicalization and trust
    # checks below. Never fall back to an untrusted PATH lookup or to an
    # executable beside the wrapper: that would create a second TCC identity.
    if [[ -z "$installed_client" && "${HOME:-}" = /* ]]; then
        local runtime_scope="${CMUX_CUA_RUNTIME_SCOPE:-${CMUX_TAG:-default}}"
        installed_client="${HOME}/Library/Application Support/cmux/cmux-cua/helper/${runtime_scope}/cmux Computer Use.app/Contents/MacOS/cmux-cua"
    fi
    [[ -n "$installed_client" ]] || return 1
    client_real="$(cmux_computer_use_canonical_executable "$installed_client")" || return 1
    cmux_computer_use_trusted_client_path "$client_real" || return 1
    printf '%s' "$client_real"
}
