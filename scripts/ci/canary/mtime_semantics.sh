#!/usr/bin/env bash
# Canary (do not merge): does Xcode's incremental build notice a changed input
# whose modification time moved backwards? A content-derived mtime can be older
# than the previous one and older than the previous build's start.
set -euo pipefail

work="${RUNNER_TEMP:-/tmp}/mtime-canary"
explicit="${1:-YES}"
rm -rf "$work"
mkdir -p "$work/pkg/Sources/CValue/include" "$work/pkg/Sources/Tool"
cd "$work/pkg"

cat > Package.swift <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Tool",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CValue"),
        .executableTarget(name: "Tool", dependencies: ["CValue"]),
    ]
)
SWIFT
cat > Sources/CValue/include/cvalue.h <<'C'
static inline int c_value(void) { return 1; }
C
cat > Sources/CValue/cvalue.c <<'C'
#include "cvalue.h"
int c_anchor(void) { return c_value(); }
C
cat > Sources/Tool/Value.swift <<'SWIFT'
let swiftValue = 1
SWIFT
cat > Sources/Tool/main.swift <<'SWIFT'
import CValue
print("swift=\(swiftValue) c=\(c_value())")
SWIFT

old="200101010000.00"   # 2001-01-01, far before any build start
touch_all_old() { find . -path ./DD -prune -o -print0 | xargs -0 touch -t "$old"; }

build() {
  local label="$1" start end
  start=$(date +%s)
  xcodebuild -scheme Tool -destination 'platform=macOS' -derivedDataPath DD \
    SWIFT_ENABLE_EXPLICIT_MODULES="$explicit" build > "$work/build-$label.log" 2>&1 \
    || { tail -40 "$work/build-$label.log"; exit 1; }
  end=$(date +%s)
  local compiled
  compiled=$(grep -cE '^(SwiftCompile|CompileC|SwiftEmitModule|SwiftExplicitDependencyCompileModule|PrecompileModule|ScanDependencies) ' "$work/build-$label.log" || true)
  echo "$label: $(DD/Build/Products/Debug/Tool) tasks=$compiled seconds=$((end - start))"
  grep -E '^(SwiftCompile|CompileC|SwiftEmitModule|SwiftExplicitDependencyCompileModule|PrecompileModule|SwiftDriver) ' "$work/build-$label.log" | cut -c1-160 | sed 's/^/    /' || true
}

# Swap a file's content keeping its size, then pin its time.
rewrite() { # file from to time
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, a, b = sys.argv[1:]
t = open(p).read()
assert a in t and len(a) == len(b)
open(p, "w").write(t.replace(a, b))
PY
  if [ "$4" = now ]; then touch "$1"; else touch -t "$4" "$1"; fi
}

echo "== explicit modules: $explicit; $(xcodebuild -version | head -1)"
touch_all_old
build baseline
build null

# 1. Swift source, same size, time back to 2001 (it already was: identical time)
#    -> models a hash-to-time collision: mtime and size equal, content differs.
rewrite Sources/Tool/Value.swift "= 1" "= 2" "$old"
build swift-same-size-same-time
# 2. Swift source, same size, time moved backwards (older than before)
rewrite Sources/Tool/Value.swift "= 2" "= 3" 200001010000.00
build swift-same-size-older-time
# 3. C header, same size, time moved backwards
rewrite Sources/CValue/include/cvalue.h "return 1" "return 4" 200001010000.00
build header-same-size-older-time
# 4. C header, different size, time older than any build (a new content hash)
python3 - <<'PY'
p = "Sources/CValue/include/cvalue.h"
t = open(p).read().replace("return 4;", "return 55;")
open(p, "w").write(t)
PY
touch -t 199901010000.00 Sources/CValue/include/cvalue.h
build header-new-size-older-time
# 5. Control: C header changed and stamped now
python3 - <<'PY'
p = "Sources/CValue/include/cvalue.h"
t = open(p).read().replace("return 55;", "return 66;")
open(p, "w").write(t)
PY
touch Sources/CValue/include/cvalue.h
build header-now
echo "== expected final line: swift=3 c=66"
