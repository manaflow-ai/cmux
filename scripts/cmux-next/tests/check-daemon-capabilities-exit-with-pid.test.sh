#!/usr/bin/env bash
# check-daemon-capabilities.sh binds its probe owner to itself
# (`server ensure --exit-with-pid <the script's pid>`), so a killed script
# never leaves the owner running; a binary without the option is probed
# unbound. A stub binary records the calls; the owner's own exit is tested
# by cmux-tui's detached_owner.rs (exit_with_pid_*).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/daemon-exit-with-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
calls="$tmp/calls"
requirements="$tmp/requirements.json"
printf '%s\n' '{"required":[],"optional":[]}' > "$requirements"

# The stub fails every `server ensure` so the script stops right after it.
# With $tmp/old present it refuses --exit-with-pid, as an older binary does
# (the script runs the binary under `env -i`, so a file, not a variable).
cat > "$tmp/cmux-tui" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" server ensure "*) ;;
  *) exit 0 ;;
esac
if [[ -f "$tmp/old" && " \$* " == *" --exit-with-pid "* ]]; then
  echo "unknown flag --exit-with-pid" >&2
  exit 2
fi
echo "ensure \$*" >> "$calls"
echo "stub: no daemon" >&2
exit 1
EOF
chmod +x "$tmp/cmux-tui"

probe() {
  : > "$calls"
  bash "$ROOT/scripts/cmux-next/check-daemon-capabilities.sh" \
    --binary "$tmp/cmux-tui" --capabilities "$requirements" >/dev/null 2>&1 &
  script_pid=$!
  if wait "$script_pid"; then
    echo "FAIL: the probe passed with a stub that serves nothing" >&2
    exit 1
  fi
}

probe
if ! grep -q -- "--exit-with-pid $script_pid\$" "$calls" || [[ "$(wc -l < "$calls")" -ne 1 ]]; then
  echo "FAIL: server ensure was not bound to the script ($script_pid): $(cat "$calls")" >&2
  exit 1
fi

touch "$tmp/old"
probe
if grep -q -- "--exit-with-pid" "$calls" || [[ "$(wc -l < "$calls")" -ne 1 ]]; then
  echo "FAIL: a binary without --exit-with-pid was not probed unbound: $(cat "$calls")" >&2
  exit 1
fi

echo "PASS: the capability probe binds its owner to the script, and probes an older binary unbound"
