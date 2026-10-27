#!/usr/bin/env bash
# Writes <app>/Contents/Resources/crash_reporter.cfg (p09-observability-105):
# with it, CEF starts Crashpad in every Chromium process
# (libcef/common/crash_reporter_client.cc ReadCrashConfigFile,
# libcef/common/crash_reporting.cc InitCrashReporter). There is never a
# ServerURL: Crashpad keeps each report in its local database and cmux forwards
# it redacted (ChromiumMinidumpForwarder).
#
# ProductVersion becomes every dump's "ver" annotation
# (components/crash/core/app/crashpad_mac.mm): "<version>+<build>
# cef<chromium>-<api>", so a dump sent at a later launch, often after an
# update, still names the cmux build that crashed.
#
# embed-cef.sh calls it for a Crashpad build (CMUX_NEXT_CEF_CRASHPAD=1) with the
# build's MARKETING_VERSION and CURRENT_PROJECT_VERSION; nightly.yml calls it
# again after it stamps the Nightly version into Info.plist, before signing.
#
# Usage: write-crash-reporter-cfg.sh <app> <version> <build>
set -euo pipefail

app="${1:?usage: write-crash-reporter-cfg.sh <app> <version> <build>}"
version="${2:?usage: write-crash-reporter-cfg.sh <app> <version> <build>}"
build="${3:?usage: write-crash-reporter-cfg.sh <app> <version> <build>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ChromiumMinidump keeps an annotation only when it is plain (letters, digits, ".", "-", "+", spaces).
for part in "$version" "$build"; do
  [[ "$part" =~ ^[0-9A-Za-z.-]+$ ]] || { echo "error: crash_reporter.cfg: version part '$part' is not plain" >&2; exit 1; }
done
cef_build="$(/usr/bin/python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); print(m["chromium"] + "-" + str(m.get("cmux_cef_api_version", 0)))' "$SCRIPT_DIR/cef-manifest.json")"

cfg="$app/Contents/Resources/crash_reporter.cfg"
mkdir -p "$app/Contents/Resources"
tmp_cfg="$(mktemp)"
cat > "$tmp_cfg" <<CFG
# Written by scripts/cmux-next/write-crash-reporter-cfg.sh (p09-observability-105).
# No ServerURL: Crashpad keeps reports on disk and never uploads them.
[Config]
ProductName=cmux-next
ProductVersion=$version+$build cef$cef_build
BrowserCrashForwardingEnabled=true
MaxDatabaseSizeInMb=50
MaxDatabaseAgeInDays=7
CFG
chmod 644 "$tmp_cfg"
if ! cmp -s "$tmp_cfg" "$cfg"; then mv "$tmp_cfg" "$cfg"; else rm -f "$tmp_cfg"; fi
