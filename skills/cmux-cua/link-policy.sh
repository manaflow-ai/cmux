#!/usr/bin/env bash
# Shared, ownership-safe skill-link policy for the Claude and Codex wrappers.
#
# This file is bundled inside the signed cmux-cua resource and sourced by both
# wrappers. It deliberately has no launch side effects until
# cmux_cua_skill_reconcile is called by a cmux-owned session.


cmux_cua_skill_readlink() {
    /usr/bin/readlink "$1" 2>/dev/null || /bin/readlink "$1" 2>/dev/null
}

cmux_cua_skill_lexical_normalize() {
    local path="$1"
    [[ "$path" = /* ]] || return 1
    local normalized="/"
    local remaining="${path#/}"
    local component
    while [[ -n "$remaining" ]]; do
        if [[ "$remaining" == */* ]]; then
            component="${remaining%%/*}"
            remaining="${remaining#*/}"
        else
            component="$remaining"
            remaining=""
        fi
        case "$component" in
            ""|.) continue ;;
            ..)
                if [[ "$normalized" != "/" ]]; then
                    normalized="${normalized%/*}"
                    [[ -n "$normalized" ]] || normalized="/"
                fi
                ;;
            *)
                if [[ "$normalized" == "/" ]]; then
                    normalized="/$component"
                else
                    normalized="$normalized/$component"
                fi
                ;;
        esac
    done
    printf '%s' "$normalized"
}

