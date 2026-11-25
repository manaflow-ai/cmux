#!/usr/bin/env bash
# The CmuxMobileKit iOS simulator tests on the fleet pool (a cmux-linux-simsdk-x64 VM running agent-sim,
# scripts/ci/ios-sim-linux-test.sh), for pr-pipeline.yml's ios job (the kit's ios-kit step of ci/steps.toml).
# cmux-next-ios-kit.yml's push runs do the same steps inline.
#
#   pack     get CmuxMobileLinkFFI.xcframework (scripts/ci/ios_link_ffi.sh), then the kit for testing (generic iOS Simulator, arm64), and
#            pack the products into $RUNNER_TEMP/kit-sim-products (run from the repository root, before ci/run:
#            the machine's own rustup, ${CARGO_HOME:-~/.cargo}/bin, which ci/run's rust tool installs there too)
#   submit   fetch the fleet client and submit the pool run in the background; CMUX_IOS_PRODUCTS names the
#            uploaded artifact (<run id>/<artifact name>), CMUX_FLEET_CONTROLLER the controller, HEAD_SHA the ref
#   result   wait for the pool run and write verdict= (pass, fail or none) and reason= to $GITHUB_OUTPUT;
#            PACKED, UPLOADED and STARTED are the outcomes of the steps before it. Never fails itself.
#
# Leo: "we need to not only build, but use. that's the actual deliverable ... linuxifying our shit ... ios linux".
set -euo pipefail

tmp="${RUNNER_TEMP:?RUNNER_TEMP is unset}"
dir="$tmp/sim-linux"
products="$tmp/kit-sim-products"
client="$tmp/fleet-client"
# The pool run leaves out what the Mac simulator step leaves out (scripts/ci/ios-kit-sim-mac-test.sh): the bench,
# and the suites the macOS and Linux swift test runs already cover.
skips=(CmuxMobileInstantPerfTests CmuxMobileDesignCoreTests CmuxMobileRealtimeTests CmuxMobileTransportTests)

