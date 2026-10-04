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
Build: --ref SHA --workspace URL --submitter LOGIN [--artifact-job JOB_ID] [--app PATH|--skip-build]
Capture: --out-root PATH --date YYYY-MM-DD --cua PATH --target APP
  --backdrop-manifest PATH  attributed JSON manifest (schema_version 1)
  --backdrop-root PATH      directory containing manifest image files
  --backdrop-id ID          choose one manifest entry (otherwise random)
  --wallpaper-remote-root PATH  host directory for the installed wallpaper
  --dry-run                   print the plan; no mkdir, SSH, CUA, or cmux-ci
EOF
}
die() { echo "showcase-capture: $*" >&2; exit 2; }
HOST=${CMUX_SHOWCASE_HOST:-}; TAG=${CMUX_SHOWCASE_TAG:-}; CHECKOUT=${CMUX_SHOWCASE_CHECKOUT:-}
REF=${CMUX_SHOWCASE_REF:-}; WORKSPACE_URL=${PR_URL:-${CMUX_SHOWCASE_WORKSPACE:-}}
SUBMITTER=${SUBMITTER:-${CMUX_SHOWCASE_SUBMITTER:-}}; ARTIFACT_JOB=${CMUX_SHOWCASE_ARTIFACT_JOB:-}; APP_PATH=${CMUX_SHOWCASE_APP:-}
OUT_ROOT=${CMUX_SHOWCASE_OUT_ROOT:-$HOME/Projects/cmux-app-screenshots}; CAPTURE_DATE=${CMUX_SHOWCASE_DATE:-}
CUA=${CMUX_CUA_SSH:-}; TARGET=${CMUX_SHOWCASE_TARGET:-}; LEASE_RECEIPT=${CMUX_SHOWCASE_LEASE_RECEIPT:-}
BACKDROP_MANIFEST=${CMUX_SHOWCASE_BACKDROP_MANIFEST:-}; BACKDROP_ROOT=${CMUX_SHOWCASE_BACKDROP_ROOT:-}
BACKDROP_ID=${CMUX_SHOWCASE_BACKDROP_ID:-}; WALLPAPER_REMOTE_ROOT=${CMUX_SHOWCASE_WALLPAPER_REMOTE_ROOT:-}
ADMISSION_COMMAND=${CMUX_SHOWCASE_ADMISSION_COMMAND:-}; WAIT_SECONDS=${CMUX_SHOWCASE_WAIT_SECONDS:-4}; DRY_RUN=0; SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
 case $1 in
 --host) HOST=${2:?}; shift 2;; --tag) TAG=${2:?}; shift 2;; --checkout) CHECKOUT=${2:?}; shift 2;;
 --ref) REF=${2:?}; shift 2;; --workspace) WORKSPACE_URL=${2:?}; shift 2;;
 --submitter) SUBMITTER=${2:?}; shift 2;; --artifact-job) ARTIFACT_JOB=${2:?}; shift 2;; --app) APP_PATH=${2:?}; shift 2;;
 --skip-build) SKIP_BUILD=1; shift;; --out-root) OUT_ROOT=${2:?}; shift 2;;
 --date) CAPTURE_DATE=${2:?}; shift 2;; --cua) CUA=${2:?}; shift 2;;
 --target) TARGET=${2:?}; shift 2;; --lease-receipt) LEASE_RECEIPT=${2:?}; shift 2;;
 --backdrop-manifest) BACKDROP_MANIFEST=${2:?}; shift 2;; --backdrop-root) BACKDROP_ROOT=${2:?}; shift 2;;
 --backdrop-id) BACKDROP_ID=${2:?}; shift 2;; --wallpaper-remote-root) WALLPAPER_REMOTE_ROOT=${2:?}; shift 2;;
 --admission-command) ADMISSION_COMMAND=${2:?}; shift 2;; --dry-run) DRY_RUN=1; shift;;
 -h|--help) usage; exit 0;; *) die "unknown option: $1";; esac
