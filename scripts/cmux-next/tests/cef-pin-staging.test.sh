#!/usr/bin/env bash
# cef-pin-staging.sh pin stages fleet `cmux-ci build cef` artifacts (a plain tar of one dist folder per arch) as
# the manifest only after checking them, and ensure-cef.sh then unpacks both arches from the controller store
# (the x86_64 one through its "dir"). A fake cmux-ci answers status and artifact; a fake controller serves the
# store. No network, no credential, no macOS tool.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { printf 'cef-pin-staging.test: %s\n' "$*" >&2; exit 1; }
FORK=c8953bc613cdb3dc82708d3647a12fe9d5d3c72e
OTHER=e07a2f786e11e77446d9838a91a55fea52efaeaa
HOST_SRC=$(git -C "$ROOT" rev-parse HEAD)
mkdir -p "$TMP/jobs" "$TMP/store"

# dist <name> <arch> <api> <fork ref> <dcheck json value> [cpu]: a fleet cef.tar in $TMP/store/<sha>, prints the sha.
# Its cef_cmux.h history lists 1..api except the numbers in SKIP_API (comma separated).
dist() {
  python3 - "$TMP/store" "$@" <<'PY'
import hashlib, io, json, os, sys, tarfile
store, name, arch, api, ref, dcheck = sys.argv[1:7]
cpu = {"arm64": 0x0100000C, "x86_64": 0x01000007}[sys.argv[7] if len(sys.argv) > 7 else arch]
folder = f"{name}-macos-{arch}"
gn = {"arm64": "arm64", "x86_64": "x64"}[arch]
skip = {int(n) for n in os.environ.get("SKIP_API", "").split(",") if n}
history = "".join(f"// {n:3d}: entry {n}\n//      1 of the fork lines then.)\n" for n in range(1, int(api) + 1) if n not in skip)
files = {
    "Chromium Embedded Framework.framework/Chromium Embedded Framework":
        (0xFEEDFACF).to_bytes(4, "little") + cpu.to_bytes(4, "little") + b"\0" * 24,
    "Chromium Embedded Framework.dSYM.tar.xz": b"dsym",
    "include/cef_cmux.h": f"// fork\n// Version of this API. Bump on any change.\n{history}#define CMUX_CEF_API_VERSION {api}\n".encode(),
    "archive.json": json.dumps({"cmux_ref": ref, "gn_args": {"target_cpu": gn, "dcheck_always_on": json.loads(dcheck)},
                                "name": f"cef_binary_154.0.0-cef-build.1+g{ref[:7]}+chromium-154.0.8037.98_macos{arch}_minimal"}).encode(),
}
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tar:
    for d in (folder, f"{folder}/Chromium Embedded Framework.framework", f"{folder}/include"):
        info = tarfile.TarInfo(d); info.type = tarfile.DIRTYPE; info.mode = 0o755; tar.addfile(info)
    for rel, data in files.items():
        info = tarfile.TarInfo(f"{folder}/{rel}"); info.size = len(data); info.mode = 0o755
        tar.addfile(info, io.BytesIO(data))
data = buf.getvalue()
sha = hashlib.sha256(data).hexdigest()
open(os.path.join(store, sha), "wb").write(data)
print(sha)
PY
}
# job <id> <json>: what `cmux-ci status <id>` prints.
job() { printf '%s\n' "$2" > "$TMP/jobs/$1.json"; }
cef_job() { # <id> <arch> <ref> <sha>
  job "$1" "{\"id\": \"$1\", \"kind\": \"cef\", \"state\": \"done\", \"variant\": \"$2\", \"ref\": \"$3\",
    \"artifact\": \"sha256:$4\", \"updated_at\": \"2026-10-26T01:46:11.411468Z\"}"
}
cat > "$TMP/cmux-ci" <<SH
#!/usr/bin/env bash
case "\$1" in
  status) cat "$TMP/jobs/\$2.json" ;;
  artifact) sha=\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"][7:])' "$TMP/jobs/\$2.json")
            cp "$TMP/store/\$sha" "\$3" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP/cmux-ci"

