#!/usr/bin/env bash
set -euo pipefail
# Capture the cmux-next showcase on an admitted fleet Mac. cmux-ci owns
# compilation, the tag-bound debug CLI owns profile seeding, and cua-ssh owns
# every visible GUI operation.
usage() { cat <<'EOF'
Usage: showcase-capture.sh [options]
Required for a live capture: --host HOST --tag TAG --checkout PATH
  --lease-receipt PATH       controller receipt proving the host reservation
  --admission-command CMD    command returning JSON {"admitted":true,"owner":...}
Build: --ref SHA --workspace URL --submitter LOGIN [--app PATH|--skip-build]
Capture: --out-root PATH --date YYYY-MM-DD --cua PATH --target APP
  --dry-run                   print the plan; no mkdir, SSH, CUA, or cmux-ci
EOF
}
die() { echo "showcase-capture: $*" >&2; exit 2; }
HOST=${CMUX_SHOWCASE_HOST:-}; TAG=${CMUX_SHOWCASE_TAG:-}; CHECKOUT=${CMUX_SHOWCASE_CHECKOUT:-}
REF=${CMUX_SHOWCASE_REF:-}; WORKSPACE_URL=${PR_URL:-${CMUX_SHOWCASE_WORKSPACE:-}}
SUBMITTER=${SUBMITTER:-${CMUX_SHOWCASE_SUBMITTER:-}}; APP_PATH=${CMUX_SHOWCASE_APP:-}
OUT_ROOT=${CMUX_SHOWCASE_OUT_ROOT:-$HOME/Projects/cmux-app-screenshots}; CAPTURE_DATE=${CMUX_SHOWCASE_DATE:-}
CUA=${CMUX_CUA_SSH:-}; TARGET=${CMUX_SHOWCASE_TARGET:-}; LEASE_RECEIPT=${CMUX_SHOWCASE_LEASE_RECEIPT:-}
ADMISSION_COMMAND=${CMUX_SHOWCASE_ADMISSION_COMMAND:-}; WAIT_SECONDS=${CMUX_SHOWCASE_WAIT_SECONDS:-4}; DRY_RUN=0; SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
 case $1 in
 --host) HOST=${2:?}; shift 2;; --tag) TAG=${2:?}; shift 2;; --checkout) CHECKOUT=${2:?}; shift 2;;
 --ref) REF=${2:?}; shift 2;; --workspace) WORKSPACE_URL=${2:?}; shift 2;;
 --submitter) SUBMITTER=${2:?}; shift 2;; --app) APP_PATH=${2:?}; shift 2;;
 --skip-build) SKIP_BUILD=1; shift;; --out-root) OUT_ROOT=${2:?}; shift 2;;
 --date) CAPTURE_DATE=${2:?}; shift 2;; --cua) CUA=${2:?}; shift 2;;
 --target) TARGET=${2:?}; shift 2;; --lease-receipt) LEASE_RECEIPT=${2:?}; shift 2;;
 --admission-command) ADMISSION_COMMAND=${2:?}; shift 2;; --dry-run) DRY_RUN=1; shift;;
 -h|--help) usage; exit 0;; *) die "unknown option: $1";; esac
