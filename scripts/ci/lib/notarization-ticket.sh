#!/usr/bin/env bash
# Architecture-aware checks supplement stapler's ticket validation. A ticket
# found by the host's CDHash can belong to a thin copy of a universal helper.

CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
LIPO_TOOL="${CMUX_LIPO_TOOL:-lipo}"

# Prints arch=CDHash for every slice. Capture command results explicitly: a
# failing process substitution would otherwise let an empty slice set pass.
slice_cdhashes() {
  local bundle="$1" executable architectures arch output hash
  executable="$(python3 - "$bundle" <<'PY'
import pathlib, plistlib, sys
bundle = pathlib.Path(sys.argv[1])
with (bundle / 'Contents/Info.plist').open('rb') as handle:
    name = plistlib.load(handle)['CFBundleExecutable']
if not name or pathlib.Path(name).name != name:
    sys.exit('Invalid CFBundleExecutable')
print(bundle / 'Contents/MacOS' / name)
PY
  )" || return 1
  architectures="$("$LIPO_TOOL" -archs "$executable")" || return 1
  if [ -z "$architectures" ]; then
    echo "error: no architectures found in $executable" >&2
    return 1
  fi
  architectures="$(printf '%s\n' "$architectures" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  if [ -z "$architectures" ]; then
    echo "error: empty architecture list for $executable" >&2
    return 1
  fi
  while IFS= read -r arch; do
    output="$("$CODESIGN_TOOL" -d -a "$arch" --verbose=4 "$bundle" 2>&1)" || {
      printf '%s\n' "$output" >&2
      return 1
    }
    hash="$(printf '%s\n' "$output" | sed -n 's/^CDHash=//p')"
    if ! [[ "$hash" =~ ^[0-9a-f]{40}$ ]]; then
      echo "error: invalid $arch CDHash for $bundle: $hash" >&2
      return 1
    fi
    printf '%s=%s\n' "$arch" "$hash"
  done <<< "$architectures"
}

# Info.plist is hashed into each slice's CodeDirectory. A new nonce before
# signing separates submissions across variants, channels, and reruns without
# changing the helper's bundle identifier or designated requirement.
isolate_helper_submission() {
  python3 - "$1/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys, uuid
path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
info = plistlib.loads(data)
info['CMUXNotarizationSubmission'] = str(uuid.uuid4())
fmt = plistlib.FMT_BINARY if data.startswith(b'bplist00') else plistlib.FMT_XML
path.write_bytes(plistlib.dumps(info, fmt=fmt))
PY
}

verify_ticket_contents_cover_slices() {
  local log_file="$1" bundle="$2" slices
  slices="$(slice_cdhashes "$bundle")" || return 1
  python3 - "$log_file" "$bundle" "$slices" <<'PY'
import json, sys
log_file, bundle, slices = sys.argv[1:]
with open(log_file) as handle:
    log = json.load(handle)
if log.get('status') != 'Accepted':
    sys.exit(f'error: notarization log is not Accepted: {bundle}')
covered = {(entry.get('arch'), entry.get('cdhash')) for entry in log.get('ticketContents') or []}
for line in slices.splitlines():
    arch, cdhash = line.split('=', 1)
    if (arch, cdhash) not in covered:
        sys.exit(f'error: accepted ticket is missing {arch} CDHash {cdhash}: {bundle}')
    print(f'accepted ticket covers {arch} CDHash {cdhash}: {bundle}')
PY
}

# stapler validate remains mandatory to authenticate the ticket. This extra
# membership check catches a valid thin ticket attached to a universal bundle;
# it does not attempt to replace Apple's signature/ticket verification.
verify_stapled_ticket_covers_slices() {
  local bundle="$1" slices
  slices="$(slice_cdhashes "$bundle")" || return 1
  python3 - "$bundle" "$slices" <<'PY'
import pathlib, sys
bundle, slices = sys.argv[1:]
ticket = pathlib.Path(bundle) / 'Contents/CodeResources'
if not ticket.is_file():
    sys.exit(f'error: no stapled ticket: {bundle}')
data = ticket.read_bytes()
for line in slices.splitlines():
    arch, cdhash = line.split('=', 1)
    if bytes.fromhex(cdhash) not in data:
        sys.exit(f'error: stapled ticket is missing {arch} CDHash {cdhash}: {bundle}')
    print(f'stapled ticket covers {arch} CDHash {cdhash}: {bundle}')
PY
}
