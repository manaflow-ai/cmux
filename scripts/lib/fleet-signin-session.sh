# shellcheck shell=bash
# The sign-in session a fleet step receives from its submitter (cmuxterm-hq build-fleet `sign_in`).
#
# A step sent with `cmux-ci run --sign-in agent` gets no account and no password: the submitter signs the
# shared agent account in on their own Mac, as a new session for this step alone, seals it to the worker's
# key for this run, and revokes it when the step ends. The worker writes it to $CMUX_CI_SIGNIN_FILE, a 0600
# JSON file ({profile, email, project, refresh_token}) in the step's own directory, removed after the script.
#
#   source scripts/lib/fleet-signin-session.sh
#   cmux_fleet_signin_load || { echo "$CMUX_FLEET_SIGNIN_ERROR"; exit 1; }
#   echo "signed in as $CMUX_FLEET_SIGNIN_EMAIL"
#   cmux_fleet_signin_simctl --set "$sims" launch "$udid" "$bundle_id"   # xcrun simctl, with the session
#
# The refresh token stays in an unexported shell variable: only that one `xcrun simctl` call gets it, as
# SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN (a cmux-next iPhone app on the simulator, DEBUG or Production,
# adopts it while it holds no session: CmuxMobileAuthModel.launchTokenStore; a Production build takes only a
# production-project session). Nothing here prints it.

# cmux_fleet_signin_load: reads and checks the session file. On failure it returns 1 with the reason in
# CMUX_FLEET_SIGNIN_ERROR (never a value).
cmux_fleet_signin_load() {
  CMUX_FLEET_SIGNIN_ERROR="" CMUX_FLEET_SIGNIN_EMAIL="" CMUX_FLEET_SIGNIN_PROJECT="" _cmux_fleet_signin_token=""
  local file="${CMUX_CI_SIGNIN_FILE:-}" mode owner fields
  if [[ -z "$file" ]]; then
    CMUX_FLEET_SIGNIN_ERROR="no CMUX_CI_SIGNIN_FILE: send the step with cmux-ci run --sign-in agent (the session comes from your Mac)"
    return 1
  fi
  if [[ ! -f "$file" || -L "$file" ]]; then
    CMUX_FLEET_SIGNIN_ERROR="the sign-in session file is not a regular file"
    return 1
  fi
  # GNU stat first: its -f means file system and prints before it fails; BSD stat refuses -c silently.
  mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")"
  owner="$(stat -c %u "$file" 2>/dev/null || stat -f %u "$file")"
  if [[ "$mode" != 600 || "$owner" != "$(id -u)" ]]; then
    CMUX_FLEET_SIGNIN_ERROR="the sign-in session file must be this user's, mode 0600 (it is $owner, $mode)"
    return 1
  fi
  # One line per field, in order; python3 -I reads only the file it is given.
  if ! fields="$(python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
ok = (isinstance(s, dict) and s.get("profile") == "agent" and "@" in str(s.get("email", ""))
      and str(s.get("refresh_token", "")) and str(s.get("project", "")))
values = [str(s.get(k, "")) for k in ("email", "project", "refresh_token")] if ok else []
if not ok or any("\n" in v or "\r" in v for v in values):
    sys.exit(3)
print("\n".join(values))
' "$file" 2>/dev/null)"; then
    CMUX_FLEET_SIGNIN_ERROR="the sign-in session file is not an agent session (profile, email, project, refresh_token)"
    return 1
  fi
  # Split in the shell itself: a here-string would put the token in a temp file.
  CMUX_FLEET_SIGNIN_EMAIL="${fields%%$'\n'*}"
  fields="${fields#*$'\n'}"
  CMUX_FLEET_SIGNIN_PROJECT="${fields%%$'\n'*}"
  _cmux_fleet_signin_token="${fields#*$'\n'}"
  fields=""
  return 0
}

# cmux_fleet_signin_simctl ARGS...: `xcrun simctl ARGS` (a launch: `--set SET launch UDID BUNDLE_ID`) with the
# session in that one call's environment only.
cmux_fleet_signin_simctl() {
  if [[ -z "${_cmux_fleet_signin_token:-}" ]]; then
    echo "cmux_fleet_signin_simctl: no session loaded (cmux_fleet_signin_load)" >&2
    return 1
  fi
  SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN="$_cmux_fleet_signin_token" xcrun simctl "$@"
}

# cmux_fleet_signin_forget: drops the session from this shell.
cmux_fleet_signin_forget() {
  _cmux_fleet_signin_token="" CMUX_FLEET_SIGNIN_EMAIL="" CMUX_FLEET_SIGNIN_PROJECT=""
}
