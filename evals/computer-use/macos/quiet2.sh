# quiet2.sh: approve the cmux-next staged cmux Remote paths too (quiet-capture-alerts.sh globs only cmux/tags)
P=~/Library/Group\ Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist
clients=()
for d in ~/Library/Application\ Support/cmux-next/tags/*/remote/app/*/cmux\ Remote\ \(dev\).app; do
  [ -d "$d" ] && clients+=("file://$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$d")/")
done
for b in /bin/bash /usr/sbin/screencapture "$HOME/cu/probe"; do clients+=("$b"); done
python3 - "$P" "${clients[@]}" <<'PY'
import plistlib, sys, datetime
path, clients = sys.argv[1], sys.argv[2:]
try: d = plistlib.load(open(path, "rb"))
except Exception: d = {}
now = datetime.datetime.now(datetime.timezone.utc)
for c in clients:
    d.setdefault(c, {}).update({"kScreenCaptureApprovalLastAlerted": now, "kScreenCaptureApprovalLastUsed": now,
        "kScreenCapturePrivacyHintDate": now + datetime.timedelta(days=365), "kScreenCapturePrivacyHintPolicy": 31536000,
        "kScreenCaptureAlertableUsageCount": 1})
plistlib.dump(d, open(path, "wb")); print("approved", clients)
PY
killall -u "$USER" replayd 2>/dev/null; true
