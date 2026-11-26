#!/usr/bin/env bash
# The CmuxMobileKit iOS simulator tests on the fleet pool, for pr-pipeline.yml's ios job and its ios-kit step
# (ci/steps.toml). vars.CMUX_IOS_SIM_LINUX picks the mode: "shadow" runs the pool beside the Mac's own
# simulator run, advisory, so both are timed on one head; "on" makes the pool's verdict the check, and the Mac runs
# the simulator tests only when the pool gave none (a logged Mac fallback); unset or anything else leaves the pool out.
#
#   ios-sim-pool.sh pack      build for testing on this Mac and pack the products into $DIR/products
#   ios-sim-pool.sh upload    put $DIR/products in the fleet's own store, in parts, for this run's pool step only;
#                             writes their digests to $DIR/products.parts (nothing goes to a repository artifact)
#   ios-sim-pool.sh submit    submit the pool run and return (products: PRODUCTS if set, a <run id>/<artifact> of
#                             an older run; else $DIR/products.parts from upload); the client waits in the
#                             background and writes $DIR/exit and $DIR/finished
#   ios-sim-pool.sh collect   wait (up to CMUX_IOS_SIM_POOL_WAIT seconds) and print the verdict line:
#                             "pass|fail|none <seconds> <reason>"
#
# $DIR is CMUX_IOS_SIM_POOL_DIR (default $RUNNER_TEMP/sim-pool). Run from the repository root.
#
# Leo, 2026-11-24: "we also absolutely need to get the ios simulators up and running on our linux ci asap and get
# that shit in tip top shape ... then we can run ios sims on gcp and dramatically unblock aziz."
set -uo pipefail

dir="${CMUX_IOS_SIM_POOL_DIR:-${RUNNER_TEMP:?}/sim-pool}"
mkdir -p "$dir"
# The ios-kit step's own simulator skips (ci/steps.toml), so the pool runs what the Mac would.
skips=(CmuxMobileInstantPerfTests)

# fetch_client: the fleet client, from the controller, each file checked against the manifest's sha256.
fetch_client() {
  client="$dir/fleet-client"
  [[ -f "$client/ci-client.py" ]] && return 0
  mkdir -p "$client"
  curl -fsS -m 30 "$CONTROLLER/v1/client/manifest" -o "$client/manifest.json"
  python3 -I - "$client" "$CONTROLLER" <<'PY'
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
}