done
[[ ${TAG:-} =~ ^[A-Za-z0-9._-]+$ ]] || die "--tag is required and must be a safe tag"
[[ -n $HOST && -n $CHECKOUT ]] || die "--host and --checkout are required"
[[ -n ${CAPTURE_DATE} ]] || CAPTURE_DATE=$(date +%F)
[[ $CAPTURE_DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid --date: $CAPTURE_DATE"
[[ -n $TARGET ]] || TARGET="cmux DEV $TAG"; [[ -n $CUA ]] || CUA=$(command -v cua-ssh || true)
[[ -n $BACKDROP_MANIFEST ]] || BACKDROP_MANIFEST="$OUT_ROOT/backdrops/manifest.json"
[[ -n $BACKDROP_ROOT ]] || BACKDROP_ROOT=$(dirname "$BACKDROP_MANIFEST")
# shellcheck disable=SC2088
[[ -n $WALLPAPER_REMOTE_ROOT ]] || WALLPAPER_REMOTE_ROOT='~/Library/Application Support/cmux-showcase/backdrops'
ARCHIVE="$OUT_ROOT/captures/cmux-next-showcase/$CAPTURE_DATE"; RECEIPTS="$ARCHIVE/receipts"; STILL_ROOT="$ARCHIVE/stills"; REEL_ROOT="$ARCHIVE/reel"
if (( DRY_RUN )); then
 printf 'showcase-capture: dry run (no effects)\n  host=%s tag=%s target=%s checkout=%s\n  archive=%s\n  backdrop-manifest=%s\n  stills=01-main-rail 02-agent-chat-tools-footer 03-diff-viewer 04-inbox 05-sidebar 06-settings\n  reel=launch rail worked-turn inbox\n' "$HOST" "$TAG" "$TARGET" "$CHECKOUT" "$ARCHIVE" "$BACKDROP_MANIFEST"; exit 0
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
backdrop_selection=$(python3 - "$BACKDROP_MANIFEST" "$BACKDROP_ROOT" "$BACKDROP_ID" <<'PY'
import hashlib, json, pathlib, secrets, sys

manifest_path = pathlib.Path(sys.argv[1]).expanduser()
root = pathlib.Path(sys.argv[2]).expanduser().resolve()
requested_id = sys.argv[3]
try:
    document = json.loads(manifest_path.read_text())
except FileNotFoundError:
    raise SystemExit(f"backdrop manifest does not exist: {manifest_path}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"backdrop manifest is not JSON: {exc}")
if document.get("schema_version") != 1 or not isinstance(document.get("entries"), list):
    raise SystemExit("backdrop manifest must use schema_version 1 with an entries array")
entries = document["entries"]
if requested_id:
    entries = [entry for entry in entries if entry.get("id") == requested_id]
    if not entries:
        raise SystemExit(f"backdrop id not found: {requested_id}")
available = []
for entry in entries:
    if not isinstance(entry, dict):
        continue
    entry_id = entry.get("id")
    filename = entry.get("file")
    expected = entry.get("sha256")
    if not isinstance(entry_id, str) or not entry_id or not isinstance(filename, str) or not filename:
        continue
    if not isinstance(expected, str) or len(expected) != 64:
        continue
    if pathlib.PurePath(entry_id).name != entry_id:
        continue
    candidate = (root / filename).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        continue
    # Capture-only references may intentionally keep their source outside the
    # published backdrops directory. The manifest still records that source.
    if not candidate.is_file():
        source = entry.get("source_url")
        fallback = None
        if isinstance(source, str) and source.startswith("/"):
            fallback = pathlib.Path(source)
        elif isinstance(source, str) and source.startswith("local-reference:"):
            fallback = pathlib.Path.home() / "Projects" / source.removeprefix("local-reference:")
        if fallback is None or not fallback.is_file():
            continue
        candidate = fallback.resolve()
    actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"backdrop hash mismatch for {entry_id}: expected {expected}, got {actual}")
    available.append((entry, candidate, actual))
if not available:
    raise SystemExit("backdrop manifest has no available, hash-verified entries")
entry, path, actual = secrets.choice(available)
print(json.dumps({"entry": entry, "local_path": str(path), "sha256": actual}, separators=(",", ":")))
PY
) || die "backdrop selection failed"
BACKDROP_FILE=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["local_path"])' <<<"$backdrop_selection")
BACKDROP_SHA256=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])' <<<"$backdrop_selection")
BACKDROP_ENTRY_JSON=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["entry"], separators=(",",":")))' <<<"$backdrop_selection")
BACKDROP_ENTRY_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["entry"]["id"])' <<<"$backdrop_selection")
[[ $BACKDROP_ENTRY_ID =~ ^[A-Za-z0-9._-]+$ ]] || die "backdrop id is not safe: $BACKDROP_ENTRY_ID"
[[ ! -e $ARCHIVE ]] || die "capture archive already exists: $ARCHIVE (choose a new date or preserve and move it first)"
mkdir -p "$RECEIPTS" "$STILL_ROOT" "$REEL_ROOT"
cp "$LEASE_RECEIPT" "$RECEIPTS/controller-lease.json"
printf '%s\n' "$admission" > "$RECEIPTS/host-admission.json"
# SSH concatenates argv before the remote shell parses it. Quote the entire
# command for zsh -lc so spaces, apostrophes and JSON survive one shell layer.
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "zsh -lc $(printf '%q' "$1")"; }
cua() { "$CUA" "$@"; }
backdrop_suffix=${BACKDROP_FILE##*.}
[[ $backdrop_suffix =~ ^[A-Za-z0-9]+$ ]] || die "backdrop file extension is not safe: $backdrop_suffix"
backdrop_basename="$BACKDROP_ENTRY_ID-$BACKDROP_SHA256.$backdrop_suffix"
# shellcheck disable=SC2088
if [[ $WALLPAPER_REMOTE_ROOT == "~/"* ]]; then
  remote_root_expr="\\$HOME/${WALLPAPER_REMOTE_ROOT#~/}"
else
  remote_root_expr=$(printf '%q' "$WALLPAPER_REMOTE_ROOT")
fi
remote "mkdir -p $remote_root_expr"
REMOTE_BACKDROP_PATH=$(remote "printf '%s' $remote_root_expr/$backdrop_basename") || die "could not resolve host wallpaper path"
scp "$BACKDROP_FILE" "$HOST:$REMOTE_BACKDROP_PATH" || die "could not copy wallpaper to admitted host"
wallpaper_swift='import AppKit
import Foundation

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    for screen in NSScreen.screens {
        try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: [:])
    }
    print("set \(imageURL.path) on \(NSScreen.screens.count) screen(s)")
} catch {
    fputs("NSWorkspace wallpaper update failed: \(error)\n", stderr)
    exit(1)
}'
wallpaper_b64=$(printf '%s' "$wallpaper_swift" | base64 | tr -d '\n')
wallpaper_output=$(remote "printf '%s' $(printf '%q' "$wallpaper_b64") | /usr/bin/base64 -D | /usr/bin/swift - $(printf '%q' "$REMOTE_BACKDROP_PATH")" 2>&1) || die "could not set host wallpaper: $wallpaper_output"
readback_swift='import AppKit
for screen in NSScreen.screens {
    print(NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "")
}'
readback_b64=$(printf '%s' "$readback_swift" | base64 | tr -d '\n')
wallpaper_readback=$(remote "printf '%s' $(printf '%q' "$readback_b64") | /usr/bin/base64 -D | /usr/bin/swift -" 2>&1) || die "could not verify host wallpaper: $wallpaper_readback"
python3 - "$RECEIPTS/wallpaper.json" "$HOST" "$REMOTE_BACKDROP_PATH" "$BACKDROP_SHA256" "$BACKDROP_ENTRY_JSON" "$wallpaper_output" "$wallpaper_readback" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
data = {
    "host": sys.argv[2],
    "remote_path": sys.argv[3],
    "sha256": sys.argv[4],
    "entry": json.loads(sys.argv[5]),
    "setter": "NSWorkspace.setDesktopImageURL",
    "output": sys.argv[6],
    "readback": sys.argv[7],
}
path.write_text(json.dumps(data, indent=2) + "\n")
PY
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
if (( ! SKIP_BUILD )) && [[ -z $APP_PATH && -z $ARTIFACT_JOB ]]; then
 [[ -n $REF ]] || REF=$(git rev-parse HEAD); [[ $REF =~ ^[0-9a-f]{40}$ ]] || die "--ref must be a full pushed SHA"
 [[ -n $WORKSPACE_URL && -n $SUBMITTER ]] || die "--workspace and --submitter are required when building"
 job_json=$("$HOME/.local/bin/cmux-ci" build cmux --ref "$REF" --tag "$TAG" --workspace "$WORKSPACE_URL" --submitter "$SUBMITTER" --backend-mode local --receipt "$RECEIPTS/$REF-submit.json")
 printf '%s\n' "$job_json" > "$RECEIPTS/job.json"; ARTIFACT_JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$job_json")
 "$HOME/.local/bin/cmux-ci" wait "$ARTIFACT_JOB" --receipt "$RECEIPTS/$REF-terminal.json"
