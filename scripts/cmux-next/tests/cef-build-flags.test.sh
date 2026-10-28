#!/usr/bin/env bash
# cef_build_flags.py reads a CEF folder's archive.json (written by the fork's
# build-cmux-cef.sh, cmux.17 and later) and checks that the framework was
# built with dcheck_always_on = false: with DCHECKs on, a DCHECK that web
# content reaches aborts the app (plans/cmux-next/crash-elimination.md).
# Without --require it only warns (frameworks before cmux.17 have no
# gn_args); with --require it refuses. --require-official-pgo also refuses a
# framework that is not is_official_build=true with the manifest's pinned PGO
# profile, and a manifest without the A/B record that the pin won.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../cef_build_flags.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-build-flags.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/off" "$work/on" "$work/old"
echo '{"type":"minimal","name":"n","cmux_ref":"r","gn_args":{"dcheck_always_on":false,"is_official_build":false}}' > "$work/off/archive.json"
echo '{"type":"minimal","name":"n","cmux_ref":"r","gn_args":{"is_official_build":false}}' > "$work/on/archive.json"
echo '{"type":"minimal","name":"n","cmux_ref":"r"}' > "$work/old/archive.json"

/usr/bin/python3 "$check" "$work/off" --require 2>/dev/null || fail "a DCHECK-off framework was refused"
/usr/bin/python3 "$check" "$work/off" 2>"$work/err" || fail "a DCHECK-off framework failed without --require"
[[ ! -s "$work/err" ]] || fail "a DCHECK-off framework printed a warning"
for kind in on old; do
  if /usr/bin/python3 "$check" "$work/$kind" --require 2>/dev/null; then fail "--require accepted the $kind framework"; fi
  /usr/bin/python3 "$check" "$work/$kind" 2>"$work/err" || fail "the $kind framework failed without --require"
  grep -q "warning: " "$work/err" || fail "no warning for the $kind framework"
done
if /usr/bin/python3 "$check" "$work/missing" --require 2>/dev/null; then fail "--require accepted a folder without archive.json"; fi

# --require-official-pgo (manifest "require_official_pgo").
# The profile names are the ones chrome/build/mac-arm.pgo.txt
# and mac.pgo.txt name at Chromium tag 154.0.8037.58.
arm_hash=354a99ee3138b99ca5663d169539bc1a82b1eca7-01b870b743c773a6d66e8b1c5294a95ac51cd3b0
arm_profile="chrome-mac-arm-8037-1789514271-$arm_hash.profdata"
x86_profile="chrome-mac-8037-1789495081-eebf3ce77b36a1ad15bece90fb99aefb70206bb6-9272cb3a6934b0e4510fb1cde78ca7e9d7859922.profdata"
edit_json() { # <src> <dst> <python statements on m>
  /usr/bin/python3 -c 'import json, sys
m = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(m, open(sys.argv[2], "w"))' "$@"
}
pinned="$work/pinned.json"
cat > "$pinned" <<JSON
{"version": "cef-test", "chromium": "154.0.8037.58", "require_dcheck_off": true, "require_official_pgo": true,
 "pgo_profile": "$arm_profile",
 "x86_64": {"asset": "a", "pgo_profile": "$x86_profile"},
 "official_pgo_ab": {"job": "70436914a38e", "runs": 20, "cef_initialize_speedup": 0.14,
   "new_tab_paint_speedup": 0.11, "stress_soak_minutes": 30, "stress_soak_crashes": 0,
   "shim_crash_recovery": "pass"}}
