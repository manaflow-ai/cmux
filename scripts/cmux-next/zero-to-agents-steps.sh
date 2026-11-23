#!/bin/bash
# Steps 2 and 3 of .github/workflows/machine-zero-to-agents-e2e.yml, and its credential census: run by
# machine-join-e2e.ts (--bench) as the disposable user while its machine is joined to the development
# platform and its daemon runs.
#
#   zero-to-agents-steps.sh ACPMUX
#
# The workflow lays out the base (this script's parent's parent): bin/ (acpmux, cmux, bun, this script,
# credential-census.ts) and out/ (the user's own, outside the home the harness scans), where the census
# table and the step details go for the run summary.
#
# 2. GitHub: `cmux github setup` wires git's helper, then `cmux github credential get` asks for a
#    short-lived token for $REPO and, with one, `git ls-remote` reads the repo through the helper and the
#    API's token-expiration header gives the token's lifetime (expiry minus now). No `gh auth login`, no PAT.
# 3. Model: one prompt through the hub's inference gateway route (`<hub>/v1/models`, `/v1/responses`), the
#    route a joined machine's Codex and Claude take in team mode (acpmux joined_model_plane.rs), with the
#    machine's own join credential and no Claude or Codex login. The workflow runs the team's gateway (mode
#    `joined`) on the runner in front of the model stub (zero-to-agents-gateway.ts) and leaves the stub's nonce in
#    bin/model-stub-nonce: the reply must carry it, and with it a refusal fails instead of being a hand step.
# Then the census of this home (credential-census.ts), which must find nothing but the join's own files.
#
# Each step ends pass, fail or hand (a hand step remains: the product has no path for it on a joined machine
# today; its reason names what is missing). Nothing here prints a token or the credential: the credential is
# read into a shell variable and reaches curl on stdin only, and the GitHub token stays in git's and curl's
# own processes. The last line is one JSON object of numbers and plain strings, the harness's evidence.
set -uo pipefail

acpmux="$1"
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
bin="$base/bin"
out="$base/out"
cmux="$bin/cmux"
hub="https://cmux-platform-development.debussy.workers.dev"
# A repository the development team's GitHub App installation covers.
repo="manaflow-ai/cmux"
export PATH="$bin:/usr/local/bin:/usr/bin:/bin"
export GIT_TERMINAL_PROMPT=0
umask 077
mkdir -p "$out"
tmp="$(mktemp -d "$out/tmp.XXXXXX")"

now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# Plain characters only (the harness keeps [A-Za-z0-9 _.:/-], at most 128).
plain() { tr -c 'A-Za-z0-9 _.:/-' ' ' | tr -s ' ' | cut -c1-120 | sed 's/ *$//'; }

# ---- 2. GitHub through the product route ----
s2_start="$(now)"
s2_result=fail
s2_reason=""
s2_ttl=-1
s2_refs=0
setup_rc=0
"$cmux" github setup >"$tmp/gh-setup.out" 2>&1 || setup_rc=$?
cred_rc=0
printf 'protocol=https\nhost=github.com\npath=%s.git\n\n' "$repo" |
  "$cmux" github credential get >"$tmp/cred.out" 2>"$tmp/cred.err" || cred_rc=$?
if grep -q '^password=.' "$tmp/cred.out"; then
  # The token's lifetime: GitHub's expiration header on one API read with it (the token reaches curl on stdin).
  exp="$(sed -n 's/^password=//p' "$tmp/cred.out" | head -1 |
    { IFS= read -r t; printf 'header = "Authorization: token %s"\n' "$t"; } |
    curl -sS -K - -o /dev/null -D - --max-time 30 "https://api.github.com/repos/$repo" 2>/dev/null |
    tr -d '\r' | sed -n 's/^[Gg]it[Hh]ub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *//p' | head -1)"
  rm -f "$tmp/cred.out"
  if [ -n "$exp" ] && e="$(date -d "$exp" +%s 2>/dev/null)"; then s2_ttl=$((e - $(date +%s))); fi
  # One real read through git's own helper (the token lives only in git and the helper).
  if refs="$(git -c credential.helper= -c "credential.https://github.com.helper=!$cmux github credential" \
    -c credential.https://github.com.useHttpPath=true ls-remote "https://github.com/$repo" HEAD 2>"$tmp/ls.err")"; then
    s2_refs="$(printf '%s\n' "$refs" | grep -c . || true)"
    if [ "$s2_refs" -ge 1 ]; then s2_result=pass; s2_reason="git ls-remote read $repo with a minted token"; else s2_reason="ls-remote returned no refs"; fi
  else
    s2_reason="git ls-remote failed: $(tail -1 "$tmp/ls.err" | plain)"
  fi
