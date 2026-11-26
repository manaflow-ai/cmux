# shellcheck shell=bash
# Shared helpers for iOS dev launches: tag -> identity and the app-receipt
# readiness gate. Sourced by scripts/dev-setup.sh, scripts/mobile-dev-launch.sh,
# scripts/verify-iphone-auth.sh, scripts/run-iroh-release-gate.sh and the
# reload scripts so the bundle-id / slug derivation lives in exactly ONE place
# (it MUST match reload.sh / cmux-debug-cli.sh exactly).
#
# The tagged-Mac pairing helpers (enable the pairing host, ensure the Mac,
# mint an attach ticket) are gone: the cmux-next Mac app no longer runs the
# iroh phone listener (mobile.attach_ticket.create / mobile.rpc.ready).

# Resolve the backend shared by a tagged Mac and its mobile build. Localhost
# remains the default for ordinary simulator work. Physical-device dogfood can
# select a trusted shared backend without giving every developer the relay
# fleet's private JWT signing key.
cmux_attach_resolve_dev_api_base_url() {
  local fallback="$1"
  if [[ -n "${CMUX_DEV_API_BASE_URL:-}" ]]; then
    printf '%s' "$CMUX_DEV_API_BASE_URL"
  else
    printf '%s' "$fallback"
  fi
}

# Raw slug WITHOUT the empty-input fallback: lowercase, ASCII non-[a-z0-9] -> '-',
# trimmed/collapsed. Empty when the tag has no ASCII alphanumerics. The ASCII
# class is deliberate (matches reload.sh + cmux-debug-cli.sh socket/DerivedData
# naming); a locale-sensitive class would keep non-ASCII letters the slug drops.
cmux_attach__slug_raw() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

