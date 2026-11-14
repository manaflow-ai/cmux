#!/usr/bin/env bash
# CMUX-570: a paired installed-app measurement using an exact published nightly.
# Replaces its CEF binary with matching V8 snapshots and optionally compares two pinned CLI artifacts.
# This is a local packaging experiment, not a release/pin change.
# cmux-ci run --class exclusive --display --label measure --script scripts/measure/cef-app-size.sh \
#   --ref SHA --cef sha256:CEF --artifact artifacts/cef-app-size.tgz \
#   --arg NIGHTLY_NUMBER --arg DMG_SHA256 --arg CEF_FORK_SHA --timeout 1800
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cef-app-size.sh 'codesign and app launch' 'CMUX-570 paired CEF app proof'
[[ "$(uname -s)" == Darwin ]] || { echo 'cef-app-size requires a macOS display worker' >&2; exit 2; }
[[ ( $# == 3 || $# == 7 ) && "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9a-f]{64}$ && "$3" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'usage: cef-app-size.sh NIGHTLY_NUMBER DMG_SHA256 CEF_FORK_SHA [BASE_CLI_SHA BASE_CLI_DIGEST NEXT_CLI_SHA NEXT_CLI_DIGEST]' >&2; exit 2;
}
nightly="$1" digest="$2" fork="$3"
arms=(baseline candidate)
if [[ $# == 7 ]]; then
  [[ "$4" =~ ^[0-9a-f]{40}$ && "$5" =~ ^[0-9a-f]{64}$ && "$6" =~ ^[0-9a-f]{40}$ && "$7" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'CLI inputs require full commit SHAs and SHA-256 digests' >&2; exit 2;
  }
  arms=(baseline cef-only candidate)
fi
cef="${CMUX_CI_CEF_DIR:?run with --cef sha256:CEF}"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-app-size.XXXXXX")"
out="$work/report"
mkdir -p "$out" "$root/artifacts" "$work/mount"
mounted=0
finish() {
  status=$?
  trap - EXIT
  if [[ "$mounted" == 1 ]]; then hdiutil detach "$work/mount" >/dev/null 2>&1 || true; fi
  printf '%s\n' "$status" > "$out/exit-code.txt"
  tar -czf "$root/artifacts/cef-app-size.tgz" -C "$out" . || status=1
  # WORK is this invocation's recorded directory; no shared app or cache is removed.
  rm -rf "$work"
  exit "$status"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
python3 - "$cef" "$fork" "$out/candidate.json" "$work/binary-path" <<'PY'
import json, pathlib, sys
root, expected, output, path_output = sys.argv[1:]
archives = list(pathlib.Path(root).glob('archive.json')) + list(pathlib.Path(root).glob('*/archive.json'))
if len(archives) != 1:
    raise SystemExit('Expected exactly one raw CEF distribution')
manifest = archives[0]
data = json.loads(manifest.read_text())
args = data.get('gn_args', {})
if data.get('cmux_ref') != expected or args.get('target_cpu') != 'arm64':
    raise SystemExit('CEF source or architecture does not match the requested candidate')
if not args.get('is_official_build') or not args.get('use_thin_lto'):
    raise SystemExit('Candidate must be official Release with ThinLTO')
if args.get('cmux_identity_test_provider') is not False:
    raise SystemExit('Candidate must explicitly disable the identity test provider')
for feature in ('enterprise_local_content_analysis', 'enterprise_screenshot_protection'):
    if args.get(feature) is False:
        raise SystemExit(f'{feature} was disabled: this comparison preserves the feature set')
binary = manifest.parent / 'Chromium Embedded Framework.framework/Chromium Embedded Framework'
if not binary.is_file():
    raise SystemExit('Missing CEF framework binary')
pathlib.Path(output).write_text(json.dumps(data, indent=2) + '\n')
pathlib.Path(path_output).write_text(str(binary.resolve()))
PY
candidate="$(cat "$work/binary-path")"
url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$nightly.dmg"
curl --fail --location --retry 2 --connect-timeout 15 --max-time 600 -o "$work/nightly.dmg" "$url"
[[ "$(shasum -a 256 "$work/nightly.dmg" | cut -c1-64)" == "$digest" ]] || {
  echo 'Nightly DMG checksum mismatch' >&2; exit 1;
}
hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$work/nightly.dmg" > "$out/mount.txt"
mounted=1
source_app="$work/mount/cmux NIGHTLY.app"
codesign --verify --deep --strict "$source_app"
for arm in "${arms[@]}"; do
  mkdir -p "$work/$arm" "$out/$arm"
  ditto "$source_app" "$work/$arm/cmux NIGHTLY.app"
done
hdiutil detach "$work/mount"
mounted=0
relative='Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework'
before="$work/baseline/cmux NIGHTLY.app/$relative"
after="$work/candidate/cmux NIGHTLY.app/$relative"
python3 - "$before" "$candidate" <<'PY'
import pathlib, plistlib, sys
versions = []
for name in sys.argv[1:]:
    binary = pathlib.Path(name).resolve()
    info = plistlib.loads((binary.parent / 'Resources/Info.plist').read_bytes())
    versions.append(tuple(info.get(key) for key in ('CFBundleShortVersionString', 'SCMRevision')))
if not all(versions[0]) or versions[0] != versions[1]:
    raise SystemExit(f'CEF versions differ: {versions}; binary substitution requires identical Chromium sources')
PY
[[ "$(lipo -archs "$before")" == arm64 && "$(lipo -archs "$candidate")" == arm64 ]] || {
  echo 'Both framework binaries must be arm64 only' >&2; exit 1;
}
nm -gjU "$before" | LC_ALL=C sort -u > "$out/baseline/exports.txt"
nm -gjU "$candidate" | LC_ALL=C sort -u > "$out/candidate/exports.txt"
LC_ALL=C comm -23 "$out/baseline/exports.txt" "$out/candidate/exports.txt" > "$out/missing-exports.txt"
[[ ! -s "$out/missing-exports.txt" ]] || { echo 'Candidate lost framework exports' >&2; exit 1; }
cp "$candidate" "$after"
dwarfdump --uuid "$after" | awk '{print $2}' > "$out/candidate/uuid-before-strip.txt"
strip -x "$after"
nm -gjU "$after" | LC_ALL=C sort -u > "$out/candidate/exports-after-strip.txt"
cmp "$out/candidate/exports.txt" "$out/candidate/exports-after-strip.txt"
dwarfdump --uuid "$after" | awk '{print $2}' > "$out/candidate/uuid-after-strip.txt"
cmp "$out/candidate/uuid-before-strip.txt" "$out/candidate/uuid-after-strip.txt"

if [[ $# == 7 ]]; then
  cp "$after" "$work/cef-only/cmux NIGHTLY.app/$relative"
  for variant in base next; do
    if [[ "$variant" == base ]]; then cli_ref="$4"; cli_digest="$5"; else cli_ref="$6"; cli_digest="$7"; fi
    cli_url="https://files.cmux.com/cmux-tui/$cli_ref"
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 600 \
      -o "$out/cli-$variant-manifest.json" "$cli_url/manifest.json"
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 600 \
      -o "$work/cli-$variant" "$cli_url/cmux-tui-aarch64-apple-darwin"
    python3 - "$out/cli-$variant-manifest.json" "$work/cli-$variant" "$cli_ref" "$cli_digest" <<'PY'
import hashlib, json, pathlib, sys
manifest, binary, ref, digest = sys.argv[1:]
data = json.loads(pathlib.Path(manifest).read_text())
if data.get('sourceCommit') != ref or data.get('binaries', {}).get('cmux-tui-aarch64-apple-darwin') != digest:
    raise SystemExit('CLI manifest does not match the requested source and digest')
if hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest() != digest:
    raise SystemExit('CLI artifact checksum mismatch')
PY
    [[ "$(lipo -archs "$work/cli-$variant")" == arm64 ]] || { echo 'CLI must be arm64 only' >&2; exit 1; }
    chmod 755 "$work/cli-$variant"
    # Match strip-release-bundle.sh: the CLI retains globals because it ships no dSYM.
    strip -S -x "$work/cli-$variant"
  done
  for arm in "${arms[@]}"; do
    variant=base
    [[ "$arm" != candidate ]] || variant=next
    cli="$work/$arm/cmux NIGHTLY.app/Contents/Resources/bin/cmux"
    [[ -f "$cli" && ! -L "$cli" ]] || { echo 'Expected a regular bundled CLI' >&2; exit 1; }
    cp "$work/cli-$variant" "$cli"
  done
  python3 - "$out" "$4" "$5" "$6" "$7" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
data = {'baseline': {'source': sys.argv[2], 'sha256': sys.argv[3]},
        'candidate': {'source': sys.argv[4], 'sha256': sys.argv[5]}, 'strip_flags': ['-S', '-x']}
(out / 'cli-inputs.json').write_text(json.dumps(data, indent=2) + '\n')
PY
fi

# Generated V8 snapshots are part of the engine build, even when the Chromium
# version is unchanged. A binary-only swap leaves the previous build's snapshots.
for arm in "${arms[@]}"; do
  [[ "$arm" != baseline ]] || continue
  python3 "$root/scripts/measure/cef-snapshot-resources.py" \
    "$(dirname "$candidate")/Resources" \
    "$work/$arm/cmux NIGHTLY.app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Resources" \
    "$out/$arm/snapshots.json"
done

# Record the installed payload before signing. This is the authoritative size
# comparison even when an ad-hoc signature or launch smoke fails later: signing
# changes only code-signature metadata, while the CEF payload bytes are already
# in their final locations.
printf 'arm\tdu_kib\tapp\n' > "$out/pre-sign-du.tsv"
for arm in "${arms[@]}"; do
  app="$work/$arm/cmux NIGHTLY.app"
  du_kib="$(du -sk "$app" | awk '{print $1}')"
  printf '%s\t%s\t%s\n' "$arm" "$du_kib" "$app" | tee -a "$out/pre-sign-du.tsv"
  python3 "$root/scripts/cmux-next/bundle-size.py" report "$app" --json "$out/$arm/size.json" \
    > "$out/$arm/size.txt"
done

signing_status=0
smoke_status=0
signature_report() {
  local app="$1" item
  for item in "$app" \
    "$app/Contents/Frameworks/Chromium Embedded Framework.framework" \
    "$app/Contents/Frameworks/"*" Helper.app" \
    "$app/Contents/Frameworks/"*" Helper ("*").app"; do
    [[ -d "$item" ]] || continue
    printf '\n--- %s\n' "${item#"$app"}"
    codesign -dvvv "$item" 2>&1 || true
    codesign -d -r- "$item" 2>&1 || true
    codesign --verify --strict "$item" 2>&1 || true
  done
}
for arm in "${arms[@]}"; do
  app="$work/$arm/cmux NIGHTLY.app"
  signature_report "$app" > "$out/$arm/signatures-before.txt"
  # Ad-hoc signing is only for the launch smoke. Do not preserve the DMG's
  # provisioning metadata: it is invalid for an ad-hoc identity and can make
  # launchd kill the copied app before it starts.
  # Resources/bin is not a standard nested-code location; sign its CLI explicitly.
  if codesign --force --sign - --timestamp=none "$app/Contents/Resources/bin/cmux" > "$out/$arm/sign.log" 2>&1 && \
     codesign --force --deep --sign - --timestamp=none "$app" >> "$out/$arm/sign.log" 2>&1; then
    printf 'signing_%s=passed\n' "$arm" | tee -a "$out/signing.txt"
  else
    code=$?
    printf 'signing_%s=failed exit=%s\n' "$arm" "$code" | tee -a "$out/signing.txt"
    signing_status=1
    continue
  fi
  signature_report "$app" > "$out/$arm/signatures-after.txt"
  if ! codesign --verify --deep --strict "$app" > "$out/$arm/sign-verify.log" 2>&1; then
    printf 'signing_%s=verify-failed\n' "$arm" | tee -a "$out/signing.txt"
    signing_status=1
    continue
  fi
  if ! python3 - "$app" > "$out/$arm/cli-help.log" 2>&1 <<'PY'
import pathlib, subprocess, sys
cli = pathlib.Path(sys.argv[1]) / 'Contents/Resources/bin/cmux'
subprocess.run([str(cli), '--help'], check=True, timeout=30)
PY
  then
    printf 'cli_%s=failed\n' "$arm" | tee -a "$out/signing.txt"
    smoke_status=1
  else
    printf 'cli_%s=passed\n' "$arm" | tee -a "$out/signing.txt"
  fi
  if ! python3 "$root/scripts/ci/stable_next_ui_journey.py" --app "$app" --out "$out/$arm/smoke" \
    --seconds 30 --startup-timeout 90 > "$out/$arm/smoke.log" 2>&1; then
    printf 'smoke_%s=failed\n' "$arm" | tee -a "$out/signing.txt"
    smoke_status=1
  else
    printf 'smoke_%s=passed\n' "$arm" | tee -a "$out/signing.txt"
  fi
done
python3 - "$out" "$nightly" "$digest" "$fork" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
before = json.loads((out / 'baseline/size.json').read_text())
after = json.loads((out / 'candidate/size.json').read_text())
signing = (out / 'signing.txt').read_text() if (out / 'signing.txt').exists() else ''
report = {'kind': 'paired-nightly-binary-and-snapshot-substitution', 'nightly': sys.argv[2],
          'dmg_sha256': sys.argv[3], 'cef_source': sys.argv[4],
          'baseline_app_bytes': before['app_bytes'], 'candidate_app_bytes': after['app_bytes'],
          'saved_app_bytes': before['app_bytes'] - after['app_bytes'],
          'pre_sign_du_tsv': 'pre-sign-du.tsv',
          'launch_and_browser_smoke_passed': 'smoke_baseline=passed' in signing and 'smoke_candidate=passed' in signing,
          'signing': signing.strip().splitlines(),
          'scope': 'CEF binary and matching V8 snapshots; release packaging and pin adoption remain separate'}
report['cli_help_smoke_passed'] = all(f'cli_{arm}=passed' in signing for arm in ('baseline', 'candidate'))
if (out / 'cli-inputs.json').exists():
    cef_only = json.loads((out / 'cef-only/size.json').read_text())
    report.update({'scope': 'Three copies of one nightly: baseline CLI, CEF only, CEF plus candidate CLI; release pin adoption remains separate',
                   'cli_inputs': json.loads((out / 'cli-inputs.json').read_text()),
                   'cef_only_app_bytes': cef_only['app_bytes'],
                   'cef_saved_app_bytes': before['app_bytes'] - cef_only['app_bytes'],
                   'cli_saved_app_bytes': cef_only['app_bytes'] - after['app_bytes']})
    report['launch_and_browser_smoke_passed'] &= 'smoke_cef-only=passed' in signing
    report['cli_help_smoke_passed'] &= 'cli_cef-only=passed' in signing
(out / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
PY
final_status=$((signing_status || smoke_status))
exit "$final_status"