arm=$(dist cef-stage-c8953bc613cd-arm64 arm64 30 $FORK false)
x86=$(dist cef-stage-c8953bc613cd-x86-64 x86_64 30 $FORK false)
cef_job armjob arm64 $FORK "$arm"
cef_job x86job x86_64 $FORK "$x86"
printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01host' > "$TMP/host"
host=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TMP/host")
cp "$TMP/host" "$TMP/store/$host"
job hoststep "{\"id\": \"hoststep\", \"kind\": \"ci-step\", \"state\": \"done\", \"script\": \"scripts/ci/cmux-remote-browser-host-build.sh\",
  \"ref\": \"$HOST_SRC\", \"inputs\": {\"cef\": \"sha256:$arm\"}, \"artifact\": \"sha256:$host\",
  \"updated_at\": \"2026-10-26T03:00:00Z\"}"

pin() { # <args...>: status in $status, output in $out
  status=0
  out=$(CMUX_CI="$TMP/cmux-ci" bash "$ROOT/scripts/cmux-next/cef-pin-staging.sh" pin --manifest "$TMP/manifest.json" \
    --rb-host-pin "$TMP/pin.json" --work "$TMP/work" "$@" 2>&1) || status=$?
}
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v)' "$@"; }

pin --arm64 armjob --x86_64 x86job --rb-host-step hoststep --fork-branch cmux/8037-helper-items
[[ "$status" == 0 ]] || fail "a valid pin failed: $out"
m="$TMP/manifest.json"
[[ "$(field "$m" version)" == cef-stage-c8953bc613cd-arm64-macos-arm64 ]] || fail "version is not the arm64 dist folder"
[[ "$(field "$m" sha256)" == "$arm" && "$(field "$m" x86_64.sha256)" == "$x86" ]] || fail "the pin does not name the job artifacts"
[[ "$(field "$m" x86_64.dir)" == cef-stage-c8953bc613cd-x86-64-macos-x86_64 ]] || fail "x86_64 names no dist folder"
[[ "$(field "$m" cmux_cef_api_version)" == 30 && "$(field "$m" fork_ref)" == "$FORK" ]] || fail "API or fork ref wrong"
[[ "$(field "$m" chromium)" == 154.0.8037.98 && "$(field "$m" require_dcheck_off)" == True ]] || fail "chromium or dcheck wrong"
[[ "$(field "$m" staging.store_expires)" == 2026-11-09 ]] || fail "store_expires is not 14 days after the build"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(any(k.startswith("r2") or k in ("url", "tag") for k in m))' "$m" ||
  fail "a staging pin names an R2 object or a GitHub release"
[[ "$(field "$TMP/pin.json" sha256)" == "$host" && "$(field "$TMP/pin.json" cef_sha256)" == "$arm" ]] || fail "host pin wrong"
[[ "$(field "$TMP/pin.json" crate_tree)" == "$(git -C "$ROOT" rev-parse "$HOST_SRC:cmux-tui/crates/cmux-remote-browser-host")" ]] ||
  fail "host pin crate_tree is not the source's"
[[ "$(field "$TMP/pin.json" staging.store_expires)" == 2026-11-09 ]] || fail "the host pin is not marked staging"
[[ "$(field "$m" debug_symbols)" == "Chromium Embedded Framework.dSYM.tar.xz" ]] || fail "the pin names no dSYM archive"
python3 -c 'import json,sys; sys.exit("missing_api" in json.load(open(sys.argv[1])))' "$m" ||
  fail "a fork with every API number records missing_api"