# slug: raw slug, falling back to "agent" only for an otherwise-empty result.
cmux_attach__slug() {
  local cleaned
  cleaned="$(cmux_attach__slug_raw "$1")"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# True iff the tag yields a real (non-empty) slug, i.e. it is not the empty-input
# fallback. Uses the SAME ASCII transform as the slug (not locale-sensitive
# [:alnum:], which would accept non-ASCII letters like "é" that the slug drops).
# Tag identity is correctness-critical (it selects the bundle id / socket / Mac
# app), so entry points must fail closed when this is false rather than let the
# tag collapse onto the shared fallback identity and target an unrelated app.
cmux_attach_tag_has_alnum() {
  [[ -n "$(cmux_attach__slug_raw "$1")" ]]
}

# Cloud registry/presence instance tags are capped at 64 JavaScript UTF-16
# units. Slugs are ASCII, so shell character count is the same measurement.
# Reject instead of truncating because truncation could collapse two tagged
# builds onto the same instance identity. The same slug names a dev build's
# space on cmux-mobile-api (`X-Cmux-Build-Space: dev:<slug>`,
# cmux-next-ios/PROTOCOL.md "Build spaces"), which refuses a slug over 64 and
# `default` the same way, so the two never disagree on a tag.
cmux_attach_tag_within_cloud_limit() {
  local slug
  slug="$(cmux_attach__slug_raw "$1")"
  (( ${#slug} <= 64 ))
}

# Tags that already name an app of their own, so no tagged dev build may take one: `default` is the stable
# app instance (cmux-mobile-api refuses dev:default too); `dev` is cmux Dev (dev.cmux.mobile.dev,
# cmux-next-ios/scripts/try.sh, whose fallback for an older commit builds in dev:dev); `demo` and `prod` are
# demo-build.sh's Demo and Production installs (dev.cmux.mobile.demo, dev.cmux.mobile.prod). A Mac tagged
# one of them would take that app for its own tag's phone, and a hand-off would install over it.
CMUX_ATTACH_RESERVED_TAGS="default dev demo prod"

# True iff the tag's slug is one of CMUX_ATTACH_RESERVED_TAGS.
cmux_attach_tag_reserved() {
  local slug
  slug="$(cmux_attach__slug_raw "$1")"
  [[ -n "$slug" && " $CMUX_ATTACH_RESERVED_TAGS " == *" $slug "* ]]
}

# Validate a dev-build tag before it selects an app bundle, socket, or cloud
# presence identity. "default" is the stable app instance sentinel, so allowing
# a dev tag to sanitize to that value would make the dev build impersonate the
# stable instance even though its bundle and socket are otherwise isolated.
#
# A tag must be canonical: its own slug (lowercase ASCII letters, digits and
# single inner dashes, at most 64). The tag is the build space `dev:<slug>` of
# its Mac and iPhone builds, and the slug maps foo_bar, foo.bar, Foo-Bar and
# foo--bar to one space, so two tasks with "different" tags would share one
# space and pair with each other's builds. Every spelling but the slug itself
# is refused, with the slug to use instead.
cmux_attach_validate_dev_tag() {
  local tag="$1" slug
  if ! cmux_attach_tag_has_alnum "$tag"; then
    echo "error: --tag '$tag' has no letters or digits; pick a tag with at least one alphanumeric character" >&2
    return 1
  fi
  slug="$(cmux_attach__slug_raw "$tag")"
  case "$slug" in
    default)
      echo "error: --tag must not sanitize to 'default'; that tag is reserved for the stable app instance" >&2
      return 1 ;;
    dev)
      echo "error: --tag dev is the cmux Dev app's (dev.cmux.mobile.dev, cmux-next-ios/scripts/try.sh); pick another tag" >&2
      return 1 ;;
    demo|prod)
      echo "error: --tag $slug is demo-build.sh's $([[ $slug == demo ]] && echo Demo || echo Production) install (dev.cmux.mobile.$slug); pick another tag" >&2
      return 1 ;;
  esac
  if ! cmux_attach_tag_within_cloud_limit "$tag"; then
    echo "error: --tag must sanitize to at most 64 characters" >&2
    return 1
  fi
  if [[ "$tag" != "$slug" ]]; then
    echo "error: --tag '$tag' is not a canonical tag: a tag is lowercase letters, digits and single dashes inside, as it is its builds' cloud build space (dev:$slug, which every spelling of it would share); use --tag $slug" >&2
    return 1
  fi
}

# bundle id segment: lowercase, non-alnum -> '.', trimmed/collapsed.
cmux_attach__bundle_seg() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# The tagged macOS Debug app's bundle id.
cmux_attach_mac_bundle_id() {
  printf 'com.cmuxterm.app.debug.%s' "$(cmux_attach__bundle_seg "$1")"
}

# Unsigned Simulator apps have no application-identifier entitlement, so iOS
# rejects their Keychain reads. Produce a deterministic per-bundle UUID for the
# simulator-only authoritative identity store. The launcher passes it directly
# into the app process; writing the external defaults domain as well keeps the
# value inspectable from simctl. Recreated isolated simulators for the same tag
# reuse one broker device slot instead of leaking a slot on every verification.
cmux_attach_seed_simulator_device_id() {
  local simulator_id="${1:?simulator id is required}"
  local bundle_id="${2:?bundle id is required}"
  local device_id
  device_id="$(CMUX_SIMULATOR_BUNDLE_ID="$bundle_id" /usr/bin/python3 - <<'PY'
import os
import uuid

bundle_id = os.environ["CMUX_SIMULATOR_BUNDLE_ID"]
print(uuid.uuid5(uuid.NAMESPACE_URL, f"cmux-ios-simulator-device:{bundle_id}"))
PY
)"
  xcrun simctl spawn "$simulator_id" defaults write \
    "$bundle_id" cmux.deviceRegistry.iosDeviceID -string "$device_id"
  printf '%s' "$device_id"
}

# Deterministic client identity for one dogfood bundle on one concrete target.
# The launch script injects it into the DEBUG app and uses the same value to
# reject readiness events emitted by a different phone or simulator.
cmux_attach_dogfood_client_id() {
  local bundle_id="${1:?bundle id is required}"
  local target_id="${2:?target id is required}"
  CMUX_DOGFOOD_BUNDLE_ID="$bundle_id" \
  CMUX_DOGFOOD_TARGET_ID="$target_id" \
    /usr/bin/python3 - <<'PY'
import os
import uuid

bundle_id = os.environ["CMUX_DOGFOOD_BUNDLE_ID"]
target_id = os.environ["CMUX_DOGFOOD_TARGET_ID"]
print(uuid.uuid5(uuid.NAMESPACE_URL, f"cmux-ios-dogfood-client:{bundle_id}:{target_id}"))
PY
}