done
[[ ${TAG:-} =~ ^[A-Za-z0-9._-]+$ ]] || die "--tag is required and must be a safe tag"
[[ -n $HOST && -n $CHECKOUT ]] || die "--host and --checkout are required"
[[ -n ${CAPTURE_DATE} ]] || CAPTURE_DATE=$(date +%F)
[[ $CAPTURE_DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid --date: $CAPTURE_DATE"
[[ -n $TARGET ]] || TARGET="cmux DEV $TAG"; [[ -n $CUA ]] || CUA=$(command -v cua-ssh || true)
ARCHIVE="$OUT_ROOT/captures/cmux-next-showcase/$CAPTURE_DATE"; RECEIPTS="$ARCHIVE/receipts"; STILL_ROOT="$ARCHIVE/stills"; REEL_ROOT="$ARCHIVE/reel"
if (( DRY_RUN )); then
 printf 'showcase-capture: dry run (no effects)\n  host=%s tag=%s target=%s checkout=%s\n  archive=%s\n  stills=01-main-rail 02-agent-chat-tools-footer 03-diff-viewer 04-inbox 05-sidebar 06-settings\n  reel=launch rail worked-turn inbox\n' "$HOST" "$TAG" "$TARGET" "$CHECKOUT" "$ARCHIVE"; exit 0
fi
[[ -f $LEASE_RECEIPT ]] || die "--lease-receipt must name an existing controller receipt"
[[ -n $ADMISSION_COMMAND ]] || die "--admission-command is required for live capture"
[[ -x $CUA ]] || die "cua-ssh not executable: $CUA"
[[ -x $HOME/.local/bin/cmux-ci ]] || { (( SKIP_BUILD )) || die "cmux-ci is required"; }
admission=$(bash -c "$ADMISSION_COMMAND") || die "admission command failed"
python3 - "$admission" <<'PY' || die "host is not admitted by the controller"
import json, sys
d=json.loads(sys.argv[1])
if d.get("admitted") is not True or not d.get("owner"): raise SystemExit(1)
PY
[[ ! -e $ARCHIVE ]] || die "capture archive already exists: $ARCHIVE (choose a new date or preserve and move it first)"
mkdir -p "$RECEIPTS" "$STILL_ROOT" "$REEL_ROOT"
cp "$LEASE_RECEIPT" "$RECEIPTS/controller-lease.json"
printf '%s\n' "$admission" > "$RECEIPTS/host-admission.json"
# SSH concatenates argv before the remote shell parses it. Quote the entire
# command for zsh -lc so spaces, apostrophes and JSON survive one shell layer.
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "zsh -lc $(printf '%q' "$1")"; }
cua() { "$CUA" "$@"; }
# Use the exact artifact's bundled CLI. The debug helper searches only local
# DerivedData/tag-cache paths and cannot find an app unpacked from an artifact.
cli() {
  local args="" arg
  for arg in "$@"; do args+=" $(printf '%q' "$arg")"; done
  remote "env -i HOME=\"\$HOME\" USER=\"\$USER\" PATH=/usr/bin:/bin TMPDIR=\"\\${TMPDIR:-/tmp}\" CMUX_SOCKET_PATH=$(printf '%q' "/tmp/cmux-debug-$TAG.sock") CMUX_TAG=$(printf '%q' "$TAG") $(printf '%q' "$APP_PATH/Contents/Resources/bin/cmux")$args"
}
seed() { cli rpc debug.showcase.seed '{"focus":true}'; }
seed_worked_turn() { cli rpc debug.agent_pane '{"action":"seed_rows","fixture":"worked-turn"}'; }
still() { local n=$1; mkdir -p "$STILL_ROOT/$n"; cua state "$HOST" "$TARGET" --out "$STILL_ROOT/$n" --quiet; [[ -s "$STILL_ROOT/$n/screenshot.png" && -s "$STILL_ROOT/$n/state.json" ]] || die "incomplete still: $n"; }
surface() { local n=$1 action=$2; cli action run "$action" --focus; sleep 1; still "$n"; }
socket_action() { cli action run "$1" --focus; sleep 1; }
if (( ! SKIP_BUILD )) && [[ -z $APP_PATH ]]; then
 [[ -n $REF ]] || REF=$(git rev-parse HEAD); [[ $REF =~ ^[0-9a-f]{40}$ ]] || die "--ref must be a full pushed SHA"
 [[ -n $WORKSPACE_URL && -n $SUBMITTER ]] || die "--workspace and --submitter are required when building"
 job_json=$("$HOME/.local/bin/cmux-ci" build cmux --ref "$REF" --tag "$TAG" --workspace "$WORKSPACE_URL" --submitter "$SUBMITTER" --backend-mode local --receipt "$RECEIPTS/$REF-submit.json")
 printf '%s\n' "$job_json" > "$RECEIPTS/job.json"; job_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$job_json")
 "$HOME/.local/bin/cmux-ci" wait "$job_id" --receipt "$RECEIPTS/$REF-terminal.json"; "$HOME/.local/bin/cmux-ci" artifact "$job_id" "$RECEIPTS/cmux-$TAG.zip"
 remote "mkdir -p ~/cmux-showcase-runs/$(printf '%q' "$TAG-$REF")/app"; scp "$RECEIPTS/cmux-$TAG.zip" "$HOST:~/cmux-showcase-runs/$TAG-$REF/app.zip"
 remote "ditto -x -k ~/cmux-showcase-runs/$(printf '%q' "$TAG-$REF")/app.zip ~/cmux-showcase-runs/$(printf '%q' "$TAG-$REF")/app"
 APP_PATH=$(remote "find ~/cmux-showcase-runs/$(printf '%q' "$TAG-$REF")/app -maxdepth 3 -name '*.app' -print -quit")
fi
[[ -n $APP_PATH ]] || die "no tagged app; pass --app or build"
remote "test -x $(printf '%q' "$APP_PATH/Contents/Resources/bin/cmux") && open -n $(printf '%q' "$APP_PATH") --env CMUX_NEXT_SHOWCASE=1 --env CMUX_TAG=$(printf '%q' "$TAG") --env CMUX_NEXT_SOCKET_MODE=automation --args --showcase"
sleep "$WAIT_SECONDS"; seed; seed_worked_turn; sleep "$WAIT_SECONDS"; still 01-main-rail
still 02-agent-chat-tools-footer
cli rpc debug.agent_pane '{"action":"open_changes"}'
sleep 1; still 03-diff-viewer
surface 04-inbox feed.show; surface 05-sidebar toggleSidebar
surface 06-settings openSettings
record_id="cmux-next-showcase-$CAPTURE_DATE-$TAG"; cua record-start "$HOST" --id "$record_id" --cursor --clicks
remote "open -n $(printf '%q' "$APP_PATH") --env CMUX_NEXT_SHOWCASE=1 --env CMUX_TAG=$(printf '%q' "$TAG") --env CMUX_NEXT_SOCKET_MODE=automation --args --showcase"; sleep "$WAIT_SECONDS"
cua state "$HOST" "$TARGET" --out "$REEL_ROOT/01-launch" --quiet; seed; seed_worked_turn; sleep 1; cua state "$HOST" "$TARGET" --out "$REEL_ROOT/02-rail" --quiet
seed; seed_worked_turn; cua state "$HOST" "$TARGET" --out "$REEL_ROOT/03-worked-turn" --quiet; socket_action feed.show
cua state "$HOST" "$TARGET" --out "$REEL_ROOT/04-inbox" --quiet; cua record-end "$HOST" "$record_id" --out "$REEL_ROOT"; [[ -s "$REEL_ROOT/recording.mov" && -s "$REEL_ROOT/meta.json" && -s "$REEL_ROOT/events.jsonl" ]] || die "recording metadata missing"
python3 - "$OUT_ROOT/captures/manifest.json" "$CAPTURE_DATE" "$ARCHIVE" "$TAG" "${REF:-}" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); date,archive,tag,ref=sys.argv[2:]; d=json.loads(p.read_text()) if p.exists() else {}
d.setdefault("apps",{})["cmux-next-showcase"]={"status":"complete","date":date,"tag":tag,"ref":ref or None,"path":str(pathlib.Path(archive).relative_to(p.parent.parent)),"screenshots":6,"reel":"reel/recording.mov","capture_method":"cmux-cua via cua-ssh on an admitted tagged fleet build"}
d.setdefault("validation",{})["cmux-next-showcase"]={"dense_stills":["main-rail","agent-chat-tools-footer","diff-viewer","inbox","sidebar","settings"],"reel":"launch, rail, worked turn, inbox"}
p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,indent=2)+"\n")
PY
echo "showcase-capture: wrote $ARCHIVE"
