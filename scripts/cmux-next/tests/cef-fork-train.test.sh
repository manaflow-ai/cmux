#!/usr/bin/env bash
# cef-fork-train.py: the shared fork train (p07-memory 074). The ledger refuses
# API holes, ids listed twice, a deferred export a gate would read as shipped
# and an app gate no export claims; `ready` refuses an unmerged export, an
# export with no fork commit and a train header at another API; `pin` refuses
# while the train is not ready, then writes one manifest (both arches, debug
# assets, no stale R2 keys), records the pin, keeps only deferred exports and
# writes a commit message with the fork API, features per program and the
# checksums; `check-manifest` refuses a pin bump made outside the train.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/../cef-fork-train.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-fork-train.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
train() { python3 "$tool" "$@" --ledger "$work/ledger.json" --manifest "$work/manifest.json"; }
g() { git -C "$work/fork" -c user.name=t -c user.email=t@t "$@"; }

# A fork: the pinned commit at API 24, a train at API 25, a feature branch at 26.
mkdir -p "$work/fork/include" "$work/src"
g init -q -b main
header() { printf '#define CMUX_CEF_API_VERSION %s\n' "$1" > "$work/fork/include/cef_cmux.h"; }
header 24; g add -A; g commit -qm base
pinned="$(g rev-parse HEAD)"
header 25; g commit -qam "api 25"
a25="$(g rev-parse HEAD)"
g branch -q train
g checkout -q -b feature
echo patch > "$work/fork/feature.patch"; header 26; g add -A; g commit -qm "api 26"
a26="$(g rev-parse HEAD)"
g checkout -q train

cat > "$work/manifest.json" <<JSON
{"version": "cef-1.2.3-cmux.1", "cef": "1.2.3", "chromium": "1.0", "arch": "arm64", "repo": "o/cef",
 "tag": "cef-1.2.3-cmux.1", "asset": "old.tar.xz", "sha256": "old", "r2_bucket": "b", "r2_key": "cef/old",
 "debug_r2_key": "cef/olddebug", "fork_branch": "old", "fork_ref": "$pinned", "cmux_cef_api_version": 24,
 "x86_64": {"asset": "old-x86.tar.xz", "r2_key": "cef/oldx86", "fork_ref": "$pinned"}, "require_dcheck_off": true}
JSON
write_ledger() { # <train api> <26's defer or empty>
  local defer=""
  [[ -n "$2" ]] && defer=", \"defer\": \"$2\""
  cat > "$work/ledger.json" <<JSON
{"schema": 1, "owner": "t", "fork_repo": "o/cef", "train_branch": "train", "train_base": "main", "api": $1,
 "pinned": {"tag": "cef-1.2.3-cmux.1", "api": 24, "fork_ref": "$pinned"},
 "exports": [
  {"id": "a", "program": "p01", "api": 25, "fork_commit": "$a25", "summary": "feature a"},
  {"id": "b", "program": "p07", "api": 26, "fork_commit": "$a26", "summary": "feature b"$defer},
  {"id": "c", "program": "p07", "api": null, "fork_commit": "$a25", "summary": "feature c"}
 ]}
JSON
}

# 1. Ledger rules.
write_ledger 26 ""
train check --sources "$work/src" || fail "a good ledger fails check"
train check-manifest || fail "the pinned manifest fails check-manifest"
write_ledger 27 ""
train check --sources "$work/src" 2>"$work/err" && fail "a hole at 27 passes"
grep -q "no export claims api 27" "$work/err" || fail "hole message: $(cat "$work/err")"
write_ledger 26 "next train"
train check --sources "$work/src" 2>"$work/err" && fail "a deferred export at 26 in a 26 train passes"
grep -q "renumber it past the train" "$work/err" || fail "deferral message: $(cat "$work/err")"
write_ledger 26 ""
python3 - "$work/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["exports"].append(dict(d["exports"][0])); json.dump(d, open(p, "w"))
PY
train check --sources "$work/src" 2>"$work/err" && fail "an id listed twice passes"
grep -q "a: listed twice" "$work/err" || fail "duplicate message: $(cat "$work/err")"
write_ledger 26 ""
printf 'struct X {\n    static let pageGroupsForkAPI: Int32 = 31\n}\n' > "$work/src/Gate.swift"
printf 'inline constexpr int kExitForkAPI = 66;\n' > "$work/src/wire.h"
train check --sources "$work/src" 2>"$work/err" && fail "an unclaimed gate passes"
grep -q "Gate.swift:2: pageGroupsForkAPI checks api 31" "$work/err" || fail "gate message: $(cat "$work/err")"
grep -q kExitForkAPI "$work/err" && fail "an exit status is read as a gate"
rm "$work/src/Gate.swift"

