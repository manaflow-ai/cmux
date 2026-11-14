#!/bin/bash
# grant-aside.sh: TCC (Accessibility, Screen Recording, PostEvent, ListenEvent) for the Aside helper, daemon and CLI,
# by path and by bundle id, plus replayd capture approvals (cuev guests only, SIP off)
SYS="/Library/Application Support/com.apple.TCC/TCC.db"; now=$(date +%s); A=$HOME/aside
paths=("$A/Aside Computer Use.app/Contents/MacOS/aside-computer-use"
       "$A/home/runtime-computer-use/Aside Computer Use.app/Contents/MacOS/aside-computer-use"
       "$A/Aside Daemon.app/Contents/MacOS/aside-daemon" "$A/Aside CLI.app/Contents/MacOS/aside")
bids=(at.studio.AsideBrowser.computer-use at.studio.AsideBrowser.daemon at.studio.AsideBrowser.cli)
for svc in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
  for c in "${paths[@]}"; do
    echo admin | sudo -S -p "" sqlite3 "$SYS" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier,flags,last_modified) VALUES ('$svc','$c',1,2,4,1,0,'UNUSED',0,$now);"
  done
  for c in "${bids[@]}"; do
    echo admin | sudo -S -p "" sqlite3 "$SYS" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier,flags,last_modified) VALUES ('$svc','$c',0,2,4,1,0,'UNUSED',0,$now);"
  done
done
echo admin | sudo -S -p "" killall tccd 2>/dev/null
P=~/Library/Group\ Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist
/usr/bin/python3 - "$P" "${paths[@]}" "$A/Aside Computer Use.app" "$A/home/runtime-computer-use/Aside Computer Use.app" <<'PY'
import plistlib, sys, datetime, urllib.parse
path, clients = sys.argv[1], sys.argv[2:]
try: d = plistlib.load(open(path, "rb"))
except Exception: d = {}
now = datetime.datetime.now(datetime.timezone.utc)
keys = []
for c in clients:
    keys.append("file://" + urllib.parse.quote(c) + "/" if c.endswith(".app") else c)
for c in keys:
    d.setdefault(c, {}).update({"kScreenCaptureApprovalLastAlerted": now, "kScreenCaptureApprovalLastUsed": now,
        "kScreenCapturePrivacyHintDate": now + datetime.timedelta(days=365), "kScreenCapturePrivacyHintPolicy": 31536000,
        "kScreenCaptureAlertableUsageCount": 1})
plistlib.dump(d, open(path, "wb")); print("approved", len(keys))
PY
killall -u "$USER" replayd 2>/dev/null; true
echo admin | sudo -S -p "" sqlite3 "$SYS" "select service,client,auth_value from access where client like '%side%'" | wc -l
