/** Read-only CodeRouter discovery through the VM's edge identity. */
export const GUEST_CODEROUTER_SHELL = `guest_coderouter_accounts() {
  cmux_ca_json=false
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) cmux_ca_json=true ;;
      *) die_message 2 unknownCodeRouter "\$cmux_arg" ;;
    esac
  done
  require_coderouter
  cmux_ca_native="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \\
    -H "authorization: Bearer \$cmux_coderouter_key" "\${cmux_coderouter_url%/}/api/coderouter/accounts")" || return 1
  cmux_ca_claude="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \\
    -H "authorization: Bearer \$cmux_coderouter_key" "\${cmux_coderouter_url%/}/api/coderouter/claude-upstream")" || return 1
  # A mismatched response is an error; never combine two organizations.
  cmux_ca_result="\$(jq -en --argjson native "\$cmux_ca_native" --argjson claude "\$cmux_ca_claude" '
    if (\$native.teamId | type) != "string" or \$native.teamId != \$claude.teamId then error("team_mismatch")
    else {teamId: \$native.teamId, accounts: (\$native.accounts + [\$claude.accounts[] | . + {provider: "claude"}])} end
  ')" || return 1
  if [ "\$cmux_ca_json" = true ] || [ "\${CMUX_OUTPUT:-}" = json ]; then
    printf '%s\\n' "\$cmux_ca_result"
  else
    printf '%s\\n' "\$cmux_ca_result" | jq -r --arg team "\$(cmux_message labelTeam)" '
      "\\(\$team): \\(.teamId)", (.accounts[] | [.provider, .label, .state] | @tsv)'
  fi
}

guest_coderouter_org() {
  [ "\${1:-current}" = current ] || die_message 2 accountHostOnly "org \${1:-}"
  [ "\$#" -eq 0 ] || shift
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in --json) ;; *) die_message 2 unknownCodeRouter "\$cmux_arg" ;; esac
  done
  require_coderouter
  cmux_ca_org="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \\
    -H "authorization: Bearer \$cmux_coderouter_key" "\${cmux_coderouter_url%/}/api/coderouter/organizations")" || return 1
  printf '%s\\n' "\$cmux_ca_org" | jq -e '.fixed == true and (.teams | length) == 1 and .selectedTeamId == .teams[0].id' >/dev/null || return 1
  if [ "\${1:-}" = --json ] || [ "\${CMUX_OUTPUT:-}" = json ]; then
    printf '%s\\n' "\$cmux_ca_org" | jq '{teamId: .selectedTeamId, fixed: true}'
  else
    printf '%s\\n' "\$cmux_ca_org" | jq -r '.selectedTeamId'
  fi
}
`;

/**
 * `cr use [own|team|auto] [claude|codex|opencode]... [--json]`: how each coding
 * agent signs in on this machine (all three when none is named). The mode
 * itself is resolved by the image's /etc/cmux/agent-auth.sh, the same file the
 * agent launchers read at every launch, so the report here and a launch can
 * never disagree. This only records the choice.
 */