# The locally-built tagged macOS Debug .app bundle path (cloud/local reloads both
# download/install here). Both the DerivedData dir AND the .app basename use the
# sanitized slug, matching reload.sh (`APP_NAME="cmux DEV ${TAG_SLUG}"`); the raw
# tag would miss for any tag whose slug differs (e.g. "Fix Foo" -> "fix-foo").
cmux_attach_mac_app_path() {
  local slug
  slug="$(cmux_attach__slug "$1")"
  printf '%s/Library/Developer/Xcode/DerivedData/cmux-%s/Build/Products/Debug/cmux DEV %s.app' \
    "$HOME" "$slug" "$slug"
}

# Resolve metadata from the bundle that is actually installed on the target.
# The checkout SHA remains useful for diagnosing the launcher, but it is not
# evidence that the app on the simulator/device came from that checkout. Keep
# this probe best-effort for physical devices where iOS does not expose the
# app executable, while requiring the simulator container to be readable.
cmux_attach_installed_bundle_metadata() {
  local target="$1" target_id="$2" bundle_id="$3" app_path="${CMUX_INSTALLED_APP_PATH:-}"
  if [[ -z "$app_path" && "$target" == "simulator_injection" ]]; then
    app_path="$(xcrun simctl get_app_container "$target_id" "$bundle_id" app 2>/dev/null || true)"
  fi
  CMUX_INSTALLED_TARGET="$target" \
  CMUX_INSTALLED_TARGET_ID="$target_id" \
  CMUX_INSTALLED_BUNDLE_ID="$bundle_id" \
  CMUX_INSTALLED_APP_PATH="$app_path" \
    /usr/bin/python3 - <<'PY'
import hashlib
import json
import os
import plistlib
from pathlib import Path

target = os.environ["CMUX_INSTALLED_TARGET"]
target_id = os.environ["CMUX_INSTALLED_TARGET_ID"]
bundle_id = os.environ["CMUX_INSTALLED_BUNDLE_ID"]
app_path = os.environ.get("CMUX_INSTALLED_APP_PATH", "")
metadata = {
    "bundle_id": bundle_id,
    "target": target,
    "target_id": target_id,
    "source": "installed_bundle",
}
if not app_path:
    metadata["metadata_source"] = "device_install_query_unavailable"
    metadata["executable_sha256"] = None
    print(json.dumps(metadata, sort_keys=True))
    raise SystemExit(0)

app = Path(app_path)
plist_path = app / "Info.plist"
if not app.is_dir() or not plist_path.is_file():
    raise SystemExit(f"installed app container is missing Info.plist: {app}")
with plist_path.open("rb") as stream:
    plist = plistlib.load(stream)
if plist.get("CFBundleIdentifier") != bundle_id:
    raise SystemExit("installed bundle identifier does not match the launched bundle")
executable_name = plist.get("CFBundleExecutable")
if not isinstance(executable_name, str) or not executable_name:
    raise SystemExit("installed bundle has no executable name")
executable = app / executable_name
if not executable.is_file():
    raise SystemExit(f"installed bundle executable is missing: {executable}")
metadata.update({
    "metadata_source": "simulator_container" if target == "simulator_injection" else "signed_app_bundle",
    "short_version": plist.get("CFBundleShortVersionString"),
    "build_version": plist.get("CFBundleVersion"),
    "source_git_sha": plist.get("CMUXGitSHA"),
    "dev_tag": plist.get("CMUXDevTag"),
    "executable_name": executable_name,
    "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
})
print(json.dumps(metadata, sort_keys=True))
PY
}

cmux_attach_monotonic_milliseconds() {
  /usr/bin/python3 -c '
import time

print(time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000)
'
}

# --- app-receipt readiness ----------------------------------------------------
# A dogfood app can prove "signed in" without a tagged Mac pairing. Such an
# app declares Info.plist CMUXDogfoodReadiness = app-receipt-v1. After it signs
# in and one authenticated API call succeeds, its DEBUG build writes a
# secret-free JSON receipt into its own data container, echoing the launch
# nonce (CMUX_DOGFOOD_READINESS_NONCE) so a stale file can never pass. An app
# without the key reports mac-rpc, which has no target now: the cmux-next Mac
# app no longer publishes mobile.rpc.ready, so callers refuse that mode.
CMUX_ATTACH_APP_RECEIPT_RELATIVE_PATH="Library/Application Support/cmux-dogfood/readiness.json"

