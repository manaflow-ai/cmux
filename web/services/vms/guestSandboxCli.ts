// `cmux sandbox`: a cloud agent's own throwaway VMs through the cmux VM API
// (workers/cmux-vm, "Agent keys and client sessions"), with the agent key the
// Chief gave it: CMUX_AGENT_KEY, else ~/.config/cmux/agent.json (mode 0600).
// The key reaches only the VMs it created, within its budget, until it
// expires; the service then deletes them. No provider or team key is used.
export const GUEST_SANDBOX_SHELL = `# cmux sandbox: this agent's own throwaway VMs, through the cmux VM API with
# the agent key it was given (CMUX_AGENT_KEY, else ~/.config/cmux/agent.json,
# mode 0600). The key reaches only VMs it created, within its VM count and
# USD/h budget, until it expires; then the service deletes them. No provider
# or team credential is ever on this machine.
sandbox_usage() {
  cat <<'USAGE'
usage: cmux sandbox <command>
  create [--name NAME] [--vcpus N] [--memory-mib N] [--json]   start a VM; prints its id once it runs
  list [--json]                                                this agent's VMs
  exec <vm> [--user USER] [--timeout-ms N] -- <command...>      run a command, exit with its status
  token <vm> [--user USER]                                     a provider token for this VM only (JSON, shown once)
  delete <vm>                                                  delete a VM and revoke its tokens
  whoami                                                       the agent key's id, expiry and budget
Credential: CMUX_AGENT_KEY, else ~/.config/cmux/agent.json ({"key", "apiUrl"}).
USAGE
}

sandbox_config_file() { printf '%s\\n' "\${CMUX_AGENT_CONFIG:-\$HOME/.config/cmux/agent.json}"; }

sandbox_load() {
  cmux_sb_file="\$(sandbox_config_file)"
  cmux_sb_key="\${CMUX_AGENT_KEY:-}"
  cmux_sb_url="\${CMUX_VM_API_URL:-}"
  if [ -f "\$cmux_sb_file" ]; then
    # A key other users can read is a leaked key: refuse it rather than use it.
    cmux_sb_mode="\$(stat -c '%a' "\$cmux_sb_file" 2>/dev/null || stat -f '%Lp' "\$cmux_sb_file" 2>/dev/null || echo 600)"
    case "\$cmux_sb_mode" in
      600|400) ;;
      *) die "sandbox: \$cmux_sb_file must be mode 0600 (it is \$cmux_sb_mode); run: chmod 600 \$cmux_sb_file" 2 ;;
    esac
    [ -n "\$cmux_sb_key" ] || cmux_sb_key="\$(jq -r '.key // empty' "\$cmux_sb_file" 2>/dev/null)"
    [ -n "\$cmux_sb_url" ] || cmux_sb_url="\$(jq -r '.apiUrl // empty' "\$cmux_sb_file" 2>/dev/null)"
  fi
  [ -n "\$cmux_sb_key" ] || die "sandbox: no agent key (set CMUX_AGENT_KEY or write \$cmux_sb_file)" 2
  case "\$cmux_sb_key" in cmuxvm_sk_*) ;; *) die "sandbox: the agent key must start with cmuxvm_sk_" 2 ;; esac
  [ -n "\$cmux_sb_url" ] || cmux_sb_url="https://vm.cmux.dev"
  case "\$cmux_sb_url" in https://*) ;; *) die "sandbox: the API URL must be https://" 2 ;; esac
  cmux_sb_url="\${cmux_sb_url%/}"
}

# sandbox_api METHOD PATH [JSON]: the body on stdout; a non-2xx answer prints the
# service's message and returns its HTTP status class (4 for 4xx, 5 for 5xx).
sandbox_api() {
  cmux_sb_out="\$(mktemp)"
  if [ "\$#" -ge 3 ]; then
    cmux_sb_status="\$(printf '%s' "\$3" | curl -sS -o "\$cmux_sb_out" -w '%{http_code}' --connect-timeout 10 --max-time 330 \\
      -X "\$1" -H "authorization: Bearer \$cmux_sb_key" -H 'content-type: application/json' -H 'accept: application/json' \\
      \${cmux_sb_idem:+-H "idempotency-key: \$cmux_sb_idem"} --data-binary @- "\$cmux_sb_url\$2")" || { rm -f "\$cmux_sb_out"; die "sandbox: cannot reach \$cmux_sb_url" 1; }
  else
    cmux_sb_status="\$(curl -sS -o "\$cmux_sb_out" -w '%{http_code}' --connect-timeout 10 --max-time 60 \\
      -X "\$1" -H "authorization: Bearer \$cmux_sb_key" -H 'accept: application/json' "\$cmux_sb_url\$2")" || { rm -f "\$cmux_sb_out"; die "sandbox: cannot reach \$cmux_sb_url" 1; }
  fi
  case "\$cmux_sb_status" in
    2??) cat "\$cmux_sb_out"; rm -f "\$cmux_sb_out"; return 0 ;;
  esac
  cmux_sb_msg="\$(jq -r '.message // empty' "\$cmux_sb_out" 2>/dev/null)"
  rm -f "\$cmux_sb_out"
  printf 'cmux: sandbox: %s %s: HTTP %s%s\\n' "\$1" "\$2" "\$cmux_sb_status" "\${cmux_sb_msg:+: \$cmux_sb_msg}" >&2
  case "\$cmux_sb_status" in 4??) return 4 ;; *) return 5 ;; esac
}

sandbox_vm_id() {
  case "\${1:-}" in
    vm_*) printf '%s\\n' "\$1" ;;
    *) die "sandbox: expected a VM id (vm_...), got '\${1:-}'" 2 ;;
  esac
}

sandbox_command() {
  cmux_sb_sub="\${1:-help}"
  [ "\$#" -eq 0 ] || shift
  case "\$cmux_sb_sub" in
    help|--help|-h) sandbox_usage; return 0 ;;
  esac
  sandbox_load
  case "\$cmux_sb_sub" in
    create)
      cmux_sb_name=""; cmux_sb_cpu=""; cmux_sb_mem=""; cmux_sb_json=0
      while [ "\$#" -gt 0 ]; do
        case "\$1" in
          --name) [ "\$#" -ge 2 ] || die "sandbox create: --name needs a value" 2; cmux_sb_name="\$2"; shift 2 ;;
          --vcpus) [ "\$#" -ge 2 ] || die "sandbox create: --vcpus needs a value" 2; cmux_sb_cpu="\$2"; shift 2 ;;
          --memory-mib) [ "\$#" -ge 2 ] || die "sandbox create: --memory-mib needs a value" 2; cmux_sb_mem="\$2"; shift 2 ;;
          --json) cmux_sb_json=1; shift ;;
          *) die "sandbox create: unknown option \$1" 2 ;;
        esac
      done
      cmux_sb_body="\$(jq -cn --arg name "\$cmux_sb_name" --arg cpu "\$cmux_sb_cpu" --arg mem "\$cmux_sb_mem" '
        {} + (if \$name == "" then {} else {displayName: \$name} end)
           + (if \$cpu == "" and \$mem == "" then {} else {resources: ({} + (if \$cpu == "" then {} else {vcpus: (\$cpu | tonumber)} end) + (if \$mem == "" then {} else {memoryMib: (\$mem | tonumber)} end))} end)')" \\
        || die "sandbox create: --vcpus and --memory-mib take numbers" 2
      # One key per create: a lost answer retried with it never makes a second VM.
      cmux_sb_idem="sandbox-\$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')"
      cmux_sb_vm="\$(sandbox_api POST /v1/vms "\$cmux_sb_body")" || return \$?
      cmux_sb_idem=""
      cmux_sb_id="\$(printf '%s' "\$cmux_sb_vm" | jq -r '.id')"
      # Wait until it runs, so the next exec works (up to 3 minutes).
      cmux_sb_try=0
      while [ "\$(printf '%s' "\$cmux_sb_vm" | jq -r '.state')" != running ] && [ "\$cmux_sb_try" -lt 90 ]; do
        sleep 2
        cmux_sb_try=\$((cmux_sb_try + 1))
        cmux_sb_vm="\$(sandbox_api GET "/v1/vms/\$cmux_sb_id")" || return \$?
      done
      if [ "\$cmux_sb_json" = 1 ]; then printf '%s\\n' "\$cmux_sb_vm"; else printf '%s\\n' "\$cmux_sb_id"; fi
      ;;
    list|ls)
      cmux_sb_list="\$(sandbox_api GET /v1/vms)" || return \$?
      if [ "\${1:-}" = --json ]; then printf '%s\\n' "\$cmux_sb_list"; else
        printf '%s' "\$cmux_sb_list" | jq -r '.items[] | [.id, .state, (.displayName // "-")] | @tsv'
      fi
      ;;
    exec)
      cmux_sb_id="\$(sandbox_vm_id "\${1:-}")" || exit 2; shift
      cmux_sb_user=""; cmux_sb_timeout=""
      while [ "\$#" -gt 0 ]; do
        case "\$1" in
          --user) [ "\$#" -ge 2 ] || die "sandbox exec: --user needs a value" 2; cmux_sb_user="\$2"; shift 2 ;;
          --timeout-ms) [ "\$#" -ge 2 ] || die "sandbox exec: --timeout-ms needs a value" 2; cmux_sb_timeout="\$2"; shift 2 ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      [ "\$#" -gt 0 ] || die "usage: cmux sandbox exec <vm> [--user USER] -- <command...>" 2
      cmux_sb_body="\$(jq -cn --arg cmd "\$*" --arg user "\$cmux_sb_user" --arg t "\$cmux_sb_timeout" '
        {command: \$cmd} + (if \$user == "" then {} else {linuxUser: \$user} end) + (if \$t == "" then {} else {timeoutMs: (\$t | tonumber)} end)')" \\
        || die "sandbox exec: --timeout-ms takes a number" 2
      cmux_sb_res="\$(sandbox_api POST "/v1/vms/\$cmux_sb_id/exec" "\$cmux_sb_body")" || return \$?
      printf '%s' "\$cmux_sb_res" | jq -j '.stdout'
      printf '%s' "\$cmux_sb_res" | jq -j '.stderr' >&2
      cmux_sb_code="\$(printf '%s' "\$cmux_sb_res" | jq -r '.exitCode // 124')"
      return "\$cmux_sb_code"
      ;;
    token)
      cmux_sb_id="\$(sandbox_vm_id "\${1:-}")" || exit 2; shift
      cmux_sb_user=""
      if [ "\${1:-}" = --user ]; then [ "\$#" -ge 2 ] || die "sandbox token: --user needs a value" 2; cmux_sb_user="\$2"; fi
      cmux_sb_body="\$(jq -cn --arg user "\$cmux_sb_user" 'if \$user == "" then {} else {linuxUser: \$user} end')"
      sandbox_api POST "/v1/vms/\$cmux_sb_id/client-session" "\$cmux_sb_body"
      printf '\\n'
      ;;
    delete|rm)
      cmux_sb_id="\$(sandbox_vm_id "\${1:-}")" || exit 2
      sandbox_api DELETE "/v1/vms/\$cmux_sb_id" >/dev/null || return \$?
      printf 'OK deleted %s\\n' "\$cmux_sb_id"
      ;;
    whoami)
      if [ -f "\$cmux_sb_file" ]; then jq '{keyId, expiresAt, maxVms, maxUsdPerHour, labels, apiUrl}' "\$cmux_sb_file"; else
        printf '{"apiUrl":"%s"}\\n' "\$cmux_sb_url"
      fi
      ;;
    *) die "sandbox: unknown command \$cmux_sb_sub (see: cmux sandbox help)" 2 ;;
  esac
}
`;

/**
 * The same verbs as a standalone `cmux-sandbox` script, for agent hosts
 * without the driver-installed `cmux` shim (cloud subagent VMs: the hq pool
 * tool installs it as /usr/local/bin/cmux-sandbox).
 */
export const GUEST_SANDBOX_STANDALONE = `#!/bin/sh
# cmux-sandbox: generated from cmux web/services/vms/guestSandboxCli.ts; do not edit.
die() { printf '%s\\n' "cmux: \$1" >&2; exit "\${2:-1}"; }
${GUEST_SANDBOX_SHELL}
sandbox_command "\$@"
`;