JSON
official() { # <folder> [arch] [manifest]
  /usr/bin/python3 "$check" "$1" --require-official-pgo --manifest "${3:-$pinned}" --arch "${2:-arm64}"
}
good_counts='{"functions":120000,"mismatched":3720}'
write_official() { # <name> <gn_args json> <pgo_profile json> <pgo_mismatch json>
  mkdir -p "$work/$1"
  echo "{\"type\":\"minimal\",\"name\":\"n\",\"cmux_ref\":\"r\",\"gn_args\":$2,\"pgo_profile\":$3,\"pgo_mismatch\":$4}" > "$work/$1/archive.json"
}
good_args='{"dcheck_always_on":false,"is_official_build":true,"chrome_pgo_phase":2}'
write_official pgo "$good_args" "\"$arm_profile\"" "$good_counts"
write_official pgo-default-phase '{"dcheck_always_on":false,"is_official_build":true}' "\"$arm_profile\"" '{"functions":10,"mismatched":0}'
write_official pgo-data-path '{"dcheck_always_on":false,"is_official_build":true,"pgo_data_path":"//chrome/build/pgo_profiles/'"$arm_profile"'"}' "\"$arm_profile\"" "$good_counts"
write_official pgo-x86 "$good_args" "\"$x86_profile\"" "$good_counts"
official "$work/pgo" 2>/dev/null || fail "an official framework with the pinned profile was refused"
official "$work/pgo" 2>"$work/err"
[[ ! -s "$work/err" ]] || fail "an official PGO framework printed a message"
official "$work/pgo-default-phase" 2>/dev/null || fail "an official framework with the default PGO phase was refused"
official "$work/pgo-data-path" 2>/dev/null || fail "a pgo_data_path naming the pinned profile was refused"
official "$work/pgo-x86" x86_64 2>/dev/null || fail "the pinned x86_64 profile was refused"
# A branch that still uses the main-branch profile pins that name.
main_profile="chrome-mac-arm-main-1738749294-$arm_hash.profdata"
edit_json "$pinned" "$work/pinned-main.json" "m['pgo_profile'] = '$main_profile'"
write_official main-profile "$good_args" "\"$main_profile\"" "$good_counts"
official "$work/main-profile" arm64 "$work/pinned-main.json" 2>/dev/null || fail "a main-branch profile that the manifest pins was refused"

refuse() { # <name> <why> [arch] [manifest]
  if official "$work/$1" "${3:-arm64}" "${4:-$pinned}" 2>"$work/err"; then fail "--require-official-pgo accepted $2"; fi
  grep -q "^error: " "$work/err" || fail "no error for $2"
}
write_official not-official '{"dcheck_always_on":false,"is_official_build":false}' "\"$arm_profile\"" "$good_counts"
refuse not-official "is_official_build=false"
grep -q "is_official_build = true" "$work/err" || fail "the error does not name is_official_build = true"
write_official no-official-flag '{"dcheck_always_on":false}' "\"$arm_profile\"" "$good_counts"
refuse no-official-flag "gn_args without is_official_build"
write_official pgo-off '{"dcheck_always_on":false,"is_official_build":true,"chrome_pgo_phase":0}' "\"$arm_profile\"" "$good_counts"
refuse pgo-off "chrome_pgo_phase=0"
write_official pgo-phase-true '{"dcheck_always_on":false,"is_official_build":true,"chrome_pgo_phase":true}' "\"$arm_profile\"" "$good_counts"
refuse pgo-phase-true "chrome_pgo_phase=true"
write_official dcheck-on '{"is_official_build":true}' "\"$arm_profile\"" "$good_counts"
refuse dcheck-on "an official framework without dcheck_always_on=false"
write_official other-branch "$good_args" "\"chrome-mac-arm-8036-1789514271-$arm_hash.profdata\"" "$good_counts"
refuse other-branch "the profile of another Chromium branch"
write_official other-time "$good_args" "\"chrome-mac-arm-8037-1789000000-$arm_hash.profdata\"" "$good_counts"
refuse other-time "a same-branch profile with another timestamp"
grep -q "not the pinned arm64 profile $arm_profile" "$work/err" || fail "the error does not name the pinned profile"
write_official other-sha1 "$good_args" "\"chrome-mac-arm-8037-1789514271-0123456789abcdef0123456789abcdef01234567-01b870b743c773a6d66e8b1c5294a95ac51cd3b0.profdata\"" "$good_counts"
refuse other-sha1 "a same-branch profile with another sha1"
refuse main-profile "a main-branch profile that the manifest does not pin"
refuse pgo-x86 "the x86_64 profile for an arm64 framework"
refuse pgo "the arm64 profile for an x86_64 framework" x86_64
write_official no-profile "$good_args" null "$good_counts"
refuse no-profile "no recorded pgo_profile"
write_official data-path-mismatch '{"dcheck_always_on":false,"is_official_build":true,"pgo_data_path":"/p/chrome-mac-arm-8037-1-'"$arm_hash"'.profdata"}' "\"$arm_profile\"" "$good_counts"
refuse data-path-mismatch "a pgo_data_path that is not the pinned profile"
write_official high-mismatch "$good_args" "\"$arm_profile\"" '{"functions":120000,"mismatched":12000}'
refuse high-mismatch "a 10 % profile mismatch rate"
grep -q "12000 of 120000 functions" "$work/err" || fail "the error does not give the mismatch counts"
write_official no-mismatch "$good_args" "\"$arm_profile\"" null
refuse no-mismatch "no measured mismatch counts"
mkdir -p "$work/rate-only"
echo "{\"gn_args\":$good_args,\"pgo_profile\":\"$arm_profile\",\"pgo_mismatch_rate\":0.01}" > "$work/rate-only/archive.json"
refuse rate-only "a hand-written rate without counts"
write_official bool-mismatch "$good_args" "\"$arm_profile\"" '{"functions":true,"mismatched":false}'
refuse bool-mismatch "boolean mismatch counts"
write_official zero-functions "$good_args" "\"$arm_profile\"" '{"functions":0,"mismatched":0}'
refuse zero-functions "zero profiled functions"
write_official more-mismatched "$good_args" "\"$arm_profile\"" '{"functions":10,"mismatched":11}'
refuse more-mismatched "more mismatched functions than functions"
write_official negative-mismatch "$good_args" "\"$arm_profile\"" '{"functions":10,"mismatched":-1}'
refuse negative-mismatch "a negative mismatch count"
if official "$work/missing" 2>/dev/null; then fail "--require-official-pgo accepted a folder without archive.json"; fi
edit_json "$pinned" "$work/no-ab.json" "del m['official_pgo_ab']"
refuse pgo "a manifest without the A/B record" arm64 "$work/no-ab.json"
edit_json "$pinned" "$work/no-x86-section.json" "del m['x86_64']"
refuse pgo-x86 "an x86_64 framework when the manifest pins no x86_64 artifact" x86_64 "$work/no-x86-section.json"
# Without --require-official-pgo a non-official framework passes as before.
/usr/bin/python3 "$check" "$work/not-official" --require 2>/dev/null || fail "--require alone refused a non-official framework"