case "${1:-}" in
pack)
  set -e
  start=$(date +%s)
  derived="${CMUX_DERIVED_DATA_SLOT:-$RUNNER_TEMP/dd-ios-sim}"
  (cd cmux-next-ios/rust && rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)" --profile minimal)
  bash scripts/ci/ios_link_ffi.sh 8
  (cd cmux-next-ios/CmuxMobileKit && xcodebuild build-for-testing -scheme CmuxMobileKit-Package \
    -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -enableCodeCoverage NO \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet)
  out="$dir/products"
  rm -rf "$out"
  mkdir -p "$out"
  tar -C "$derived/Build" -czf "$out/ios-sim-build.tar.gz" Products
  plat="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
  tar -C "$plat" -czf "$out/ios-sim-xctest-platform.tar.gz" Library/Frameworks Library/PrivateFrameworks Library/Xcode/Agents usr/lib
  du -sh "$out"/*
  echo "build-for-testing and pack: $(( $(date +%s) - start )) s"
  ;;
upload)
  set -e
  : "${CONTROLLER:?no CMUX_FLEET_CONTROLLER variable}" "${GITHUB_RUN_ID:?}"
  start=$(date +%s)
  fetch_client
  # One plain tar of the products' tarballs, cut into parts the store takes (at most 512 MiB each, 4 parts).
  parts="$dir/products-parts"
  rm -rf "$parts" "$dir/products.parts"
  mkdir -p "$parts"
  (python3 -I - "$dir/products" "$parts" <<'PY'
import hashlib, os, sys, tarfile
src, out = sys.argv[1], sys.argv[2]
limit = 448 << 20
class Parts:
    def __init__(self):
        self.n, self.f, self.size = -1, None, limit
    def write(self, data):
        view = memoryview(data)
        while view:
            if self.size >= limit:
                if self.f:
                    self.f.close()
                self.n += 1
                if self.n >= 4:
                    raise SystemExit("the products are over 4 parts (1.75 GiB)")
                self.f, self.size = open(os.path.join(out, f"part{self.n}"), "xb"), 0
            take = min(len(view), limit - self.size)
            self.f.write(view[:take])
            self.size += take
            view = view[take:]
        return len(data)
    def close(self):
        if self.f:
            self.f.close()
parts = Parts()
with tarfile.open(fileobj=parts, mode="w|", format=tarfile.PAX_FORMAT) as tar:
    for name in sorted(os.listdir(src)):
        if name.endswith(".tar.gz"):
            tar.add(os.path.join(src, name), arcname=name, recursive=False)
parts.close()
for i in range(parts.n + 1):
    h = hashlib.sha256()
    with open(os.path.join(out, f"part{i}"), "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    print(f"part{i} {h.hexdigest()}")
PY
  ) > "$parts/index"
  lane="https://github.com/manaflow-ai/cmux/actions/runs/$GITHUB_RUN_ID"
  pids=()
  while read -r part digest; do
    CMUX_CI_CONTROLLER="$CONTROLLER" python3 "$dir/fleet-client/ci-client.py" artifact-put "$parts/$part" \
      --sha256 "$digest" --lane "$lane" > "$parts/$part.json" 2> "$parts/$part.log" &
    pids+=($!)
  done < "$parts/index"
  failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  if [[ $failed -ne 0 ]]; then
    cat "$parts"/*.log >&2 || true
    echo "fleet pool: products upload failed" >&2
    exit 1
  fi
  sed 's/^[^ ]* /sha256:/' "$parts/index" | paste -s -d , - > "$dir/products.parts"
  echo "fleet pool: $(wc -l < "$parts/index") part(s) uploaded in $(( $(date +%s) - start ))s"
  rm -f "$parts"/part[0-9]
  ;;
submit)
  : "${CONTROLLER:?no CMUX_FLEET_CONTROLLER variable}" "${HEAD_SHA:?}"
  if [[ -z "${PRODUCTS:-}" ]]; then
    PRODUCTS="$(cat "$dir/products.parts" 2>/dev/null || true)"
    [[ -n "$PRODUCTS" ]] || { echo "no products: set PRODUCTS or run upload first" >&2; exit 1; }
  fi
  export PRODUCTS
  fetch_client || exit 1
  args=()
  for s in "${skips[@]}"; do args+=(--arg "skip=$s"); done
  date +%s > "$dir/started"
  rm -f "$dir/exit" "$dir/finished"
  CMUX_CI_CONTROLLER="$CONTROLLER" nohup bash -c '
    client="$1" dir="$2"; shift 2
    python3 "$client/ci-client.py" run --class simulator --os linux --script scripts/ci/ios-sim-linux-test.sh \
      --ref "$HEAD_SHA" --repo manaflow-ai/cmux --env "CMUX_IOS_PRODUCTS=$PRODUCTS" --arg suite=kit "$@" \
      --arg timeout=1800 --artifact artifacts/ios-sim-linux/result.tgz --timeout 2400 --queue-timeout 900
    echo $? > "$dir/exit"; date +%s > "$dir/finished"
  ' _ "$client" "$dir" "${args[@]}" > "$dir/step.log" 2>&1 < /dev/null &
  echo "submitted in the background (pid $!)"
  touch "$dir/submitted"
  ;;
collect)
  verdict=none
  seconds=0
  if [[ ! -f "$dir/submitted" ]]; then
    reason="no pool run was submitted for this job"
  else
    wait_s="${CMUX_IOS_SIM_POOL_WAIT:-1500}"
    end=$(( $(date +%s) + wait_s ))
    while [[ ! -f "$dir/exit" && $(date +%s) -lt $end ]]; do sleep 2; done
    status="$(cat "$dir/exit" 2>/dev/null || echo unfinished)"
    step="$(grep -o -E 'step [0-9a-f]{24}' "$dir/step.log" 2>/dev/null | head -1 | cut -d' ' -f2)"
    if [[ -n "$step" ]]; then
      python3 "$dir/fleet-client/ci-client.py" artifact "$step" "$dir/result.tgz" >&2 \
        || python3 "$dir/fleet-client/ci-client.py" artifact --failed "$step" "$dir/result.tgz" >&2 || true
    fi
    if [[ -s "$dir/result.tgz" ]]; then
      mkdir -p "$dir/result" && tar -xzf "$dir/result.tgz" -C "$dir/result" 2>/dev/null || true
    fi
    if [[ -f "$dir/result/summary.txt" ]]; then
      cat "$dir/result/summary.txt" >&2
      grep -E -A400 '<failure|<error' "$dir/result/junit.xml" 2>/dev/null | head -80 >&2 || true
    else
      tail -n 40 "$dir/step.log" >&2 2>/dev/null || true
    fi
    cases="$(grep -c '<testcase' "$dir/result/junit.xml" 2>/dev/null || true)"
    cases="${cases:-0}"
    if [[ "$status" == 0 && "$cases" -gt 0 ]]; then
      verdict=pass; reason="step ${step:-?} passed $cases tests"
    elif [[ "$status" == 1 && "$cases" -gt 0 ]]; then
      verdict=fail; reason="step ${step:-?} ran $cases tests and some failed"
    else
      reason="step ${step:-none} gave no verdict (exit $status, $cases test cases)"
    fi
    if [[ -f "$dir/finished" ]]; then
      seconds=$(( $(cat "$dir/finished") - $(cat "$dir/started") ))
    fi
  fi
  echo "$verdict $seconds $reason"
  ;;
*)
  echo "usage: ios-sim-pool.sh pack|submit|collect" >&2
  exit 2
  ;;
esac
