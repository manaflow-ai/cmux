# shellcheck shell=bash
# The iPhones an end-of-task hand-off installs on: every connected, paired iPhone of this Mac's
# person, not only the configured default, with new phones registered.
#
# Whose phone: devicectl lists every phone this Mac ever paired with that is on the same Wi-Fi, so
# a teammate's test phone in the room is "connected" too. Leo, 2026-11-26: "just now leo-prod
# review wanted to connect to the aziz test phone? why". A phone counts as this person's when
# it is in ~/.config/cmux/iphone-device-ids or is the default, when it is named with --device-id, or
# when it is plugged into this Mac by USB (that registers it). A phone this Mac does not know that
# is reached only over Wi-Fi is skipped and reported: nothing is installed or launched on it.
# A UDID in ~/.config/cmux/iphone-device-ids-ignored (one per line, `#` comments) is never
# picked unless --device-id names it: the way to drop a phone registered by mistake. Shared by the classic app's
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

# Every connected, paired, booted iPhone/iPad: "<udid>\t<name>\t<model>\t<transport>" (devicectl's
# transportType: `wired` for USB, `localNetwork` for Wi-Fi).
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
        name = str(props.get('name') or udid).replace("\t", " ")
        model = str(hw.get('marketingName') or hw.get('productType') or '').replace("\t", " ")
        print(f"{udid}\t{name}\t{model}\t{conn.get('transportType') or ''}")
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

# Whether UDID $1 is listed in file $2 (first column, case-insensitive; `#` lines skipped).
review_phone_listed() {
  [[ -n "$1" && -s "$2" ]] || return 1
  awk -F'\t' -v id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    /^[[:space:]]*#/ { next }
    { first = tolower($1); gsub(/[[:space:]]/, "", first); if (first == id) found = 1 }
    END { exit found ? 0 : 1 }' "$2"
}

# Whether a connected phone is this person's (see the header): `yes`, or why not.
review_phone_owner() {
  local udid="$1" transport="$2" ignored
  ignored="$(dirname "$REVIEW_PHONES_FILE")/iphone-device-ids-ignored"
  local lower_udid lower_requested
  lower_udid="$(printf '%s' "$udid" | tr '[:upper:]' '[:lower:]')"
  lower_requested="$(printf '%s' "${REQUESTED_DEVICE_ID:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$lower_requested" && "$lower_udid" == "$lower_requested" ]]; then echo yes; return; fi
  if review_phone_listed "$udid" "$ignored"; then echo ignored; return; fi
  if review_phone_listed "$udid" "$REVIEW_PHONES_FILE"; then echo yes; return; fi
  if [[ -n "${DEFAULT_DEVICE_ID:-}" && "$lower_udid" == "$(printf '%s' "$DEFAULT_DEVICE_ID" | tr '[:upper:]' '[:lower:]')" ]]; then
    echo yes; return
  fi
  if [[ "$transport" == "wired" ]]; then echo yes; return; fi
  echo wifi-unknown
}

# The phones this review installs on: every connected phone of this Mac's person (see the
# header). A --device-id or default phone that is not connected is reported (the explicit one fails).
review_resolve_phones() {
  local udid name model transport line wanted owner
  local connected=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && connected+=("$line")
  done < <(review_connected_phones || true)
  for line in ${connected[@]+"${connected[@]}"}; do
    IFS=$'\t' read -r udid name model transport <<<"$line"
    owner="$(review_phone_owner "$udid" "$transport")"
    case "$owner" in
      yes) ;;
      ignored)
        echo "==> skipped iPhone $name ($model, $udid): listed in iphone-device-ids-ignored"
        review_phone_result "$name ($udid): skipped, listed in iphone-device-ids-ignored (pass --device-id $udid to use it once)"
        continue ;;
      *)
        echo "==> skipped iPhone $name ($model, $udid): this Mac does not know it and reaches it only over Wi-Fi (someone else's phone nearby?)"
        review_phone_result "$name ($udid): skipped, not registered on this Mac and reached only over Wi-Fi; if it is yours, plug it in by USB once or pass --device-id $udid"
        continue ;;
    esac
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

