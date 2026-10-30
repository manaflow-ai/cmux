#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/strip-release-bundle.sh <path-to-cmux.app>

Strips cmux-owned Release Mach-O binaries before codesigning: executables fully,
plug-ins and libraries down to their global symbols. Compiled .strings tables
under Contents/Resources become binary property lists.
The dSYM UUID is preserved, so Sentry symbol upload continues to match crashes.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH/Contents" ]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

FILE_TOOL="${CMUX_FILE_TOOL:-file}"
STRIP_TOOL="${CMUX_STRIP_TOOL:-strip}"

# strip_if_macho <path> [full]. By default it uses -S -x, which keeps global
# symbols for plug-ins, libraries and extensions.
strip_if_macho() {
  local path="$1"
  local mode="${2:-}"
  # A symlink (bin/cmux-tui, bin/acpmux -> cmux) names a file stripped on its own.
  [ ! -L "$path" ] || return 0
  [ -f "$path" ] || return 0
  [ -x "$path" ] || return 0
  if ! "$FILE_TOOL" "$path" | grep -q 'Mach-O'; then
    return 0
  fi
  echo "stripping release binary: $path"
  if [ "$mode" = full ]; then
    "$STRIP_TOOL" "$path"
  else
    "$STRIP_TOOL" -S -x "$path"
  fi
}

# cmux's own executables keep only what dyld needs: plain strip on a dynamically
# linked executable saves undefined and dynamically referenced symbols (-u -r).
# Nothing looks their other symbols up at runtime, and crashes symbolicate from
# the dSYMs uploaded to Sentry. Measured on arm64: 10.4 MB in the app, 2.8 MB in
# the CLI.
strip_executable() {
  strip_if_macho "$1" full
}

# cmux NEXT links its executable with -no_exported_symbols, so the strip below
# removes every function name. Keep them in Resources/cmux-symbols.bin first:
# hang records and exception traces name app frames through it.
if [ -f "$APP_PATH/Contents/MacOS/cmux" ]; then
  python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/write-app-symbol-map.py" \
    "$APP_PATH/Contents/MacOS/cmux" "$APP_PATH/Contents/Resources/cmux-symbols.bin"
fi
strip_executable "$APP_PATH/Contents/MacOS/cmux"
# bin/cmux is the Rust cmux-tui binary, which ships no dSYM: keep its global
# symbols (-S -x) so its crash reports still name functions.
strip_if_macho "$APP_PATH/Contents/Resources/bin/cmux"
strip_executable "$APP_PATH/Contents/Resources/bin/cmux-diff-sidecar"
# Every other helper in bin/ and libexec/ keeps its global symbols: the
# nightly's optchat-chief, cmux-app-host, cmux-browser-host, cmux-cloud, ghostty
# and libexec/cmux-server-helper. bin/cmux-tui and bin/acpmux are symlinks to
# bin/cmux. Scripts, symlinks and the executables stripped above are skipped.
for helper_dir in bin libexec; do
  [ -d "$APP_PATH/Contents/Resources/$helper_dir" ] || continue
  while IFS= read -r -d '' binary; do
    case "$binary" in
      "$APP_PATH/Contents/Resources/bin/cmux" | "$APP_PATH/Contents/Resources/bin/cmux-diff-sidecar") continue ;;
    esac
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/Resources/$helper_dir" -maxdepth 1 -print0 | sort -z)
done

# cmux-tui SSH bootstrap payloads are installed 0644, so strip_if_macho's
# executable check would skip them. Only the macOS builds are Mach-O; the Linux
# builds arrive stripped. sign-cmux-tui-ssh-payloads.sh signs these afterwards
# and re-pins their checksums in manifest.json, so the strip needs no re-pin.
if [ -d "$APP_PATH/Contents/Resources/bin/cmux-tui-ssh" ]; then
  while IFS= read -r -d '' payload; do
    if "$FILE_TOOL" "$payload" | grep -q 'Mach-O'; then
      echo "stripping cmux-tui SSH payload: $payload"
      "$STRIP_TOOL" -S -x "$payload"
    fi
  done < <(find "$APP_PATH/Contents/Resources/bin/cmux-tui-ssh" -maxdepth 1 -name 'cmux-tui-*-apple-darwin' -type f -print0 | sort -z)