else
  rm -f "$tmp/cred.out"
  code="$(grep -oE '\[[a-z_]+\.[a-z_]+\]' "$tmp/cred.err" | tail -1 | tr -d '[]')"
  if [ "$code" = vm.agent_unreachable ]; then
    # github_cli.rs asks only the Cloud VM agent's socket; a joined machine has none.
    s2_result=hand
    s2_reason="hand step remains: cmux github credential get answered vm.agent_unreachable: no /run/cmux-vm-agent/agent.sock on a joined machine"
  else
    s2_reason="credential get refused: ${code:-no code} exit $cred_rc"
  fi
fi
s2_secs="$(secs "$s2_start" "$(now)")"
{
  echo "setup exit $setup_rc"
  echo "credential get exit $cred_rc; stderr:"
  sed -e 's/::/: :/g' -e 's/##\[/## [/g' "$tmp/cred.err" | cut -c1-300 | head -8
} >"$out/step2.txt"

# ---- 3. One prompt through the team's inference gateway, with the machine's own credential ----
s3_start="$(now)"
s3_result=fail
s3_reason=""
s3_model=""
s3_ttl=-1
credfile="$HOME/.acpmux/machine-credential.json"
cred="$(jq -r '.credential // empty' "$credfile" 2>/dev/null)"
# The nonce of the model stub behind the workflow's gateway (bin/model-stub-nonce, root's, not a secret): the reply
# must carry it. Without the file (no gateway was started) any reply counts.
nonce="$(tr -cd 'A-Za-z0-9' <"$bin/model-stub-nonce" 2>/dev/null | cut -c1-32)"
# `cmux inference setup` is the Cloud machine's path; it takes a vm_ id only (inference_setup.rs), so a joined
# machine's equivalent is the hub route below. Its answer for this machine is kept in the step details.
s3_machine="$(jq -r '.machine_id // empty' "$credfile" 2>/dev/null | tr -cd 'A-Za-z0-9_-')"
setup3_rc=0
"$cmux" inference setup --machine "${s3_machine:-none}" --path auto --api "$hub" --token-file /dev/null \
  >"$tmp/setup3.out" 2>&1 </dev/null || setup3_rc=$?
call() { # METHOD PATH [BODYFILE] -> http code; body in $tmp/resp.json
  local extra=()
  [ -n "${3:-}" ] && extra=(-H 'content-type: application/json' --data-binary "@$3")
  printf 'header = "x-cmux-inference-authorization: Bearer %s"\n' "$cred" |
    curl -sS -K - -X "$1" "${extra[@]}" -o "$tmp/resp.json" -w '%{http_code}' --max-time 120 "$hub$2" 2>"$tmp/curl.err"
}
if [ -z "$cred" ]; then
  s3_reason="no join credential on the machine"