fi
if [[ -z $APP_PATH && -n $ARTIFACT_JOB ]]; then
 [[ $ARTIFACT_JOB =~ ^[a-f0-9]{24}$ ]] || die "--artifact-job must be a 24-character controller job id"
 remote "command -v cmux-ci >/dev/null || { echo 'cmux-ci is required on the capture mini for direct artifact pulls' >&2; exit 127; }"
 remote_dir='$HOME/cmux-showcase-runs/$TAG-$ARTIFACT_JOB'
 remote "mkdir -p $remote_dir/app"
 remote "cmux-ci artifact $(printf '%q' "$ARTIFACT_JOB") $remote_dir/app.zip"
 remote "ditto -x -k $remote_dir/app.zip $remote_dir/app"
 APP_PATH=$(remote "find $remote_dir/app -maxdepth 3 -name '*.app' -print -quit")
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
python3 - "$OUT_ROOT/captures/manifest.json" "$CAPTURE_DATE" "$ARCHIVE" "$TAG" "${REF:-}" "$HOST" "$REMOTE_BACKDROP_PATH" "$BACKDROP_SHA256" "$BACKDROP_ENTRY_JSON" "$wallpaper_readback" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); date,archive,tag,ref,host,remote_path,sha256,entry_json,readback=sys.argv[2:]; d=json.loads(p.read_text()) if p.exists() else {}
entry=json.loads(entry_json)
d.setdefault("apps",{})["cmux-next-showcase"]={"status":"complete","date":date,"tag":tag,"ref":ref or None,"path":str(pathlib.Path(archive).relative_to(p.parent.parent)),"screenshots":6,"reel":"reel/recording.mov","capture_method":"cmux-cua via cua-ssh on an admitted tagged fleet build","wallpaper":{"host":host,"remote_path":remote_path,"sha256":sha256,"attribution":entry,"readback":readback}}
d.setdefault("validation",{})["cmux-next-showcase"]={"dense_stills":["main-rail","agent-chat-tools-footer","diff-viewer","inbox","sidebar","settings"],"reel":"launch, rail, worked turn, inbox"}
p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,indent=2)+"\n")
PY
echo "showcase-capture: wrote $ARCHIVE"