fi

if [ -d "$APP_PATH/Contents/PlugIns" ]; then
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/PlugIns" -path '*/Contents/MacOS/*' -type f -print0)
fi

if [ -d "$APP_PATH/Contents/Frameworks" ]; then
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name 'libcmux_*.dylib' -type f -print0)
  # The Chromium engine's cmux Helper apps (GPU, Renderer, Plugin, Alerts).
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 4 -path '*/cmux Helper*.app/Contents/MacOS/*' -type f -print0 | sort -z)
fi

if [ -d "$APP_PATH/Contents/Library/SystemExtensions" ]; then
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/Library/SystemExtensions" -path '*/Contents/MacOS/*' -type f -print0)
fi

# Mergeable frameworks (Sentry.framework) carry LC_ATOM_INFO, data that only a
# static link into another image reads, never dyld: 6.6 MB of Sentry's 9.7 MB
# binary (nightly-next, 2026-10-20). Remove it and the debug stabs (-S); every
# symbol stays, so the framework's own frames still symbolicate.
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
  while IFS= read -r -d '' binary; do
    echo "removing LC_ATOM_INFO: $binary"
    "$STRIP_TOOL" -S -no_atom_info -no_code_signature_warning "$binary"
  done < <(python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/find-atom-info-macho.py" "$APP_PATH/Contents/Frameworks")
fi

# Compiled String Catalogs ship as binary property lists. Xcode re-encodes them
# with STRINGS_FILE_OUTPUT_ENCODING, and the project's binary setting does not
# reach SwiftPM package targets, so the resource bundles' tables arrive as
# UTF-16 XML (cmux NEXT: 2,109 files, 19.6 MiB; 9.5 MiB as binary). Foundation
# reads both forms. Binary, old-style text and unreadable tables stay as they
# are (this only saves space), and nested code bundles, signed on their own,
# are skipped.
python3 -I - "$APP_PATH/Contents/Resources" <<'PY'
import os, plistlib, sys, tempfile

def table_of(data):
    """The XML property list in data, or None (binary, old-style text, unreadable)."""
    if data.startswith(b"bplist"):
        return None
    try:
        return plistlib.loads(data, fmt=plistlib.FMT_XML)
    except Exception:
        pass
    # Xcode's UTF-16 copy keeps the UTF-8 declaration, which expat refuses.
    if data[:2] not in (b"\xff\xfe", b"\xfe\xff"):
        return None
    try:
        return plistlib.loads(data.decode("utf-16").encode("utf-8"), fmt=plistlib.FMT_XML)
    except Exception:
        return None

root = sys.argv[1]
count = before = after = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if not d.endswith((".app", ".appex", ".framework", ".plugin", ".xpc"))]
    for name in filenames:
        if not name.endswith(".strings"):
            continue
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        table = table_of(data)
        if table is None:
            text = data.lstrip(b"\xef\xbb\xbf\xff\xfe").replace(b"\x00", b"").lstrip()
            if text.startswith((b"<?xml", b"<!DOCTYPE", b"<plist")):
                print(f"warning: kept unreadable XML strings table as is: {path}", file=sys.stderr)
            continue
        binary = plistlib.dumps(table, fmt=plistlib.FMT_BINARY)
        fd, tmp = tempfile.mkstemp(dir=dirpath, prefix=".strings-")
        with os.fdopen(fd, "wb") as f:
            f.write(binary)
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
        count += 1
        before += len(data)
        after += len(binary)
if count:
    print(f"binary strings tables: {count} files, {before / 1048576:.2f} -> {after / 1048576:.2f} MiB")
PY