# ensure-cef.sh unpacks both arches from the store: plain tar, the x86_64 one from its own folder.
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, sys
store = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/v1/artifacts/sha256:") and self.path.endswith("/url"):
            sha = self.path[len("/v1/artifacts/sha256:"):-4]
            body = json.dumps({"url": f"http://127.0.0.1:{self.server.server_port}/blob/{sha}"}).encode()
        elif self.path.startswith("/blob/") and os.path.isfile(os.path.join(store, self.path[6:])):
            body = open(os.path.join(store, self.path[6:]), "rb").read()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(store, "..", "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$TMP/server.py" "$TMP/store" & server_pid=$!
for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
store_url="http://127.0.0.1:$(cat "$TMP/port")"
ensure() { # <cache dir> <env and args...>: ensure-cef.sh on the staged manifest; status in $status, stderr in $err
  local cache="$1"; shift
  status=0
  got=$(env -u GH_TOKEN -u GITHUB_TOKEN -u CONFIGURATION -u OTHER_SWIFT_FLAGS -u CMUX_BENCH_HOOKS_RELOAD CMUX_CEF_MANIFEST="$m" CMUX_CEF_CACHE_DIR="$cache" \
    CMUX_CEF_STORE_URL="$store_url" CMUX_CEF_TODAY=2026-10-27 "$@" 2>"$TMP/ensure.err") || status=$?
  err=$(cat "$TMP/ensure.err")
}
for arch in arm64 x86_64; do
  ensure "$TMP/cache" bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --arch $arch
  [[ "$status" == 0 && -f "$got/include/cef_cmux.h" ]] || fail "ensure-cef.sh --arch $arch did not unpack the staged dist: $err"
done

# A staging pin fails even with --optional, so no build ships without the engine.
ensure_refused() { # <what> <expected message part> <ensure args...>
  local what="$1" want="$2"; shift 2
  ensure "$@"
  [[ "$status" != 0 && -z "$got" ]] || fail "$what: ensure exited $status with '$got'"
  grep -q -- "$want" <<<"$err" || fail "$what: no '$want' in: $err"
}
ensure_refused "an expired staging pin, cached" "expired on 2026-11-09" \
  "$TMP/cache" CMUX_CEF_TODAY=2026-11-09 bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --optional
ensure_refused "a staging pin in a Release build" "a Release build embeds only a released pin" \
  "$TMP/cache" CONFIGURATION=Release bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --optional
ensure_refused "a staging pin in a Release build with other Swift flags" "a Release build embeds only a released pin" \
  "$TMP/cache" CONFIGURATION=Release OTHER_SWIFT_FLAGS='$(inherited) -DCMUX_BENCH_HOOKSX' \
  bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --optional
# The flag text without reload.sh's setting (a shipped pipeline's flags, or -Xcc -D, which Swift never compiles): refused.
ensure_refused "a staging pin in a Release build with the flag but no reload bench setting" "a Release build embeds only a released pin" \
  "$TMP/cache" CONFIGURATION=Release OTHER_SWIFT_FLAGS='$(inherited) -Xcc -DCMUX_BENCH_HOOKS' \
  bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --optional
ensure_refused "a staging pin in a Release build with the reload bench setting but no flag" "a Release build embeds only a released pin" \
  "$TMP/cache" CONFIGURATION=Release CMUX_BENCH_HOOKS_RELOAD=1 bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --optional
# reload.sh's bench build (Release + -DCMUX_BENCH_HOOKS + CMUX_BENCH_HOOKS_RELOAD=1) never ships, so it embeds the
# staging pin (first-seconds-lag.md step 4).
ensure "$TMP/cache" CONFIGURATION=Release CMUX_BENCH_HOOKS_RELOAD=1 OTHER_SWIFT_FLAGS='$(inherited) -DCMUX_BENCH_HOOKS' \
  bash "$ROOT/scripts/cmux-next/ensure-cef.sh"
[[ "$status" == 0 && -n "$got" ]] || fail "a bench Release build refused the staging pin: $err"
ensure_refused "a staging pin off the tailnet" "served only by the fleet controller store" \
  "$TMP/cold" CMUX_CEF_NO_STORE=1 bash "$ROOT/scripts/cmux-next/ensure-cef.sh" --optional --arch x86_64
ensure "$TMP/cache" CMUX_CEF_TODAY=2026-11-07 bash "$ROOT/scripts/cmux-next/ensure-cef.sh"
[[ "$status" == 0 && -n "$got" ]] || fail "a staging pin 2 days before expiry failed: $err"
grep -q "expires on 2026-11-09 (2 days)" <<<"$err" || fail "no expiry warning 2 days before: $err"

# The remote browser host pin follows the same rules.
host_env=(CMUX_NEXT_RB_HOST_PIN="$TMP/pin.json" CMUX_NEXT_RB_HOST_CACHE_DIR="$TMP/rbh")
ensure "$TMP/cache" "${host_env[@]}" bash "$ROOT/scripts/cmux-next/ensure-remote-browser-host.sh"
[[ "$status" == 0 && -f "$got" ]] || fail "ensure-remote-browser-host.sh did not fetch the staged host: $err"
ensure_refused "a staging host pin off the tailnet" "served only by the fleet controller store" \
  "$TMP/cache" "${host_env[@]}" CMUX_NEXT_RB_HOST_CACHE_DIR="$TMP/rbh-cold" CMUX_RB_HOST_NO_STORE=1 \
  bash "$ROOT/scripts/cmux-next/ensure-remote-browser-host.sh" --optional
ensure_refused "an expired staging host pin, cached" "expired on 2026-11-09" \
  "$TMP/cache" "${host_env[@]}" CMUX_CEF_TODAY=2026-11-10 bash "$ROOT/scripts/cmux-next/ensure-remote-browser-host.sh" --optional
ensure_refused "a staging host pin in a Release build" "a Release build embeds only a published host" \
  "$TMP/cache" "${host_env[@]}" CONFIGURATION=Release bash "$ROOT/scripts/cmux-next/ensure-remote-browser-host.sh" --optional
ensure_refused "a staging host pin in a Release build with the flag but no reload bench setting" "a Release build embeds only a published host" \
  "$TMP/cache" "${host_env[@]}" CONFIGURATION=Release OTHER_SWIFT_FLAGS='$(inherited) -DCMUX_BENCH_HOOKS' \
  bash "$ROOT/scripts/cmux-next/ensure-remote-browser-host.sh" --optional
ensure "$TMP/cache" "${host_env[@]}" CONFIGURATION=Release CMUX_BENCH_HOOKS_RELOAD=1 OTHER_SWIFT_FLAGS='$(inherited) -DCMUX_BENCH_HOOKS' \
  bash "$ROOT/scripts/cmux-next/ensure-remote-browser-host.sh"
[[ "$status" == 0 && -f "$got" ]] || fail "a bench Release build refused the staging host pin: $err"

# Refusals leave the manifest as it was.
cp "$m" "$TMP/manifest.before"
refused() { # <what> <expected message part> <args...>
  local what="$1" want="$2"; shift 2
  pin "$@"
  [[ "$status" != 0 ]] || fail "$what was staged"
  grep -q -- "$want" <<<"$out" || fail "$what: no '$want' in: $out"
  cmp -s "$m" "$TMP/manifest.before" || fail "$what changed the manifest"
}
old=$(dist cef-old arm64 27 $OTHER false); cef_job oldjob arm64 $OTHER "$old"
refused "an API 27 build" "below --min-api 30" --arm64 oldjob
x86other=$(dist cef-other x86_64 30 $OTHER false); cef_job x86other x86_64 $OTHER "$x86other"
refused "arches of two fork commits" "stage one fork build" --arm64 armjob --x86_64 x86other
debug=$(dist cef-debug arm64 30 $FORK true); cef_job debugjob arm64 $FORK "$debug"
refused "a DCHECK build" "dcheck_always_on = false" --arm64 debugjob
wrongcpu=$(dist cef-wrongcpu arm64 30 $FORK false x86_64); cef_job wrongcpu arm64 $FORK "$wrongcpu"
refused "an x86_64 binary as arm64" "Mach-O for arm64" --arm64 wrongcpu
cef_job liar arm64 $OTHER "$arm"
refused "a job whose dist names another commit" "archive.json names" --arm64 liar
job running '{"id": "running", "kind": "cef", "state": "running", "variant": "arm64"}'
refused "an unfinished build" "not a done cef build" --arm64 running
job otherhost "{\"id\": \"otherhost\", \"state\": \"done\", \"script\": \"scripts/ci/cmux-remote-browser-host-build.sh\",
  \"ref\": \"$HOST_SRC\", \"inputs\": {\"cef\": \"sha256:$old\"}, \"artifact\": \"sha256:$host\"}"
refused "a host linked to another CEF" "not the staged arm64" --arm64 armjob --rb-host-step otherhost
cp "$TMP/pin.json" "$TMP/pin.good"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["cef_sha256"]="0"*64; json.dump(p, open(sys.argv[1], "w"))' "$TMP/pin.json"
refused "a pin the host pin does not link, without --rb-host-step" "every DEV build would fail" --arm64 armjob
cp "$TMP/pin.good" "$TMP/pin.json"
pin --arm64 armjob --x86_64 x86job --fork-branch cmux/8037-helper-items
[[ "$status" == 0 ]] && cmp -s "$m" "$TMP/manifest.before" || fail "a pin the host pin already links failed: $out"

# A fork line that skips API numbers (API 30 without 28 and 29) is staged only when they are named exactly.
gap=$(SKIP_API=28,29 dist cef-gap arm64 30 $FORK false); cef_job gapjob arm64 $FORK "$gap"
job gaphost "{\"id\": \"gaphost\", \"state\": \"done\", \"script\": \"scripts/ci/cmux-remote-browser-host-build.sh\",
  \"ref\": \"$HOST_SRC\", \"inputs\": {\"cef\": \"sha256:$gap\"}, \"artifact\": \"sha256:$host\",
  \"updated_at\": \"2026-10-27T00:00:00Z\"}"
refused "a fork missing APIs 28 and 29" "lacks 28,29" --arm64 gapjob --rb-host-step gaphost
refused "a fork missing APIs 28 and 29, one named" "accept-missing-api names 28" --arm64 gapjob --rb-host-step gaphost --accept-missing-api 28
pin --arm64 gapjob --rb-host-step gaphost --accept-missing-api 29,28 --manifest "$TMP/gap.json"
[[ "$status" == 0 && "$(field "$TMP/gap.json" missing_api)" == "[28, 29]" ]] || fail "missing APIs 28,29 not recorded: $out"
cp "$TMP/pin.good" "$TMP/pin.json"

# fork-api: the app's debug.cef fork API against the pin, and the app's gates against its missing numbers.
mkdir -p "$TMP/app/Packages/macOS/CmuxNext/Sources/X" "$TMP/app/Packages/macOS/CmuxNext/ChromiumHost/src"
printf 'struct F {\n    static let pathsForkAPI: Int32 = 29\n    var omnibox: Bool { runtime.forkAPIVersion >= 12 }\n}\n' \
  > "$TMP/app/Packages/macOS/CmuxNext/Sources/X/F.swift"
printf 'inline constexpr int kMinForkAPI = 27;\ninline constexpr int kExitForkAPI = 66;\n' \
  > "$TMP/app/Packages/macOS/CmuxNext/ChromiumHost/src/wire.h"
fork_api() { # <manifest> <fork api>: status in $status, rows in $out
  printf '{"facts": {"fork_api": %s}}\n' "$2" > "$TMP/verify-on.json"
  status=0
  out=$(python3 "$ROOT/scripts/cmux-next/cef_pin_staging.py" fork-api --verify "$TMP/verify-on.json" --manifest "$1" \
    --root "$TMP/app") || status=$?
}
fork_api "$m" 30
[[ "$status" == 0 ]] && grep -q '^PASS fork-api:' <<<"$out" && grep -q '^PASS fork-api-gaps' <<<"$out" ||
  fail "fork API 30 on a whole API 30 pin did not pass: $out"
fork_api "$m" 24
[[ "$status" != 0 ]] && grep -q '^FAIL fork-api:' <<<"$out" || fail "fork API 24 on an API 30 pin passed: $out"
fork_api "$TMP/gap.json" 30
[[ "$status" != 0 ]] && grep -q '^FAIL fork-api-gaps.*X/F.swift:2 pathsForkAPI = 29' <<<"$out" ||
  fail "a gate on missing API 29 passed: $out"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["missing_api"]=[12, 28]; json.dump(m, open(sys.argv[1], "w"))' "$TMP/gap.json"
fork_api "$TMP/gap.json" 30
grep -q '^FAIL fork-api-gaps.*X/F.swift:3 forkAPIVersion = 12' <<<"$out" || fail "a forkAPIVersion >= 12 gate on missing 12 passed: $out"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["missing_api"]=[28]; json.dump(m, open(sys.argv[1], "w"))' "$TMP/gap.json"
fork_api "$TMP/gap.json" 30
[[ "$status" == 0 ]] || fail "missing API 28 that no gate names failed: $out"
echo "cef-pin-staging.test: ok"