pack() {
  local start derived plat
  start=$(date +%s)
  derived="${CMUX_DERIVED_DATA_SLOT:-$tmp/dd-ios-sim}"
  export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
  command -v rustup >/dev/null || { echo "no rustup on this machine yet: the Mac runs the simulator tests" >&2; exit 1; }
  (cd cmux-next-ios/rust && rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)" --profile minimal)
  # The build fleet's copy when it has one (marked, so ci/run's ios-kit step reuses it), else this Mac builds it.
  bash scripts/ci/ios_link_ffi.sh 8
  (cd cmux-next-ios/CmuxMobileKit && xcodebuild build-for-testing -scheme CmuxMobileKit-Package \
    -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -enableCodeCoverage NO \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet)
  rm -rf "$products"
  mkdir -p "$products"
  tar -C "$derived/Build" -czf "$products/ios-sim-build.tar.gz" Products
  plat="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
  tar -C "$plat" -czf "$products/ios-sim-xctest-platform.tar.gz" \
    Library/Frameworks Library/PrivateFrameworks Library/Xcode/Agents usr/lib
  du -sh "$products"/*
  touch "$products/.packed"
  echo "build-for-testing and pack: $(( $(date +%s) - start )) s"
}

submit() {
  local controller="${CMUX_FLEET_CONTROLLER:-}"
  [[ -n "$controller" ]] || { echo "no CMUX_FLEET_CONTROLLER variable" >&2; exit 1; }
  [[ -n "${CMUX_IOS_PRODUCTS:-}" && -n "${HEAD_SHA:-}" ]] || { echo "CMUX_IOS_PRODUCTS and HEAD_SHA are required" >&2; exit 1; }
  rm -rf "$dir"
  mkdir -p "$client" "$dir"
  curl -fsS -m 30 "$controller/v1/client/manifest" -o "$client/manifest.json"
  python3 -I - "$client" "$controller" <<'PY'
import hashlib, json, sys, urllib.request
from pathlib import Path
root, controller = Path(sys.argv[1]), sys.argv[2]
for name, digest in json.loads((root / "manifest.json").read_text())["files"].items():
    if "/" in name or name.startswith("."):
        raise SystemExit(f"bad client file name {name!r}")
    data = urllib.request.urlopen(f"{controller}/v1/client/files/{name}", timeout=30).read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"{name}: sha256 mismatch")
    (root / name).write_bytes(data)
PY
  local args=(--arg suite=kit --arg timeout=1800)
  local s
  for s in "${skips[@]}"; do args+=(--arg "skip=$s"); done
  date +%s > "$dir/started"
  # The client bounds itself (queue 900 s, run 2400 s); "result" reads its exit and step id from these files.
  CMUX_CI_CONTROLLER="$controller" nohup bash -c '
    client="$1"; dir="$2"; shift 2
    python3 "$client/ci-client.py" run --class simulator --os linux --script scripts/ci/ios-sim-linux-test.sh \
      --ref "$HEAD_SHA" --repo manaflow-ai/cmux --env "CMUX_IOS_PRODUCTS=$CMUX_IOS_PRODUCTS" "$@" \
      --artifact artifacts/ios-sim-linux/result.tgz --timeout 2400 --queue-timeout 900
    echo $? > "$dir/exit"; date +%s > "$dir/finished"
  ' _ "$client" "$dir" "${args[@]}" > "$dir/step.log" 2>&1 &
  echo "submitted in the background (pid $!)"
}

result() {
  set +e
  local verdict=none reason status step cases
  if [[ "${PACKED:-}" != success ]]; then
    reason="the simulator test build for the pool did not finish (${PACKED:-skipped})"
  elif [[ "${UPLOADED:-}" != success ]]; then
    reason="the simulator test build did not upload (${UPLOADED:-skipped})"
  elif [[ "${STARTED:-}" != success ]]; then
    reason="the pool run was not submitted (${STARTED:-skipped})"
  else
    # Outlasts the client's own bounds (queue 900 s and run 2400 s), counted from the submit.
    local deadline=$(( $(cat "$dir/started" 2>/dev/null || date +%s) + 3400 ))
    while [[ ! -f "$dir/exit" && $(date +%s) -lt $deadline ]]; do sleep 2; done
    status="$(cat "$dir/exit" 2>/dev/null || echo unfinished)"
    step="$(grep -o -E 'step [0-9a-f]{24}' "$dir/step.log" 2>/dev/null | head -1 | cut -d' ' -f2)"
    if [[ -n "$step" ]]; then
      python3 "$client/ci-client.py" artifact "$step" "$dir/result.tgz" \
        || python3 "$client/ci-client.py" artifact --failed "$step" "$dir/result.tgz"
    fi
    [[ -s "$dir/result.tgz" ]] && mkdir -p "$dir/result" && tar -xzf "$dir/result.tgz" -C "$dir/result" 2>/dev/null
    if [[ -f "$dir/result/summary.txt" ]]; then
      cat "$dir/result/summary.txt"
      grep -E -A400 '<failure|<error' "$dir/result/junit.xml" 2>/dev/null | head -80
    else
      tail -n 40 "$dir/step.log" 2>/dev/null
    fi
    cases="$(grep -c '<testcase' "$dir/result/junit.xml" 2>/dev/null)"
    cases="${cases:-0}"
    if [[ "$status" == 0 && "$cases" -gt 0 ]]; then
      verdict=pass; reason="step ${step:-?} passed $cases tests"
    elif [[ "$status" == 1 && "$cases" -gt 0 ]]; then
      verdict=fail; reason="step ${step:-?} ran $cases tests and some failed"
    else
      reason="step ${step:-none} gave no verdict (exit $status, $cases test cases)"
    fi
    if [[ -f "$dir/finished" && -f "$dir/started" ]]; then
      reason="$reason in $(( $(cat "$dir/finished") - $(cat "$dir/started") )) s"
    fi
  fi
  echo "fleet pool: $verdict: $reason"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    { echo "### iOS simulator tests on the fleet pool: $verdict"; echo "$reason"; } >> "$GITHUB_STEP_SUMMARY"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "verdict=$verdict"; echo "reason=$reason"; } >> "$GITHUB_OUTPUT"
  fi
  return 0
}

case "${1:-}" in
  pack) pack ;;
  submit) submit ;;
  result) result ;;
  *) echo "usage: $0 pack|submit|result" >&2; exit 2 ;;
esac
