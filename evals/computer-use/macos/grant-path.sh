#!/bin/bash
# grant-path.sh PATH... : Accessibility, Screen Recording, PostEvent, ListenEvent for binaries (cuev guests only)
SYS="/Library/Application Support/com.apple.TCC/TCC.db"; now=$(date +%s)
for c in "$@"; do
  for svc in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
    echo admin | sudo -S -p "" sqlite3 "$SYS" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier,flags,last_modified) VALUES ('$svc','$c',1,2,4,1,0,'UNUSED',0,$now);"
  done
  echo "granted $c"
done
echo admin | sudo -S -p "" killall tccd 2>/dev/null; true