# Print the readiness mode one app bundle declares: "app-receipt" or "mac-rpc".
# A missing bundle, Info.plist, or key means mac-rpc. An unknown value fails
# closed (exit 2) so a newer app contract cannot be silently treated as an old
# one.
cmux_attach_app_readiness_mode() {
  local app_path="${1:-}"
  if [[ -z "$app_path" || ! -f "$app_path/Info.plist" ]]; then
    printf 'mac-rpc'
    return 0
  fi
  /usr/bin/python3 - "$app_path/Info.plist" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as stream:
        info = plistlib.load(stream)
except Exception:
    print("mac-rpc", end="")
    raise SystemExit(0)
value = info.get("CMUXDogfoodReadiness") if isinstance(info, dict) else None
if value is None:
    print("mac-rpc", end="")
elif value == "app-receipt-v1":
    print("app-receipt", end="")
else:
    print(f"error: unsupported CMUXDogfoodReadiness value {value!r}", file=sys.stderr)
    raise SystemExit(2)
PY
}

# Fresh single-use launch nonce. Not a secret; it only binds a receipt to one
# launch. Callers inject it through SIMCTL_CHILD_/DEVICECTL_CHILD_, never argv.
cmux_attach_readiness_nonce() {
  /usr/bin/python3 -c 'import secrets; print(secrets.token_hex(16))'
}

# Validate one app readiness receipt and print a sanitized, allowlisted copy.
#   $1 receipt file, $2 expected nonce, $3 client id, $4 bundle id,
#   $5 expected account, $6 required session_source ("" accepts either).
# Exit 0 valid; 1 not (yet) valid for this launch (missing, unreadable, stale
# nonce: keep waiting); 3 definitive failure for this launch (the nonce matches
# but identity, account, session source, or shape is wrong: stop waiting).
cmux_attach_validate_app_receipt() {
  local receipt="$1" nonce="$2" client_id="$3" bundle_id="$4" account="$5" required_source="${6:-}"
  [[ -f "$receipt" ]] || { echo "app readiness receipt is missing" >&2; return 1; }
  CMUX_RECEIPT_NONCE="$nonce" \
  CMUX_RECEIPT_CLIENT_ID="$client_id" \
  CMUX_RECEIPT_BUNDLE_ID="$bundle_id" \
  CMUX_RECEIPT_ACCOUNT="$account" \
  CMUX_RECEIPT_SOURCE="$required_source" \
    /usr/bin/python3 - "$receipt" <<'PY'
import json
import os
import sys

def retry(reason):
    print(reason, file=sys.stderr)
    raise SystemExit(1)

def reject(reason):
    print(reason, file=sys.stderr)
    raise SystemExit(3)

nonce = os.environ["CMUX_RECEIPT_NONCE"]
if not nonce:
    reject("launcher has no readiness nonce")
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        receipt = json.load(stream)
except (OSError, ValueError):
    retry("app readiness receipt is not readable JSON yet")
if not isinstance(receipt, dict):
    retry("app readiness receipt is not a JSON object")
if receipt.get("nonce") != nonce:
    retry("app readiness receipt is from another launch (nonce mismatch)")

for key in receipt:
    lowered = str(key).lower()
    if any(word in lowered for word in ("token", "password", "secret", "cookie")):
        reject(f"app readiness receipt carries a forbidden secret-like field: {key}")
schema = receipt.get("schema")
if isinstance(schema, bool) or schema != 1:
    reject("app readiness receipt has an unsupported schema")
string_fields = ("client_id", "bundle_id", "dev_tag", "git_sha", "api_base_url",
                 "account_email", "user_id", "session_source", "written_at")
for key in string_fields:
    if key in receipt and not isinstance(receipt[key], str):
        reject(f"app readiness receipt field {key} is not a string")
for key in ("client_id", "bundle_id", "account_email", "session_source", "written_at"):
    if not receipt.get(key):
        reject(f"app readiness receipt is missing {key}")
if receipt["client_id"] != os.environ["CMUX_RECEIPT_CLIENT_ID"]:
    reject("app readiness receipt names a different dogfood client id")
if receipt["bundle_id"] != os.environ["CMUX_RECEIPT_BUNDLE_ID"]:
    reject("app readiness receipt names a different bundle id")
expected_account = os.environ["CMUX_RECEIPT_ACCOUNT"].strip().lower()
if not expected_account or receipt["account_email"].strip().lower() != expected_account:
    reject("app is signed in to a different account than the selected profile")
source = receipt["session_source"]
if source not in ("auto_login", "restored"):
    reject(f"app readiness receipt has an unknown session_source {source!r}")
required_source = os.environ["CMUX_RECEIPT_SOURCE"]
if required_source and source != required_source:
    reject(f"app session_source is {source}, expected {required_source}")

sanitized = {key: receipt[key] for key in string_fields if key in receipt}
sanitized["schema"] = 1
sanitized["account_email"] = receipt["account_email"].strip().lower()
print(json.dumps(sanitized, sort_keys=True))
PY
}

