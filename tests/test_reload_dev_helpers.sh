#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/dev-cli-shim.sh
. "$ROOT_DIR/scripts/lib/dev-cli-shim.sh"
# shellcheck source=scripts/lib/dev-web-port.sh
. "$ROOT_DIR/scripts/lib/dev-web-port.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reload-dev-helpers.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
TARGET="$TMP_ROOT/cmux-dev"
OLD="$TMP_ROOT/old"
TEMPLATE="$ROOT_DIR/scripts/lib/cmux-dev-shim"

printf '#!/usr/bin/env bash\nexit 42\n' > "$TARGET"
chmod 0755 "$TARGET"
command cp "$TARGET" "$OLD"

# A slow copy leaves the previous complete helper visible until publication.
# shellcheck disable=SC2329
cp() {
  sleep 0.2
  command cp "$@"
}
cmux_publish_dev_cli_shim "$TARGET" "$TEMPLATE" &
writer_pid=$!
sleep 0.05
cmp "$OLD" "$TARGET"
wait "$writer_pid"
bash -n "$TARGET"
test -x "$TARGET"
grep -qF 'cmux-debug-' "$TARGET"

# A failed copy preserves the last published helper and removes its temp file.
command cp "$TARGET" "$OLD"
# shellcheck disable=SC2329
cp() { return 7; }
if cmux_publish_dev_cli_shim "$TARGET" "$TEMPLATE"; then
  echo "expected shim copy failure" >&2
  exit 1
fi
cmp "$OLD" "$TARGET"
if compgen -G "$TMP_ROOT/.cmux-dev.*" >/dev/null; then
  echo "temporary shim survived failed copy" >&2
  exit 1
fi

# Concurrent publishers may race, but the shared target remains complete.
TEMPLATE_A="$TMP_ROOT/template-a"
TEMPLATE_B="$TMP_ROOT/template-b"
command cp "$TEMPLATE" "$TEMPLATE_A"
command cp "$TEMPLATE" "$TEMPLATE_B"
printf '\n# publisher a\n' >> "$TEMPLATE_A"
printf '\n# publisher b\n' >> "$TEMPLATE_B"
# shellcheck disable=SC2329
cp() {
  sleep 0.05
  command cp "$@"
}
cmux_publish_dev_cli_shim "$TARGET" "$TEMPLATE_A" &
writer_a=$!
cmux_publish_dev_cli_shim "$TARGET" "$TEMPLATE_B" &
writer_b=$!
for _ in 1 2 3 4 5 6; do
  bash -n "$TARGET"
  sleep 0.02
done
wait "$writer_a"
wait "$writer_b"
bash -n "$TARGET"
test -x "$TARGET"
grep -Eq '^# publisher [ab]$' "$TARGET"

# Tagged defaults are stable and isolated; explicit overrides retain precedence.
unset CMUX_PORT CMUX_PORT_RANGE CMUX_PORT_END PORT
test "$(cmux_dev_web_port_for_tag gz016)" = "4160"
test "$(cmux_choose_dev_web_port gz016)" = "4160"
test "$(cmux_dev_web_port_for_tag another-tag)" != "4160"
for tag in gz016 alpha beta terminal-runtime; do
  port="$(cmux_dev_web_port_for_tag "$tag")"
  (( port >= 3800 && port <= 4799 ))
done

CMUX_PORT=9170
PORT=9171
test "$(cmux_choose_dev_web_port gz016)" = "9170"
unset CMUX_PORT
test "$(cmux_choose_dev_web_port gz016)" = "9171"
CMUX_PORT=70000
PORT=0
test "$(cmux_choose_dev_web_port gz016)" = "4160"

# A shell launched inside another tagged app inherits its complete web-port
# range. A new tag must not copy that ambient range. Overriding only CMUX_PORT
# remains the supported way to pin a reload to a specific port.
CMUX_PORT=9590
CMUX_PORT_RANGE=10
CMUX_PORT_END=9599
PORT=9590
test "$(cmux_choose_dev_web_port gz016)" = "4160"
test "$(cmux_choose_dev_web_port_range)" = "1"
test "$(cmux_choose_dev_web_port_end 4160 1)" = "4160"
CMUX_PORT=4555
test "$(cmux_choose_dev_web_port gz016)" = "4555"
test "$(cmux_choose_dev_web_port_range)" = "1"
test "$(cmux_choose_dev_web_port_end 4555 1)" = "4555"

unset CMUX_PORT PORT
unset CMUX_PORT_RANGE CMUX_PORT_END
test "$(cmux_choose_dev_web_port_range)" = "1"
test "$(cmux_choose_dev_web_port_end 4160 1)" = "4160"
CMUX_PORT_RANGE=10
test "$(cmux_choose_dev_web_port_range)" = "10"
test "$(cmux_choose_dev_web_port_end 4160 10)" = "4169"
CMUX_PORT_END=9999
test "$(cmux_choose_dev_web_port_end 4160 10)" = "9999"

printf 'PASS: reload dev helpers are atomic and tag-isolated\n'
