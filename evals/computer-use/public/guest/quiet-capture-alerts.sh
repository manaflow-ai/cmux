# quiet-capture-alerts.sh: the benchmark VM has no person to answer macOS's
# screen-capture privacy alerts ("...is requesting to bypass the system
# private window picker", and the monthly reminder). Mark every capture
# client of both arms as approved and alerted now, with the next reminder a
# year out, so no modal appears over either arm's tasks.
P=~/Library/Group\ Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist
mkdir -p "$(dirname "$P")"
clients=("file://$HOME/.codex/computer-use/Codex%20Computer%20Use.app/")
for d in ~/Library/Application\ Support/cmux/tags/*/remote/app/*/cmux\ Remote\ \(dev\).app; do
  [ -d "$d" ] && clients+=("file://$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$d")/")
done
for app in /Applications/cmux\ DEV*.app; do
  clients+=("$app/Contents/Resources/bin/cmux-tui" "file://$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$app")/")
done
python3 - "$P" "${clients[@]}" <<'PY'
import plistlib, sys, datetime, os
path, clients = sys.argv[1], sys.argv[2:]
try: d = plistlib.load(open(path, "rb"))
except Exception: d = {}
now = datetime.datetime.now(datetime.timezone.utc)
for c in clients:
    e = d.setdefault(c, {})
    e.update({"kScreenCaptureApprovalLastAlerted": now, "kScreenCaptureApprovalLastUsed": now,
              "kScreenCapturePrivacyHintDate": now + datetime.timedelta(days=365),
              "kScreenCapturePrivacyHintPolicy": 31536000, "kScreenCaptureAlertableUsageCount": 1})
plistlib.dump(d, open(path, "wb"))
print("approved", len(clients), "capture clients")
PY
killall -u "$USER" replayd 2>/dev/null; true
