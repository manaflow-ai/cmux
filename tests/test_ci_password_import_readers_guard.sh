#!/usr/bin/env bash
# The notary-test guard must ignore debug source filenames and catch real
# reader symbols and Firefox's NSS table literal.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT_DIR/scripts/ci/check-password-import-readers.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-password-reader-guard.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

printf 'ChromiumLoginDataReader.swift FirefoxPasswordCrypto.swift\n' > "$tmp/debug-only"
cat > "$tmp/bin/nm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/nm"

if ! PATH="$tmp/bin:$PATH" "$CHECKER" "$tmp/debug-only"; then
  echo "FAIL: a DWARF source filename must not count as a reader symbol" >&2
  exit 1
fi

cat > "$tmp/bin/nm" <<'EOF'
#!/usr/bin/env bash
echo '0000000000000000 T $s16CmuxNextBrowserImport24ChromiumLoginDataReaderV'
EOF
chmod +x "$tmp/bin/nm"
if PATH="$tmp/bin:$PATH" "$CHECKER" "$tmp/debug-only"; then
  echo "FAIL: a real Chromium reader symbol must fail the guard" >&2
  exit 1
fi

cat > "$tmp/bin/nm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/nm"
printf 'SELECT a11, a102 FROM nssPrivate\n' > "$tmp/with-table"
if PATH="$tmp/bin:$PATH" "$CHECKER" "$tmp/with-table"; then
  echo "FAIL: the Firefox NSS table literal must fail the guard" >&2
  exit 1
fi

# cmux NEXT's code is CmuxNextApp.framework behind a stub executable (CMUX-629):
# given the executable, the guard reads the framework too.
app="$tmp/cmux.app/Contents"
mkdir -p "$app/MacOS" "$app/Frameworks/CmuxNextApp.framework/Versions/A"
printf 'stub\n' > "$app/MacOS/cmux"
printf 'SELECT a11, a102 FROM nssPrivate\n' > "$app/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"
if PATH="$tmp/bin:$PATH" "$CHECKER" "$app/MacOS/cmux"; then
  echo "FAIL: the Firefox NSS table literal in CmuxNextApp.framework must fail the guard" >&2
  exit 1
fi
printf 'code\n' > "$app/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"
if ! PATH="$tmp/bin:$PATH" "$CHECKER" "$app/MacOS/cmux"; then
  echo "FAIL: a clean stub and framework must pass the guard" >&2
  exit 1
fi

echo "PASS: password-import reader guard distinguishes debug filenames from code"
