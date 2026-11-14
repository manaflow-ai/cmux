#!/bin/bash
# codex-thin.sh (CUEVAL_CODEX in the eval guest): the guest's codex, pointed at the team subrouter through
# the host relay (the guest is not on the tailnet), effort medium. The runner passes everything else
# (no sandbox or approvals, shell/patch/web/Codex CU plugin off, the arm's MCP server). No credentials here.
C=$HOME/.local/bin/codex
[[ $1 == exec ]] || exec "$C" "$@"
shift
exec "$C" exec -c 'model_reasoning_effort="medium"' \
  -c 'model_providers.subrouter.base_url="http://192.168.64.1:31415/v1"' "$@"