# Copy the app's readiness receipt out of its data container into $4.
#   physical_device: devicectl copy from the appDataContainer domain (works for
#   development-signed builds with get-task-allow).
#   simulator_injection: simctl data container on the host filesystem.
cmux_attach_fetch_app_receipt() {
  local target="$1" target_id="$2" bundle_id="$3" destination="$4" container
  case "$target" in
    physical_device)
      xcrun devicectl device copy from \
        --device "$target_id" \
        --domain-type appDataContainer \
        --domain-identifier "$bundle_id" \
        --source "$CMUX_ATTACH_APP_RECEIPT_RELATIVE_PATH" \
        --destination "$destination" \
        --timeout 15 >/dev/null 2>&1 || return 1
      ;;
    simulator_injection)
      container="$(xcrun simctl get_app_container "$target_id" "$bundle_id" data 2>/dev/null)" || return 1
      [[ -n "$container" && -f "$container/$CMUX_ATTACH_APP_RECEIPT_RELATIVE_PATH" ]] || return 1
      cp "$container/$CMUX_ATTACH_APP_RECEIPT_RELATIVE_PATH" "$destination" || return 1
      ;;
    *)
      echo "error: unknown readiness target '$target'" >&2
      return 2
      ;;
  esac
  [[ -f "$destination" ]]
}

# Bounded wait for a valid app receipt for this launch. Prints the sanitized
# receipt on success. Retries use a capped backoff (1, 2, 4, 8, 8 ... s) and
# stop at the deadline or at the first definitive mismatch for this nonce.
#   $1 target, $2 target id, $3 bundle id, $4 nonce, $5 client id,
#   $6 expected account, $7 required session_source ("" = either),
#   $8 timeout seconds.
cmux_attach_wait_for_app_receipt() {
  local target="$1" target_id="$2" bundle_id="$3" nonce="$4" client_id="$5"
  local account="$6" required_source="$7" timeout="$8"
  local deadline delay=1 workdir status output last_reason="no receipt published yet"
  deadline=$((SECONDS + timeout))
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-app-receipt.XXXXXX")" || return 1
  while :; do
    rm -f "$workdir/readiness.json" "$workdir/reason"
    if cmux_attach_fetch_app_receipt "$target" "$target_id" "$bundle_id" "$workdir/readiness.json"; then
      status=0
      output="$(cmux_attach_validate_app_receipt "$workdir/readiness.json" \
        "$nonce" "$client_id" "$bundle_id" "$account" "$required_source" \
        2>"$workdir/reason")" || status=$?
      if [[ "$status" -eq 0 ]]; then
        rm -rf "$workdir"
        printf '%s\n' "$output"
        return 0
      fi
      last_reason="$(head -n1 "$workdir/reason" 2>/dev/null || true)"
      [[ -n "$last_reason" ]] || last_reason="receipt validation failed"
      if [[ "$status" -eq 3 ]]; then
        rm -rf "$workdir"
        printf 'error: %s\n' "$last_reason" >&2
        return 1
      fi
    else
      last_reason="no receipt published yet"
    fi
    if (( SECONDS + delay > deadline )); then
      break
    fi
    sleep "$delay"
    if (( delay < 8 )); then
      delay=$((delay * 2))
    fi
  done
  rm -rf "$workdir"
  printf 'error: no valid app readiness receipt within %ss: %s\n' "$timeout" "$last_reason" >&2
  return 1
}