usage() { # <why> <args...>
  local why="$1"; shift
  set +e; /usr/bin/python3 "$check" "$@" 2>/dev/null; local code=$?; set -e
  [[ "$code" == 2 ]] || fail "$why exited $code, not 2"
}
usage "--require-official-pgo without --manifest" "$work/pgo" --require-official-pgo --arch arm64
usage "--require-official-pgo without --arch" "$work/pgo" --require-official-pgo --manifest "$pinned"
usage "--require-official-pgo with an unknown arch" "$work/pgo" --require-official-pgo --manifest "$pinned" --arch arm64e
usage "--manifest without a value" "$work/pgo" --require-official-pgo --arch arm64 --manifest
usage "an unknown flag" "$work/pgo" --requires
usage "--check-manifest without a path" --check-manifest
usage "--count-pgo-mismatch without a path" --count-pgo-mismatch

# --check-manifest: a pin that requires an official PGO framework records the
# pinned profile per arch and the fleet A/B it won (task 047 acceptance).
/usr/bin/python3 "$check" --check-manifest "$pinned" 2>/dev/null || fail "--check-manifest refused a complete pin"
/usr/bin/python3 "$check" --check-manifest "$here/../cef-manifest.json" || fail "cef-manifest.json require_official_pgo is not consistent"
refuse_manifest() { # <why> <python statements on m>
  edit_json "$pinned" "$work/bad-manifest.json" "$2"
  if /usr/bin/python3 "$check" --check-manifest "$work/bad-manifest.json" 2>"$work/err"; then fail "--check-manifest accepted $1"; fi
  grep -q "^error: " "$work/err" || fail "no error for $1"
}
refuse_manifest "a string require_official_pgo" "m['require_official_pgo'] = 'yes'"
refuse_manifest "require_dcheck_off false" "m['require_dcheck_off'] = False"
refuse_manifest "no arm64 pgo_profile" "del m['pgo_profile']"
refuse_manifest "an arm64 pgo_profile that is not a profile name" "m['pgo_profile'] = 'chrome-mac-arm-8037.profdata'"
refuse_manifest "the x86_64 profile as the arm64 pin" "m['pgo_profile'] = '$x86_profile'"
refuse_manifest "no x86_64 pgo_profile" "del m['x86_64']['pgo_profile']"
refuse_manifest "the arm64 profile as the x86_64 pin" "m['x86_64']['pgo_profile'] = '$arm_profile'"
refuse_manifest "no A/B record" "del m['official_pgo_ab']"
refuse_manifest "no A/B job" "m['official_pgo_ab']['job'] = ''"
refuse_manifest "fewer than 20 A/B runs" "m['official_pgo_ab']['runs'] = 10"
refuse_manifest "a 9 % CefInitialize speedup" "m['official_pgo_ab']['cef_initialize_speedup'] = 0.09"
refuse_manifest "a slower new-tab paint" "m['official_pgo_ab']['new_tab_paint_speedup'] = -0.2"
refuse_manifest "a 20 minute soak" "m['official_pgo_ab']['stress_soak_minutes'] = 20"
refuse_manifest "a soak crash" "m['official_pgo_ab']['stress_soak_crashes'] = 1"
refuse_manifest "a boolean soak crash count" "m['official_pgo_ab']['stress_soak_crashes'] = False"
refuse_manifest "a failed shim crash-recovery test" "m['official_pgo_ab']['shim_crash_recovery'] = 'fail'"
edit_json "$pinned" "$work/unpinned.json" "m['require_official_pgo'] = False; del m['official_pgo_ab']"
/usr/bin/python3 "$check" --check-manifest "$work/unpinned.json" || fail "--check-manifest refused a manifest that does not require an official framework"