cmux_cua_skill_resolve_link_target() {
    local link="$1"
    local target="$2"
    local resolved
    if [[ "$target" = /* ]]; then
        resolved="$target"
    else
        resolved="${link%/*}/$target"
    fi
    cmux_cua_skill_lexical_normalize "$resolved"
}

cmux_cua_skill_canonical_document() {
    local path="$1"
    [[ "$path" = /* ]] || return 1
    if [[ -f "$path" ]]; then
        local parent="${path%/*}"
        local basename="${path##*/}"
        local canonical_parent
        canonical_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || canonical_parent=""
        if [[ -n "$canonical_parent" ]]; then
            printf '%s/%s' "$canonical_parent" "$basename"
            return 0
        fi
    fi
    cmux_cua_skill_lexical_normalize "$path"
}

cmux_cua_skill_frontmatter_name() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local awk_bin=/usr/bin/awk
    [[ -x "$awk_bin" ]] || awk_bin=awk
    "$awk_bin" '
        NR == 1 && $0 ~ /^---[[:space:]]*$/ { in_frontmatter = 1; next }
        in_frontmatter && $0 ~ /^---[[:space:]]*$/ { exit }
        in_frontmatter && $0 ~ /^name:[[:space:]]*/ {
            value = $0
            sub(/^name:[[:space:]]*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$file" 2>/dev/null
}

cmux_cua_skill_name_is() {
    local file="$1"
    local expected="$2"
    local value
    value="$(cmux_cua_skill_frontmatter_name "$file")" || return 1
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    [[ "$value" == "$expected" ]]
}

cmux_cua_skill_target_is_managed() {
    # A resource suffix, app name, or dangling path alone is not ownership
    # proof. A link is managed only when its existing bundle has cmux's bundle
    # identifier, lives in a known cmux install/build root, and is owned by
    # root or the current user. Removed bundles have no verifiable owner or
    # identity and are deliberately preserved for manual review.
    local target="$1"
    local resource_name
    case "$target" in
        */Contents/Resources/cmux-cua) resource_name=cmux-cua ;;
        */Contents/Resources/cmux-computer-use) resource_name=cmux-computer-use ;;
        */Contents/Resources/codex-cua) resource_name=codex-cua ;;
        *) return 1 ;;
    esac

    local app_bundle="${target%/Contents/Resources/$resource_name}"
    [[ "$app_bundle" == *.app ]] || return 1
    local home="${HOME:-}"
    local app_owner
    app_owner="$(/usr/bin/stat -f '%u' "$app_bundle" 2>/dev/null || true)"
    [[ "$app_owner" == "0" || "$app_owner" == "$(/usr/bin/id -u)" ]] || return 1

    case "$app_bundle" in
        /Applications/cmux*.app|/Applications/Utilities/cmux*.app|\
        "$home/Applications"/cmux*.app|\
        "$home/Library/Developer/Xcode/DerivedData"/cmux-*/Build/Products/*/cmux*.app|\
        /tmp/cmux-*/Build/Products/*/cmux*.app)
            ;;
        *)
            return 1
            ;;
    esac

    local info_plist="$app_bundle/Contents/Info.plist"
    if [[ -f "$info_plist" && -x /usr/libexec/PlistBuddy ]]; then
        local bundle_id
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null)" || return 1
        [[ "$bundle_id" == com.cmuxterm.* ]]
        return $?
    fi
    return 1
}

cmux_cua_skill_link_is_managed() {
    local link="$1"
    [[ -L "$link" ]] || return 1
    local target resolved
    target="$(cmux_cua_skill_readlink "$link")" || return 1
    [[ -n "$target" ]] || return 1
    resolved="$(cmux_cua_skill_resolve_link_target "$link" "$target")" || resolved="$target"
    cmux_cua_skill_target_is_managed "$resolved" || cmux_cua_skill_target_is_managed "$target"
}

cmux_cua_skill_remove_managed_link() {
    local link="$1"
    if cmux_cua_skill_link_is_managed "$link"; then
        # rm acts on the link itself because the target was validated and the
        # operand is an absolute path. Never recurse or follow the target.
        /bin/rm -f "$link" 2>/dev/null || true
        if [[ "${CMUX_CUA_DIAGNOSTICS:-0}" == 1 && ! -L "$link" ]]; then
            printf 'cmux-cua: managed-link-retired path=%q\n' "$link" >&2
        fi
        return 0
    fi
    return 1
}

cmux_cua_skill_link_state() {
    local link="$1"
    if cmux_cua_skill_link_is_managed "$link"; then
        printf '%s' managed
    elif [[ -L "$link" || -e "$link" ]]; then
        printf '%s' user
    else
        printf '%s' missing
    fi
}

cmux_cua_skill_project_candidate_is_collision() {
    local candidate="$1"
    local source_document="$2"
    [[ -f "$candidate" ]] || return 1
    cmux_cua_skill_name_is "$candidate" cmux-cua || return 1
    local candidate_canonical source_canonical
    candidate_canonical="$(cmux_cua_skill_canonical_document "$candidate")" || return 1
    source_canonical="$(cmux_cua_skill_canonical_document "$source_document")" || source_canonical="$source_document"
    [[ "$candidate_canonical" != "$source_canonical" ]]
}

cmux_cua_skill_document_is_user_global() {
    local candidate="$1"
    local provider="$2"
    local home="${HOME:-}"
    local codex_home="${CODEX_HOME:-$home/.codex}"
    local candidate_normalized
    candidate_normalized="$(cmux_cua_skill_lexical_normalize "$candidate" 2>/dev/null)" \
        || candidate_normalized="$candidate"
    local candidate_root_canonical=""
    local candidate_root="${candidate%/cmux-cua/SKILL.md}"
    if [[ -d "$candidate_root" ]]; then
        candidate_root_canonical="$(cd "$candidate_root" 2>/dev/null && pwd -P)"
    fi

    local -a global_roots
    if [[ "$provider" == codex ]]; then
        global_roots=("$home/.agents/skills" "$codex_home/skills")
    else
        global_roots=("$home/.claude/skills")
    fi

    local global_root global_normalized
    for global_root in "${global_roots[@]}"; do
        [[ "$global_root" = /* ]] || continue
        global_normalized="$(cmux_cua_skill_lexical_normalize "$global_root" 2>/dev/null)" \
            || continue
        if [[ "$candidate_normalized" == "$global_normalized/cmux-cua/SKILL.md" ]]; then
            return 0
        fi
        local global_root_canonical=""
        if [[ -d "$global_root" ]]; then
            global_root_canonical="$(cd "$global_root" 2>/dev/null && pwd -P)"
        fi
        [[ -n "$candidate_root_canonical" \
           && "$candidate_root_canonical" == "$global_root_canonical" ]] \
            && return 0
    done
    return 1
}

cmux_cua_skill_project_has_collision() {
    local cwd="$1"
    local provider="$2"
    local source_document="$3"
    [[ "$cwd" = /* ]] || return 1
    local dir
    dir="$(cd "$cwd" 2>/dev/null && pwd -P)" || return 1
    local depth=0
    local candidate
    while [[ "$dir" = /* && $depth -lt 64 ]]; do
        # User-global roots are not project roots. Compare the lexical path
        # before following a candidate symlink so a global link cannot be
        # mistaken for a project collision while walking `~/projects/foo` (or
        # a custom CODEX_HOME nested under another directory).
        if [[ "$provider" == codex ]]; then
            local -a candidates=(
                "$dir/.agents/skills/cmux-cua/SKILL.md"
                "$dir/.codex/skills/cmux-cua/SKILL.md"
            )
            for candidate in "${candidates[@]}"; do
                cmux_cua_skill_document_is_user_global "$candidate" "$provider" && continue
                if cmux_cua_skill_project_candidate_is_collision "$candidate" "$source_document"; then
                    return 0
                fi
            done
        else
            candidate="$dir/.claude/skills/cmux-cua/SKILL.md"
            if ! cmux_cua_skill_document_is_user_global "$candidate" "$provider" \
               && cmux_cua_skill_project_candidate_is_collision "$candidate" "$source_document"; then
                return 0
            fi
        fi

        # Match Codex's project-root boundary: once a repository marker is
        # found, do not inspect unrelated parent checkouts.
        [[ -e "$dir/.git" ]] && break
        [[ "$dir" == "/" ]] && break
        dir="${dir%/*}"
        [[ -n "$dir" ]] || dir=/
        depth=$((depth + 1))
    done
    return 1
}

cmux_cua_skill_remove_legacy_links() {
    local home="$1"
    local provider="$2"
    local codex_home="${CODEX_HOME:-$home/.codex}"
    local root link name
    if [[ "$provider" == codex ]]; then
        for root in "$home/.agents/skills" "$codex_home/skills"; do
            [[ "$root" = /* ]] || continue
            for name in cmux-computer-use codex-cua; do
                link="$root/$name"
                cmux_cua_skill_remove_managed_link "$link" || true
            done
        done
    else
        # Older Claude wrappers wrote the legacy name into Codex's shared root.
        for root in "$home/.claude/skills" "$home/.agents/skills"; do
            [[ "$root" = /* ]] || continue
            for name in cmux-computer-use codex-cua; do
                link="$root/$name"
                cmux_cua_skill_remove_managed_link "$link" || true
            done
        done
    fi
}

cmux_cua_skill_reconcile() {
    local provider="$1"
    local source_dir="$2"
    local cwd="$3"
    local install_requested="$4"
    local home="${HOME:-}"
    [[ "$home" = /* && "$source_dir" = /* ]] || return 1
    local source_document="$source_dir/SKILL.md"
    [[ -f "$source_document" ]] || return 1

    local project_collision=0
    if [[ "$install_requested" == 1 ]] \
       && cmux_cua_skill_project_has_collision "$cwd" "$provider" "$source_document"; then
        project_collision=1
    fi
    cmux_cua_skill_remove_legacy_links "$home" "$provider"

    local skills_root destination state legacy_root legacy_state
    if [[ "$provider" == codex ]]; then
        skills_root="$home/.agents/skills"
        legacy_root="${CODEX_HOME:-$home/.codex}/skills"
    else
        skills_root="$home/.claude/skills"
        legacy_root=""
    fi
    destination="$skills_root/cmux-cua"
    state="$(cmux_cua_skill_link_state "$destination")"
    local user_path_collision=0
    local blocked_path=""
    if [[ "$state" == user ]]; then
        user_path_collision=1
        blocked_path="$destination"
    fi
    if [[ -n "$legacy_root" && "$legacy_root" != "$skills_root" ]]; then
        legacy_state="$(cmux_cua_skill_link_state "$legacy_root/cmux-cua")"
        if [[ "$legacy_state" == user ]]; then
            user_path_collision=1
            [[ -n "$blocked_path" ]] || blocked_path="$legacy_root/cmux-cua"
        fi
    else
        legacy_state=missing
    fi

    if [[ "$install_requested" == 1 && "$user_path_collision" == 1 \
          && "${CMUX_CUA_DIAGNOSTICS:-0}" == 1 ]]; then
        printf 'cmux-cua: skill-install=blocked-user-path path=%q\n' "$blocked_path" >&2
    fi
    if [[ "$install_requested" == 1 && "$project_collision" == 1 \
          && "${CMUX_CUA_DIAGNOSTICS:-0}" == 1 ]]; then
        printf 'cmux-cua: skill-install=blocked-project-collision path=%q\n' "$cwd" >&2
    fi

    if [[ "$install_requested" == 1 \
          && "$project_collision" != 1 \
          && "$user_path_collision" != 1 ]]; then
        /bin/mkdir -p "$skills_root" 2>/dev/null || true
        if [[ "$state" == missing ]]; then
            /bin/ln -s "$source_dir" "$destination" 2>/dev/null || true
        elif [[ "$state" == managed ]]; then
            /bin/ln -sfn "$source_dir" "$destination" 2>/dev/null || true
        fi
    elif [[ "$state" == managed ]]; then
        # This is a per-launch preference, not an install receipt. Without
        # opt-in (or beside a project collision), retire only verified
        # app-managed links. Normal user-installed skills are never removed.
        cmux_cua_skill_remove_managed_link "$destination" || true
    fi
    # The deprecated root must not contribute a second managed discovery path,
    # including when the canonical destination has never been installed.
    if [[ "$legacy_state" == managed ]]; then
        cmux_cua_skill_remove_managed_link "$legacy_root/cmux-cua" || true
    fi
    return 0
}