# Durable, secret-free launcher receipt for the app-receipt mode, with
# readiness=app-receipt. It has no Mac fields because no Mac takes part. Only allowlisted fields are copied from the
# app's sanitized receipt.
cmux_attach_write_app_readiness_receipt() {
  local path="$1" git_sha="$2" tag="$3" bundle_id="$4" target="$5" target_id="$6"
  local readiness_latency_ms="$7" attempt_count="$8" app_receipt_json="$9"
  local installed_bundle_metadata_json="${10:-}"
  if [[ ! "$readiness_latency_ms" =~ ^[0-9]+$ ]] \
      || [[ ! "$attempt_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: readiness receipt timing and attempt count must be integers" >&2
    return 2
  fi
  if [[ -z "$installed_bundle_metadata_json" ]]; then
    installed_bundle_metadata_json="{\"bundle_id\":\"$bundle_id\",\"target\":\"$target\",\"target_id\":\"$target_id\",\"source\":\"legacy_receipt_writer\",\"executable_sha256\":null}"
  fi
  printf '%s' "$app_receipt_json" | /usr/bin/python3 -c '
import json
import os
import stat
import sys
import tempfile

(
    path,
    git_sha,
    tag,
    bundle_id,
    target,
    target_id,
    readiness_latency_ms,
    attempt_count,
    installed_bundle_metadata_json,
) = sys.argv[1:]
app = json.load(sys.stdin)
if not isinstance(app, dict) or app.get("bundle_id") != bundle_id:
    raise SystemExit("app readiness receipt has the wrong bundle identifier")
try:
    installed_bundle = json.loads(installed_bundle_metadata_json)
except json.JSONDecodeError as error:
    raise SystemExit(f"invalid installed bundle metadata: {error}")
if not isinstance(installed_bundle, dict) or installed_bundle.get("bundle_id") != bundle_id:
    raise SystemExit("installed bundle metadata has the wrong bundle identifier")

receipt = {
    "schema": "cmux-ios-dogfood-readiness-v1",
    "readiness": "app-receipt",
    "git_sha": installed_bundle.get("source_git_sha") or app.get("git_sha") or git_sha,
    "tooling_checkout_sha": git_sha,
    "tag": tag,
    "bundle_id": bundle_id,
    "target": target,
    "target_id": target_id,
    "readiness_latency_ms": int(readiness_latency_ms),
    "attempt_count": int(attempt_count),
    "client_id": app["client_id"],
    "session_source": app["session_source"],
    "app_receipt": {
        key: app[key]
        for key in ("schema", "dev_tag", "git_sha", "api_base_url", "account_email",
                    "user_id", "session_source", "written_at")
        if key in app
    },
    "installed_bundle": installed_bundle,
}
auth_profile = os.environ.get("CMUX_DEV_AUTH_PROFILE", "")
auth_account = os.environ.get("CMUX_DEV_AUTH_ACCOUNT", "")
if auth_profile and auth_account:
    receipt["auth_profile"] = auth_profile
    receipt["auth_account"] = auth_account
    receipt["auth_proof"] = "stack_same_account_app_receipt"
parent = os.path.dirname(path) or "."
os.makedirs(parent, mode=0o700, exist_ok=True)
parent_status = os.lstat(parent)
if not stat.S_ISDIR(parent_status.st_mode) or parent_status.st_uid != os.getuid():
    raise SystemExit("readiness receipt directory is not a private owned directory")
if parent != ".":
    os.chmod(parent, 0o700)
descriptor, temporary_path = tempfile.mkstemp(prefix=".cmux-ready-", dir=parent)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(receipt, output, sort_keys=True)
        output.write("\n")
    os.replace(temporary_path, path)
except BaseException:
    try:
        os.close(descriptor)
    except OSError:
        pass
    try:
        os.unlink(temporary_path)
    except OSError:
        pass
    raise
' "$path" "$git_sha" "$tag" "$bundle_id" "$target" "$target_id" \
    "$readiness_latency_ms" "$attempt_count" "$installed_bundle_metadata_json"
}
