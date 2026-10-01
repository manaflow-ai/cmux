#!/usr/bin/env bash
# Renames each static archive in an xcframework to start with `lib` and
# updates Info.plist to match. SwiftPM refuses to link a binary target's
# archive without that prefix ("Static libraries should be prefixed with lib").
set -euo pipefail
fw="${1:?usage: prefix-ghosttykit-archives.sh <path/to/X.xcframework>}"
plist="$fw/Info.plist"
buddy=/usr/libexec/PlistBuddy
i=0
while id=$("$buddy" -c "Print :AvailableLibraries:$i:LibraryIdentifier" "$plist" 2>/dev/null); do
  lib=$("$buddy" -c "Print :AvailableLibraries:$i:LibraryPath" "$plist")
  case "$lib" in
    lib*|*.framework) ;;
    *.a)
      mv "$fw/$id/$lib" "$fw/$id/lib$lib"
      "$buddy" -c "Set :AvailableLibraries:$i:LibraryPath lib$lib" "$plist"
      if binary=$("$buddy" -c "Print :AvailableLibraries:$i:BinaryPath" "$plist" 2>/dev/null) && [ "$binary" = "$lib" ]; then
        "$buddy" -c "Set :AvailableLibraries:$i:BinaryPath lib$lib" "$plist"
      fi
      echo "$id: $lib -> lib$lib"
      ;;
  esac
  i=$((i + 1))
done