export const GUEST_CODEROUTER_USE_SHELL = `guest_coderouter_use() {
  cmux_use_mode=""
  cmux_use_agents=""
  cmux_use_json=false
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      own|team|auto) [ -z "\$cmux_use_mode" ] || die_message 2 useOneMode; cmux_use_mode="\$cmux_arg" ;;
      claude|codex|opencode)
        case " \$cmux_use_agents " in
          *" \$cmux_arg "*) ;;
          *) cmux_use_agents="\${cmux_use_agents:+\$cmux_use_agents }\$cmux_arg" ;;
        esac
        ;;
      status|show) ;;
      --json) cmux_use_json=true ;;
      --help|-h|help) cmux_message useHelp; return 0 ;;
      *) die_message 2 useUnknown "\$cmux_arg" ;;
    esac
  done
  [ -n "\$cmux_use_agents" ] || cmux_use_agents="claude codex opencode"
  [ "\${CMUX_OUTPUT:-}" != json ] || cmux_use_json=true
  cmux_use_lib="\${CMUX_AGENT_AUTH_LIB:-/etc/cmux/agent-auth.sh}"
  [ -f "\$cmux_use_lib" ] || die_message 2 useUnsupported
  . "\$cmux_use_lib"
  for cmux_use_agent in \$cmux_use_agents; do
    cmux_use_file="\$(cmux_agent_auth_file "\$cmux_use_agent")"
    case "\$cmux_use_mode" in
      own|team)
        if { mkdir -p "\${cmux_use_file%/*}" && printf '%s\\n' "\$cmux_use_mode" > "\$cmux_use_file.tmp" && mv -f "\$cmux_use_file.tmp" "\$cmux_use_file"; } 2>/dev/null; then :; else
          die_message 1 useWriteFailed "\$cmux_use_file"
        fi
        ;;
      auto) rm -f "\$cmux_use_file" 2>/dev/null || die_message 1 useWriteFailed "\$cmux_use_file" ;;
    esac
  done
  # A Claude key or endpoint the caller exported itself outranks either mode.
  cmux_use_override=""
  if [ -n "\${ANTHROPIC_API_KEY:-}\${ANTHROPIC_BASE_URL:-}" ] && [ "\${ANTHROPIC_BASE_URL:-}" != "\${CMUX_CODEROUTER_URL:-}" ]; then cmux_use_override=1; fi
  # The account check reads the model-plane origin; a missing plane answers
  # "unknown", never an error, so the switch works offline.
  if [ -f "\$HOME/.config/cmux/model-plane.env" ] || [ -f /etc/cmux/model-plane.env ]; then load_model_env; fi
  # Report the current answer, and let the next launch see it too.
  rm -f "\$HOME/.cache/cmux/agent-access" 2>/dev/null || :
  cmux_use_sep=""
  [ "\$cmux_use_json" = false ] || printf '{"agents":['
  for cmux_use_agent in \$cmux_use_agents; do
    cmux_agent_auth_resolve "\$cmux_use_agent"
    if [ "\$cmux_use_json" = true ]; then
      printf '%s{"agent":"%s","mode":"%s","reason":"%s","chosen":%s}' "\$cmux_use_sep" "\$cmux_use_agent" "\$cmux_agent_auth_mode" "\$cmux_agent_auth_reason" \\
        "\$([ "\$cmux_agent_auth_reason" = chosen ] && echo true || echo false)"
      cmux_use_sep=,
      continue
    fi
    case "\$cmux_use_agent" in
      claude) cmux_use_name="Claude Code"; cmux_use_login="/login in Claude Code" ;;
      codex) cmux_use_name=Codex; cmux_use_login="codex login (codex login --device-auth without a browser)" ;;
      *) cmux_use_name=OpenCode; cmux_use_login="opencode auth login" ;;
    esac
    case "\$cmux_agent_auth_reason" in
      env) cmux_use_reason="\$(cmux_message useReasonEnv "CMUX_\$(printf '%s' "\$cmux_use_agent" | tr '[:lower:]' '[:upper:]')_AUTH")" ;;
      chosen) cmux_use_reason="\$(cmux_message useReasonChosen)" ;;
      login) cmux_use_reason="\$(cmux_message useReasonLogin)" ;;
      team-account) cmux_use_reason="\$(cmux_message useReasonTeamAccount)" ;;
      no-team-account) cmux_use_reason="\$(cmux_message useReasonNoTeamAccount)" ;;
      team-unreachable) cmux_use_reason="\$(cmux_message useReasonTeamUnreachable)" ;;
      *) cmux_use_reason="\$(cmux_message useReasonTeamUnknown)" ;;
    esac
    if [ "\$cmux_agent_auth_mode" = own ]; then
      cmux_message useModeOwn "\$cmux_use_name" "\$cmux_use_reason"
      [ "\$cmux_agent_auth_reason" = login ] || cmux_message useOwnLogin "\$cmux_use_login"
    else
      cmux_message useModeTeam "\$cmux_use_name" "\$cmux_use_reason"
      if [ "\$cmux_agent_auth_reason" = chosen ]; then
        if cmux_agent_team_access "\$cmux_use_agent"; then cmux_use_rc=0; else cmux_use_rc=\$?; fi
        [ "\$cmux_use_rc" -ne 1 ] || cmux_message useTeamNoAccount "\$cmux_use_name" "cr add \$cmux_use_agent" "\$cmux_use_agent"
      fi
    fi
    if [ "\$cmux_use_agent" = claude ] && [ -n "\$cmux_use_override" ]; then cmux_message useEnvOverride; fi
  done
  if [ "\$cmux_use_json" = true ]; then printf ']}\\n'; return 0; fi
  if [ -n "\$cmux_use_mode" ]; then cmux_message useNextLaunch; fi
}
`;
