#!/usr/bin/env bash
# perf100 inside an nx-remote GUI job on cmux-lawrence-2 (the app comes from the AWS fleet):
#
#   nx-remote --detach --needs gui --allow-agents --no-route --app-from-fleet cmux --tag <tag> --ref <sha> \
#     --timeout 7200 -- 'bash scripts/perf100/nx-job.sh [app=S0,S1,S2,S3,S4] [tui=S0,S1,S3,S4] [acpmux=10,100] [seed=1] [quick=1]'
#   nx-remote wait <job-id>        # results under artifacts/nx-remote/<job-id>/perf100/
#
# --allow-agents: S2 starts the replay stand-in agent (scripts/perf100/fixtures/replay_agent.py) in the
# app's acpmux; every other launch sets ACPMUX_AGENT_LAUNCH=deny itself, and every app runs on a scratch
# HOME with PATH /usr/bin:/bin:/usr/sbin:/sbin and ACPMUX_LOGIN_ENV=0, so no real agent CLI is found.
# The headless parts use the bundle's own cmux-tui and acpmux binaries on scratch roots.
set -uo pipefail
app_scenarios="S0,S1,S2,S3,S4"
tui_scenarios="S0,S1,S3,S4"
acpmux_sessions="10,100"
seed=1
quick=""
for arg in "$@"; do
  case "$arg" in
    app=*) app_scenarios="${arg#app=}" ;;
    tui=*) tui_scenarios="${arg#tui=}" ;;
    acpmux=*) acpmux_sessions="${arg#acpmux=}" ;;
    seed=*) seed="${arg#seed=}" ;;
    quick=1) quick="--quick" ;;
    *) echo "nx-job.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
: "${NX_APP:?run inside an nx-remote --app-from-fleet job}"
: "${NX_ARTIFACTS:?run inside an nx-remote job}"
cd "$(git rev-parse --show-toplevel)"
out="$NX_ARTIFACTS/perf100"
mkdir -p "$out"
sha="$(git rev-parse HEAD)"
py=/usr/bin/python3
[ -x "$py" ] || py=python3
common=(--seed "$seed" --out "$out" --tag "${NX_APP_TAG:-}" --sha "$sha" --host-class "${PERF100_HOST_CLASS:-cmux-lawrence-2}" $quick)
status=0
echo "PERF100-NX host=$(hostname -s) sha=$sha tag=${NX_APP_TAG:-} load=\"$(uptime | sed 's/.*load averages*: //')\" ptys_in_use=$(ls /dev | grep -c '^ttys[0-9]')"
if [ "$app_scenarios" != "none" ]; then
  "$py" scripts/perf100/perf100.py app --app "$NX_APP" --scenarios "$app_scenarios" --flood-timeout 1800 "${common[@]}" --md "$out/app.md" > "$out/app.log" 2>&1 || status=$?
  tail -n 5 "$out/app.log"
fi
bin="$NX_APP/Contents/Resources/bin"
# A short scratch parent: the daemons' socket paths must stay under the macOS sun_path limit.
scratch="$(mktemp -d /tmp/p100.XXXXXX)"
if [ "$tui_scenarios" != "none" ]; then
  "$py" scripts/perf100/perf100.py tui --tui "$bin/cmux-tui" --scenarios "$tui_scenarios" --root-dir "$scratch" --pty-budget 300 --pty-reserve 150 --flood-timeout 1800 "${common[@]}" --md "$out/tui.md" > "$out/tui.log" 2>&1 || status=$?
  tail -n 5 "$out/tui.log"
fi
if [ "$acpmux_sessions" != "none" ]; then
  "$py" scripts/perf100/perf100.py acpmux --acpmux "$bin/acpmux" --sessions "$acpmux_sessions" --root-dir "$scratch" "${common[@]}" --md "$out/acpmux.md" > "$out/acpmux.log" 2>&1 || status=$?
  tail -n 5 "$out/acpmux.log"
fi
rm -rf "$scratch"
"$py" scripts/perf100/perf100.py report "$out" --md "$out/perf100.md" > /dev/null
"$py" scripts/perf100/perf100.py budget --results "$out" --host-class "${PERF100_HOST_CLASS:-cmux-lawrence-2}" | tee "$out/budget.md" | tail -n 1
# The tagged app's leftovers (the scenarios quit every app they launched): nx-remote's own stop.
[ -n "${NX_APP_STOP:-}" ] && "$NX_APP_STOP" > /dev/null 2>&1
exit "$status"
