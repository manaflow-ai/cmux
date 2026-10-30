#!/usr/bin/env bash
# A program in a cmux-next terminal that opens a web page reaches cmux: the
# terminal's BROWSER names cmux-open-url (bare, found on PATH), and the `open`
# and `xdg-open` shims in the same bin dir send http(s) URLs to it. It hands the
# URL to `cmux open --link --caller <names> -` on stdin, never in argv, and falls
# back to the system's open when the app cannot be reached. Files, apps and any
# other `open` option go to the system's open unchanged, and so does every
# `open` when the user set BROWSER to another browser.
#
# Fakes: a `cmux` that records its argv and stdin (and fails when told to), and
# a system `open` (CMUX_SYSTEM_OPEN) that records its argv.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
bin="$TMP/cmux DEV t.app/Contents/Resources/bin"
mkdir -p "$bin" "$TMP/tools"
for shim in cmux-open-url open xdg-open; do install -m 755 "$ROOT/scripts/cmux-next/url-open/$shim" "$bin/$shim"; done
cat >"$bin/cmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CMUX_TEST_LOG.cli"
cat >>"$CMUX_TEST_LOG.stdin"
[ -z "${CMUX_TEST_CLI_FAILS:-}" ]
SH
cat >"$TMP/system-open" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CMUX_TEST_LOG.system"
SH
chmod +x "$bin/cmux" "$TMP/system-open"
# A tool named like the programs the rules match by caller.
printf '#!/bin/sh\n"$@"\n' >"$TMP/tools/aws"; chmod +x "$TMP/tools/aws"

fail=0
run() { # name, then the command; env: the terminal's
  local name=$1; shift
  export CMUX_TEST_LOG="$TMP/$name"
  env PATH="$bin:/usr/bin:/bin" BROWSER=cmux-open-url CMUX_BUNDLED_CLI_PATH="$bin/cmux" \
    CMUX_SYSTEM_OPEN="$TMP/system-open" "$@"
}
expect_file() { # file, expected content
  local got; got=$(cat "$1" 2>/dev/null || true)
  [[ "$got" == "$2" ]] || { echo "FAIL: ${1##*/}: expected [$2], got [$got]" >&2; fail=1; }
}
expect_absent() { [[ ! -e "$1" ]] || { echo "FAIL: ${1##*/} should be empty: $(cat "$1")" >&2; fail=1; }; }

# open <url>: to cmux on stdin, with the caller names; the system open is not used.
run open-url open "https://signin.aws.amazon.com/oauth?state=SECRET"
expect_file "$TMP/open-url.stdin" "https://signin.aws.amazon.com/oauth?state=SECRET"
grep -q -- '^open --link --caller .* -$' "$TMP/open-url.cli" || { echo "FAIL: open-url argv: $(cat "$TMP/open-url.cli")" >&2; fail=1; }
grep -q SECRET "$TMP/open-url.cli" && { echo "FAIL: the URL reached argv" >&2; fail=1; }
expect_absent "$TMP/open-url.system"

# open -g <url> (the open npm package's background flag) still goes to cmux.
run open-g open -g "https://example.com/a"
expect_file "$TMP/open-g.stdin" "https://example.com/a"
expect_absent "$TMP/open-g.system"
# ... and its long forms (Claude Code's bundled `open` package passes them).
run open-long open --background --wait-apps "https://example.com/b"
expect_file "$TMP/open-long.stdin" "https://example.com/b"
expect_absent "$TMP/open-long.system"

# Files, apps and other options go to the system open unchanged.
run open-file open "$TMP/notes.txt"
expect_file "$TMP/open-file.system" "$TMP/notes.txt"
expect_absent "$TMP/open-file.cli"
run open-app open -a Safari "https://example.com/"
expect_file "$TMP/open-app.system" "-a Safari https://example.com/"
expect_absent "$TMP/open-app.cli"
run open-mixed open "https://example.com/" "$TMP/notes.txt"
expect_file "$TMP/open-mixed.system" "https://example.com/ $TMP/notes.txt"

# A BROWSER the user set to another browser wins: every open goes to the system.
export CMUX_TEST_LOG="$TMP/user-browser"
env PATH="$bin:/usr/bin:/bin" BROWSER=firefox CMUX_BUNDLED_CLI_PATH="$bin/cmux" CMUX_SYSTEM_OPEN="$TMP/system-open" \
  open "https://example.com/"
expect_file "$TMP/user-browser.system" "https://example.com/"
expect_absent "$TMP/user-browser.cli"

# BROWSER=open names the system opener, not another browser: prezto's stock
# .zprofile exports it in every login shell that starts without BROWSER, such
# as the `zsh -lc` Codex runs each command in. A device-code page an agent or a
# program opens there still reaches cmux (the user saw these open in Helium).
for value in open /usr/bin/open xdg-open; do
  name="browser-${value//\//_}"
  export CMUX_TEST_LOG="$TMP/$name"
  env PATH="$bin:/usr/bin:/bin" BROWSER="$value" CMUX_BUNDLED_CLI_PATH="$bin/cmux" CMUX_SYSTEM_OPEN="$TMP/system-open" \
    open "https://example.com/device?code=ABCD-1234"
  expect_file "$TMP/$name.stdin" "https://example.com/device?code=ABCD-1234"
  expect_absent "$TMP/$name.system"
done
# Python's webbrowser with BROWSER=open runs `open` from PATH: the shim, then cmux.
export CMUX_TEST_LOG="$TMP/python-browser-open"
env PATH="$bin:/usr/bin:/bin" BROWSER=open CMUX_BUNDLED_CLI_PATH="$bin/cmux" CMUX_SYSTEM_OPEN="$TMP/system-open" \
  python3 -I -c 'import webbrowser,sys; sys.exit(0 if webbrowser.open("https://example.com/device?code=PY") else 1)'
expect_file "$TMP/python-browser-open.stdin" "https://example.com/device?code=PY"
expect_absent "$TMP/python-browser-open.system"

# The app cannot be reached: the system open gets the URL.
CMUX_TEST_CLI_FAILS=1 run unreachable cmux-open-url "https://example.com/x"
expect_file "$TMP/unreachable.system" "https://example.com/x"

# xdg-open: a URL to cmux, a file to the system open.
run xdg-url xdg-open "https://example.com/y"
expect_file "$TMP/xdg-url.stdin" "https://example.com/y"
run xdg-file xdg-open "$TMP/notes.txt"
expect_file "$TMP/xdg-file.system" "$TMP/notes.txt"

# Python's webbrowser runs BROWSER (the bare name, found on PATH); the caller
# names carry the program that asked (here a tool named aws running python3).
run python "$TMP/tools/aws" python3 -I -c 'import webbrowser,sys; sys.exit(0 if webbrowser.open("https://example.com/py") else 1)'
expect_file "$TMP/python.stdin" "https://example.com/py"
grep -qi -- '--caller [^ ]*python' "$TMP/python.cli" || { echo "FAIL: python caller names: $(cat "$TMP/python.cli")" >&2; fail=1; }
grep -q -- '--caller [^ ]*aws' "$TMP/python.cli" || { echo "FAIL: aws caller name: $(cat "$TMP/python.cli")" >&2; fail=1; }
expect_absent "$TMP/python.system"

(( fail == 0 )) && echo "PASS: url-open shims"
exit "$fail"