# 2. Readiness against the fork.
train ready --fork-repo "$work/fork" 2>"$work/err" && fail "an unmerged export is ready"
grep -q "b (p07): ${a26:0:10} is not merged into train" "$work/err" || fail "unmerged message: $(cat "$work/err")"
grep -q "says CMUX_CEF_API_VERSION 25, the ledger 26" "$work/err" || fail "header message: $(cat "$work/err")"
printf '%s  %s\n' "$(printf 'a%.0s' {1..64})" cef-1.2.3-cmux.2-macos-arm64.tar.xz \
  "$(printf 'b%.0s' {1..64})" cef-1.2.3-cmux.2-macos-arm64-debug.tar.xz \
  "$(printf 'c%.0s' {1..64})" cef-1.2.3-cmux.2-macos-x86_64.tar.xz \
  "$(printf 'd%.0s' {1..64})" cef-1.2.3-cmux.2-macos-x86_64-debug.tar.xz > "$work/SHA256SUMS"
cp "$work/manifest.json" "$work/manifest.before"
train pin --fork-repo "$work/fork" --tag cef-1.2.3-cmux.2 --sums "$work/SHA256SUMS" --chromium 1.1 2>/dev/null \
  && fail "pin runs while the train is not ready"
cmp -s "$work/manifest.json" "$work/manifest.before" || fail "a refused pin changed the manifest"
g merge -q --no-edit feature
train ready --fork-repo "$work/fork" || fail "a merged train at the ledger's API is not ready"
train status --fork-repo "$work/fork" --json > "$work/status"
python3 - "$work/status" <<'PY' || fail "status: $(cat "$work/status")"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["header_api"] == 26 and s["exports"] == {"a": "merged", "b": "merged", "c": "merged"}, s
PY

# 3. The one pin.
train pin --fork-repo "$work/fork" --tag cef-1.2.3-cmux.2 --sums "$work/SHA256SUMS" --chromium 1.1 \
  --message "$work/msg" || fail "pin failed"
head_ref="$(g rev-parse HEAD)"
python3 - "$work/manifest.json" "$work/ledger.json" "$head_ref" <<'PY' || fail "pinned files"
import json, sys
m, l, ref = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
assert m["tag"] == m["version"] == "cef-1.2.3-cmux.2" and m["cef"] == "1.2.3" and m["chromium"] == "1.1", m
assert m["cmux_cef_api_version"] == 26 and m["fork_ref"] == ref and m["fork_branch"] == "train", m
assert m["sha256"] == "a" * 64 and m["debug_sha256"] == "b" * 64, m
assert m["url"] == "https://github.com/o/cef/releases/download/cef-1.2.3-cmux.2/cef-1.2.3-cmux.2-macos-arm64.tar.xz", m
x = m["x86_64"]
assert x["sha256"] == "c" * 64 and x["debug_sha256"] == "d" * 64 and x["fork_ref"] == ref, x
assert not {"r2_bucket", "r2_key", "debug_r2_key"} & set(m) and "r2_key" not in x, m
assert m["require_dcheck_off"] is True, m
assert l["pinned"] == {"tag": "cef-1.2.3-cmux.2", "api": 26, "fork_ref": ref}, l["pinned"]
assert l["exports"] == [], l["exports"]
PY
for want in "CEF: pin cef-1.2.3-cmux.2 (fork API 26" "fork API 24 -> 26" \
            "arm64 cef-1.2.3-cmux.2-macos-arm64.tar.xz $(printf 'a%.0s' {1..64})" \
            "x86_64 cef-1.2.3-cmux.2-macos-x86_64-debug.tar.xz $(printf 'd%.0s' {1..64})" \
            "  p01" "    a (API 25): feature a" "  p07" "    c (API 26 (numbered by this train)): feature c" \
            "publish-cef-r2.sh cef-1.2.3-cmux.2 --manifest"; do
  grep -qF -- "$want" "$work/msg" || fail "message lacks '$want': $(cat "$work/msg")"
done
train check-manifest || fail "the train's pin fails check-manifest"
train check --sources "$work/src" || fail "the ledger after the pin fails check"

# 4. A program's own bump is refused.
python3 - "$work/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["cmux_cef_api_version"] = 27; json.dump(m, open(p, "w"))
PY
train check-manifest 2>"$work/err" && fail "a bump outside the train passes"
grep -q "never one program's bump" "$work/err" || fail "bump message: $(cat "$work/err")"

# 5. The repo's own ledger, manifest and gates hold.
python3 "$tool" check || fail "the repo's train ledger fails check"
python3 "$tool" check-manifest || fail "the repo's manifest is not the train's pin"
echo "cef-fork-train: ok"
