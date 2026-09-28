#!/usr/bin/env bash
# CI guard for the app-source mode of ./scripts/lint-pbxproj-test-wiring.sh.
#
# main stopped compiling on 2026-09-25 because a merge dropped
# Sources/Mobile/AgentChat/AgentChatProseStreamWakeDriver.swift from the cmux
# target. This checks that the lint catches that shape, and that its allowlist
# neither hides real gaps nor goes stale.
#
# Cases:
#   (a) Real repo: every Sources/ and CLI/ Swift file is in its target.
#   (b) A nested Sources file with no pbxproj entry fails, naming its path.
#   (c) The same file passes when allowlisted.
#   (d) An allowlist entry for a file that is now wired fails as stale.
#   (e) An allowlist entry for a deleted file fails as stale.
#   (f) An unwired file named like a wired one elsewhere fails: membership is
#       checked by name, so names must be unique.
#   (g) A repo path with `#` in it still reports the missing file.
#   Also.swift shares a Sources-phase line with Wired.swift, as merges leave
#   in the real pbxproj; both must count as wired.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT_DIR/scripts/lint-pbxproj-test-wiring.sh"

fail() {
  echo "test_ci_pbxproj_app_sources_wiring: $1" >&2
  [ -f "${2:-}" ] && cat "$2" >&2
  exit 1
}

# (a)
"$LINT" --repo-root "$ROOT_DIR" --target cmux --tests-dir Sources --recursive \
  --allowlist scripts/pbxproj-sources-wiring-allowlist.txt
"$LINT" --repo-root "$ROOT_DIR" --target cmux-cli --tests-dir CLI --recursive

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/cmux.xcodeproj" "$SANDBOX/Sources/Feature"
echo 'struct Wired {}' > "$SANDBOX/Sources/Wired.swift"
echo 'struct Also {}' > "$SANDBOX/Sources/Also.swift"
echo 'struct Dropped {}' > "$SANDBOX/Sources/Feature/Dropped.swift"

# The app target uses 8-char UUIDs like the real cmux target (A5001050).
cat > "$SANDBOX/cmux.xcodeproj/project.pbxproj" <<'PBX'
/* Begin PBXBuildFile section */
		A0000001 /* Wired.swift in Sources */ = {isa = PBXBuildFile; fileRef = A0000002 /* Wired.swift */; };
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
		A0000002 /* Wired.swift */ = {isa = PBXFileReference; path = Wired.swift; sourceTree = "<group>"; };
		A0000003 /* cmux */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; path = cmux; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
/* Begin PBXNativeTarget section */
		A5001050 /* cmux */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				A5001051 /* Sources */,
			);
			name = cmux;
		};
/* End PBXNativeTarget section */
/* Begin PBXSourcesBuildPhase section */
		A5001051 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
				A0000001 /* Wired.swift in Sources */,				A0000004 /* Also.swift in Sources */,
			);
		};
/* End PBXSourcesBuildPhase section */
PBX

lint_sandbox() {
  "$LINT" --repo-root "$SANDBOX" --target cmux --tests-dir Sources --recursive "$@" \
    >"$SANDBOX/out" 2>&1
}

# (b)
if lint_sandbox; then
  fail "(b) lint passed with Sources/Feature/Dropped.swift missing from the target" "$SANDBOX/out"
fi
grep -q '  - Sources/Feature/Dropped.swift' "$SANDBOX/out" \
  || fail "(b) output does not name Sources/Feature/Dropped.swift" "$SANDBOX/out"
if grep -q 'Wired.swift\|Also.swift' "$SANDBOX/out"; then
  fail "(b) output flags a wired file" "$SANDBOX/out"
fi

# (c)
printf '# reason\nSources/Feature/Dropped.swift  # not in the app\n' > "$SANDBOX/allow.txt"
lint_sandbox --allowlist "$SANDBOX/allow.txt" \
  || fail "(c) allowlisted file still failed" "$SANDBOX/out"

# (d)
printf 'Sources/Feature/Dropped.swift\nSources/Wired.swift\n' > "$SANDBOX/allow.txt"
if lint_sandbox --allowlist "$SANDBOX/allow.txt"; then
  fail "(d) lint accepted an allowlist entry for a wired file" "$SANDBOX/out"
fi
grep -q 'Sources/Wired.swift (now a member of cmux)' "$SANDBOX/out" \
  || fail "(d) output does not report the stale wired entry" "$SANDBOX/out"

# (e)
printf 'Sources/Feature/Dropped.swift\nSources/Gone.swift\n' > "$SANDBOX/allow.txt"
if lint_sandbox --allowlist "$SANDBOX/allow.txt"; then
  fail "(e) lint accepted an allowlist entry for a missing file" "$SANDBOX/out"
fi
grep -q 'Sources/Gone.swift (file does not exist)' "$SANDBOX/out" \
  || fail "(e) output does not report the stale missing entry" "$SANDBOX/out"

# (f)
mkdir -p "$SANDBOX/Sources/Copy"
echo 'struct Wired2 {}' > "$SANDBOX/Sources/Copy/Wired.swift"
if lint_sandbox --allowlist "$SANDBOX/allow.txt"; then
  fail "(f) lint accepted a second Wired.swift that is not in the target" "$SANDBOX/out"
fi
grep -q '  - Sources/Copy/Wired.swift' "$SANDBOX/out" \
  || fail "(f) output does not name the duplicate" "$SANDBOX/out"
rm -r "$SANDBOX/Sources/Copy"

# (g)
HASHED="$SANDBOX/repo#1"
mkdir -p "$HASHED"
cp -R "$SANDBOX/cmux.xcodeproj" "$SANDBOX/Sources" "$HASHED/"
if "$LINT" --repo-root "$HASHED" --target cmux --tests-dir Sources --recursive \
  >"$SANDBOX/out" 2>&1; then
  fail "(g) lint passed under a repo path containing #" "$SANDBOX/out"
fi
grep -q '  - Sources/Feature/Dropped.swift' "$SANDBOX/out" \
  || fail "(g) output does not name Sources/Feature/Dropped.swift" "$SANDBOX/out"

echo "test_ci_pbxproj_app_sources_wiring: ok"
