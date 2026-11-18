# shellcheck shell=bash
# The iPhones an end-of-task hand-off installs on: every connected, paired iPhone, not only the
# configured default, with new phones registered. Shared by the classic app's
# `ios/scripts/reload.sh --review` and the cmux-next app's `cmux-next-ios/scripts/review.sh`.
#
# The caller sets REVIEW_PHONES_FILE, REVIEW_TARGETS=(), REVIEW_FAILED=0, REVIEW_PHONE_STATUS="",
# REQUESTED_DEVICE_ID (a phone asked for with --device-id, recorded before any default fills
# DEVICE_ID; missing, it is a blocker), DEFAULT_DEVICE_ID (the configured default; missing, a
# notice), and optionally REVIEW_CALLER (the command named in errors, default --review) and
# REVIEW_TAILNET_NOTE=0 (no classic tailnet note for a new phone).
# review_resolve_phones fills REVIEW_TARGETS with "<udid>\t<name> (<model>, <udid>)" lines.

# One line per phone for the report.
review_phone_result() {
  REVIEW_PHONE_STATUS+="${REVIEW_PHONE_STATUS:+$'\n  '}$1"
}

# Every connected, paired, booted iPhone/iPad: "<udid>\t<name>\t<model>".
# Same reachability rule as scripts/iphone-install-queue.sh probe.
review_connected_phones() {
  local json
  json="$(mktemp "${TMPDIR:-/tmp}/cmux-review-devices.XXXXXX")" || return 1
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || { rm -f "$json"; return 1; }
  /usr/bin/python3 - "$json" <<'PYDEV'
import json, sys
for d in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hw, conn, props = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical" or conn.get("pairingState") != "paired":
        continue
    reachable = str(props.get("bootState") or "").lower() == "booted" or (
        conn.get("transportType") == "localNetwork" and conn.get("tunnelState") != "unavailable"
        and props.get("developerModeStatus"))
    udid = hw.get("udid") or d.get("identifier")
    if reachable and udid:
        print(f"{udid}\t{props.get('name') or udid}\t{hw.get('marketingName') or hw.get('productType') or ''}")
PYDEV
  local rc=$?
  rm -f "$json"
  return "$rc"
}

# Known phones live in ~/.config/cmux/iphone-device-ids (one "<udid>\t<name>\t<model>"
# per line). A connected phone that is not listed yet is a new phone: it is added
# there, and becomes the default (~/.config/cmux/iphone-device-id) when none is set.
review_register_phone() {
  local udid="$1" name="$2" model="$3" default_file
  default_file="$(dirname "$REVIEW_PHONES_FILE")/iphone-device-id"
  mkdir -p "$(dirname "$REVIEW_PHONES_FILE")"
  if ! grep -qi "^$udid" "$REVIEW_PHONES_FILE" 2>/dev/null; then
    printf '%s\t%s\t%s\n' "$udid" "$name" "$model" >> "$REVIEW_PHONES_FILE"
    echo "==> new iPhone registered: $name ($model, $udid) in $REVIEW_PHONES_FILE"
    # The classic app's fleet build talks to hq's tailnet-only dev backend; cmux-next's does not.
    [[ "${REVIEW_TAILNET_NOTE:-1}" -eq 0 ]] ||
      echo "==> note: a fleet-built dev app reaches hq's dev backend only on the tailnet; if this phone's auth gate fails, check that it is on the tailnet"
  fi
  if [[ ! -s "$default_file" ]]; then
    printf '%s\n' "$udid" > "$default_file"
    echo "==> default iPhone set to $name ($udid)"
  fi
}

# The phones this review installs on: every connected phone. A --device-id or
# default phone that is not connected is reported (the explicit one fails).
review_resolve_phones() {
  local udid name model line wanted
  local connected=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && connected+=("$line")
  done < <(review_connected_phones || true)
  for line in ${connected[@]+"${connected[@]}"}; do
    IFS=$'\t' read -r udid name model <<<"$line"
    review_register_phone "$udid" "$name" "$model"
    REVIEW_TARGETS+=("$udid"$'\t'"$name ($model, $udid)")
  done
  local seen=""
  for wanted in "${REQUESTED_DEVICE_ID:-}" "$DEFAULT_DEVICE_ID"; do
    [[ -n "$wanted" ]] || continue
    [[ "$seen" == *"|$wanted|"* ]] && continue
    seen+="|$wanted|"
    if ! printf '%s\n' ${connected[@]+"${connected[@]}"} | grep -qi "^$wanted"; then
      if [[ "$wanted" == "${REQUESTED_DEVICE_ID:-}" ]]; then
        echo "error: --device-id $wanted is not connected" >&2
        review_phone_result "$wanted: BLOCKED, requested with --device-id but not connected (unlock it and connect it by USB or Wi-Fi)"
        REVIEW_FAILED=1
      else
        echo "warning: the default iPhone $wanted is not connected" >&2
        review_phone_result "$wanted (default): not connected, nothing installed"
      fi
    fi
  done
  if [[ "${#REVIEW_TARGETS[@]}" -eq 0 ]]; then
    echo "error: ${REVIEW_CALLER:---review} found no connected iPhone; connect and unlock one (a missing phone is a blocker to report)" >&2
    return 1
  fi
}

