# Cloud Chief first-token latency: options (design note, not started)

Status 2026-10-26 (a664). Setup overlap 8621b404a2d is in production (backend.yml run 40257849238, Worker version f7a70836).
No prod run-record marks were read yet: the marks (`vm`, `vm_ready`, `submit`, `request`, `first_token`, in `cb_marks`/`cb_timing`,
served by `GET /v1/chiefs/<agent>/runs`) need the owner's session, which the deploy agent did not have. Numbers below are
therefore NOT measured for the cloud; only the local baseline is.

## Where a turn spends time (from `ccAttempt`, turn.ts)
fresh VM create -> tailnet key + boot.sh join -> tools/net script + attachments -> start.sh -> `claude -p` cold start -> model request -> first token.
Every turn pays all of it; the VM is deleted after the turn.

## Baseline (measured, local Chief, `cmux chief usage --since 24h`, 59 turns)
start p50 0.67 s / p95 1.0 s; first token p50 4.4 s / p95 14.1 s; whole turn p50 11 s / p95 46.8 s.
Cloud target: first token within ~2x of local.

## Options
1. Overlap setup (shipped): removes the serial key/token/GitHub/tool-file/network round trips. Expected saving: 1-3 round trips (hundreds of ms to ~1-2 s); unmeasured.
2. Pre-create on message arrival: start create+key+boot when the inbox row lands (before the turn is admitted/compacted/prompt built). Hides most of VM create + join behind work the Worker does anyway. Keeps one-VM-per-turn isolation. Cost: a wasted VM when the message needs no turn (cap by only pre-creating for messages that will start a turn). Medium effort.
3. Warm VM per Chief + `claude --resume`: keep one VM per Chief, paused/idle-suspended between turns, resume the Claude session (`--resume <session>`), skip create/join/setup entirely. Biggest win (setup cost -> resume cost), also keeps prompt cache. Cost: breaks per-turn VM isolation (one tenant, so acceptable per Chief but needs wipe/health rules), idle VM billing, session-file persistence, eviction handling. Highest effort.

Recommendation: measure the five marks on 10+ prod turns first (needs owner session), then ship option 2; do option 3 only if `vm`+`vm_ready` is still > ~40% of first-token time.