else
  # The machine credential's own lifetime, when its record says (expiry minus now).
  exp="$(jq -r '.expires_at // .expiresAt // empty' "$credfile" 2>/dev/null)"
  if [ -n "$exp" ] && e="$(date -d "$exp" +%s 2>/dev/null || { [[ "$exp" =~ ^[0-9]+$ ]] && echo "$exp"; })"; then
    [ "$e" -gt 100000000000 ] && e=$((e / 1000))
    s3_ttl=$((e - $(date +%s)))
  fi
  models_code="$(call GET /v1/models)"
  if [ "$models_code" = 200 ]; then
    s3_model="$(jq -r '[.data[]?.id] | map(select(test("^[A-Za-z0-9._:/-]+$"))) | .[0] // empty' "$tmp/resp.json" 2>/dev/null)"
    # One tool offered, as an agent's turn offers its tools: the model stub answers a request with none as a side
    # request ("Stub side reply."), and a turn with its nonce.
    jq -n --arg m "${s3_model:-gpt-5}" '{model: $m, input: "Reply with exactly the word pong.", max_output_tokens: 32,
      tools: [{type: "function", name: "noop", description: "does nothing", parameters: {type: "object", properties: {}}}]}' >"$tmp/req.json"
    resp_code="$(call POST /v1/responses "$tmp/req.json")"
    text="$(jq -r '[.output[]?.content[]?.text? // empty] | join(" ")' "$tmp/resp.json" 2>/dev/null | plain)"
    if [ "$resp_code" = 200 ] && [ -n "$text" ] && [ -n "$nonce" ] && [[ "$text" != *"$nonce"* ]]; then
      # The workflow's gateway sits in front of the model stub with this nonce: any other reply came from elsewhere.
      s3_reason="a reply without the gateway stub's nonce: $(printf '%s' "$text" | cut -c1-40)"
    elif [ "$resp_code" = 200 ] && [ -n "$text" ]; then
      s3_result=pass
      s3_reason="answered through the hub gateway route: $(printf '%s' "$text" | cut -c1-40)"
    else
      ecode="$(jq -r '.error.code // .error.type // empty' "$tmp/resp.json" 2>/dev/null | plain)"
      s3_reason="responses HTTP $resp_code ${ecode}"
    fi
  else
    ecode="$(jq -r '.error.code // .error.type // empty' "$tmp/resp.json" 2>/dev/null | plain)"
    s3_reason="models HTTP $models_code ${ecode}"
  fi
  if [ "$s3_result" != pass ] && [ -n "$nonce" ]; then
    # The workflow started a gateway for joined machines: a refusal now is a failure, never a hand step.
    s3_reason="$s3_reason (with the run's gateway online)"
  else
    case "$s3_result:$s3_reason" in
      pass:*) ;;
      # The route answered but the team has no gateway serving joined machines: nothing on this machine is missing.
      *gateway* | *offline* | *not_configured* | *unavailable* | *" 503"* | *" 404"*)
        s3_result=hand
        s3_reason="hand step remains: $s3_reason: the test team has no inference gateway online for joined machines"
        ;;
    esac
  fi
fi
unset cred
s3_secs="$(secs "$s3_start" "$(now)")"
{
  echo "models HTTP ${models_code:-none}; responses HTTP ${resp_code:-none}; model ${s3_model:-none}; stub nonce ${nonce:-none}"
  echo "cmux inference setup --machine ${s3_machine:-none} --path auto: exit $setup3_rc: $(head -1 "$tmp/setup3.out" | cut -c1-160)"
  sed -e 's/::/: :/g' "$tmp/curl.err" 2>/dev/null | cut -c1-200 | head -3
} >"$out/step3.txt"
rm -rf "$tmp"

# ---- Census of this home ----
census_rc=0
bun "$bin/credential-census.ts" --root "$HOME" --json "$out/census.json" --markdown "$out/census.md" >/dev/null 2>"$out/census.err" || census_rc=$?
foreign="$(jq -r '.foreign // -1' "$out/census.json" 2>/dev/null || echo -1)"
found="$(jq -r '.rows | length' "$out/census.json" 2>/dev/null || echo -1)"

jq -cn \
  --arg s2 "$s2_result" --arg s2r "$(printf '%s' "$s2_reason" | plain)" --argjson s2s "$s2_secs" --argjson s2t "$s2_ttl" --argjson s2refs "${s2_refs:-0}" \
  --arg s3 "$s3_result" --arg s3r "$(printf '%s' "$s3_reason" | plain)" --argjson s3s "$s3_secs" --argjson s3t "$s3_ttl" --arg s3m "$(printf '%s' "$s3_model" | plain)" \
  --argjson crc "$census_rc" --argjson cf "$foreign" --argjson cn "$found" \
  '{github_result: $s2, github_reason: $s2r, github_seconds: $s2s, github_token_ttl_s: $s2t, github_refs: $s2refs,
    model_result: $s3, model_reason: $s3r, model_seconds: $s3s, machine_credential_ttl_s: $s3t, model: $s3m,
    census_exit: $crc, census_foreign: $cf, census_found: $cn}'
# A step that failed outright (not a hand step) or a foreign credential fails the run.
[ "$s2_result" != fail ] && [ "$s3_result" != fail ] && [ "$census_rc" = 0 ]