# --count-pgo-mismatch sums clang's per-unit PGO warnings from a ninja log; a
# unit that prints both warnings is counted once.
cat > "$work/ninja.log" <<'LOG'
[1/3] CXX obj/a.o
warning: profile data may be out of date: of 100 functions, 4 have mismatched data that will be ignored [-Wprofile-instr-out-of-date]
warning: profile data may be incomplete: of 100 functions, 7 have no data [-Wprofile-instr-missing]
2 warnings generated.
[2/3] CXX obj/b.o
warning: profile data may be incomplete: of 50 functions, 1 has no data [-Wprofile-instr-missing]
1 warning generated.
[3/3] CXX obj/c.o
warning: profile data may be out of date: of 1 function, 1 has mismatched data that will be ignored [-Wprofile-instr-out-of-date]
LOG
counts=$(/usr/bin/python3 "$check" --count-pgo-mismatch "$work/ninja.log")
[[ "$counts" == '{"functions": 151, "mismatched": 5}' ]] || fail "--count-pgo-mismatch printed $counts"

# ensure-cef.sh end to end on a cached framework: a manifest with
# require_official_pgo passes its path, so the pinned profile decides.
cache="$work/cache"; sha=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$cache/cef-test/Chromium Embedded Framework.framework"
echo "$sha" > "$cache/cef-test/.verified"
edit_json "$pinned" "$work/ensure.json" "m.update(asset='a.tar.xz', sha256='$sha')"
ensure() { # <archive folder> [--optional]
  cp "$work/$1/archive.json" "$cache/cef-test/archive.json"
  CMUX_CEF_MANIFEST="$work/ensure.json" CMUX_CEF_CACHE_DIR="$cache" bash "$here/../ensure-cef.sh" ${2:+"$2"}
}
[[ "$(ensure pgo 2>/dev/null)" == "$cache/cef-test" ]] || fail "ensure-cef.sh refused the pinned official framework"
if ensure other-time 2>"$work/err" >/dev/null; then fail "ensure-cef.sh accepted a framework with another profile"; fi
grep -q "not the pinned arm64 profile" "$work/err" || fail "ensure-cef.sh did not say why it refused the framework"
[[ -z "$(ensure other-time --optional 2>"$work/err")" ]] || fail "ensure-cef.sh --optional used a framework with another profile"
grep -q "^warning: CEF unavailable" "$work/err" || fail "ensure-cef.sh --optional did not warn about the refused framework"
echo "cef-build-flags: ok"
