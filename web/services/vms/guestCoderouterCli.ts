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
