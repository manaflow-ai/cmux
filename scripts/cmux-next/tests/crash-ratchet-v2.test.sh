#!/usr/bin/env bash
# crash_ratchet.py v2 (plans/cmux-next/crash-elimination.md, phase 1):
#  - scope: every Swift package in the app's path-dependency closure, not only
#    CmuxNext (the 2026-10 TextLayout NSRangeException lived in
#    Packages/Shared/CmuxHomeRender, which v1 never scanned);
#  - BAN mode: a class listed in crash-allowlist.json "banned" ignores inline
#    crash-allow comments; only an allowlist entry (path, class, count, reason,
#    reviewer) passes;
#  - assumeIsolated with a `// main-proof:` comment does not count;
#  - objc_selector: a non-override @objc func with a labeled parameter must
#    spell its selector (PointerHover's `mouseEntered(with:)` was exported as
#    `mouseEnteredWith:` and AppKit raised "unrecognized selector");
#  - dynamic_dispatch: string selectors and KVC by string key are counted.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
ratchet() { python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" 2>&1; }

app="$tmp/Packages/macOS/CmuxNext"
shared="$tmp/Packages/Shared/Render"
mkdir -p "$tmp/scripts/cmux-next" "$tmp/cmux-tui/crates/x/src" "$app/Sources/M" "$shared/Sources/RenderText"
cp "$here/crash_ratchet.py" "$tmp/scripts/cmux-next/"
printf 'pub fn f() {}\n' > "$tmp/cmux-tui/crates/x/src/lib.rs"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "CmuxNext", dependencies: [.package(path: "../../Shared/Render")])\n' > "$app/Package.swift"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Render")\n' > "$shared/Package.swift"
printf 'let a = 1\n' > "$app/Sources/M/A.swift"
printf 'let r = 1\n' > "$shared/Sources/RenderText/T.swift"
cat > "$tmp/scripts/cmux-next/crash-allowlist.json" <<'JSON'
{"banned": ["swift.as_bang", "swift.objc_selector"], "allow": []}
JSON
g init -q && g add . && g commit -qm fixture
python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --update-baseline >/dev/null
g add . && g commit -qm baseline
out="$(ratchet)" || fail "the clean fixture is red: $out"
reset() { g checkout -q -- . && g clean -qfd; }

# 1. A linked shared package is in scope.
printf 'let r = s!\n' > "$shared/Sources/RenderText/T.swift"
if out="$(ratchet)"; then fail "a force unwrap in a linked shared package passed: $out"; fi
[[ "$out" == *"swift RenderText: force_unwrap 0 -> 1"* ]] || fail "the shared-package hit is not reported: $out"
reset

# 2. A banned class ignores an inline crash-allow; an allowlist entry passes.
printf 'let a = b as! Int // crash-allow: trust me\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "an inline crash-allow waived a banned class: $out"; fi
[[ "$out" == *"swift M: as_bang 0 -> 1"* ]] || fail "the banned hit is not reported: $out"
cat > "$tmp/scripts/cmux-next/crash-allowlist.json" <<'JSON'
{"banned": ["swift.as_bang", "swift.objc_selector"],
 "allow": [{"path": "Packages/macOS/CmuxNext/Sources/M/A.swift", "class": "swift.as_bang", "count": 1,
            "reason": "fixture", "reviewer": "crash-lead"}]}
JSON
out="$(ratchet)" || fail "an allowlist entry did not pass the banned hit: $out"
reset

# 3. assumeIsolated with a main-proof comment does not count; without one it does.
printf '// main-proof: registered with queue: .main\nMainActor.assumeIsolated { }\n' > "$app/Sources/M/A.swift"
out="$(ratchet)" || fail "a main-proof assumeIsolated counted: $out"
printf 'MainActor.assumeIsolated { }\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "an unproven assumeIsolated passed: $out"; fi
reset

# 4. objc_selector: labeled parameters need an explicit selector.
printf 'final class H: NSObject {\n    @objc func mouseEntered(with event: NSEvent) {}\n}\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "an inferred labeled @objc selector passed: $out"; fi
[[ "$out" == *"swift M: objc_selector 0 -> 1"* ]] || fail "the objc_selector hit is not reported: $out"
printf 'final class H: NSObject {\n    @objc\n    func handle(_ e: NSEvent, reply: NSEvent) {}\n}\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "a two-line @objc with a labeled second parameter passed: $out"; fi
cat > "$app/Sources/M/A.swift" <<'SWIFT'
final class H: NSView {
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
    @objc private func pressed(_ sender: Any?) {}
    @objc func fire() {}
}
SWIFT
out="$(ratchet)" || fail "explicit, override, sender and no-argument @objc forms counted: $out"
reset

# 5. dynamic_dispatch is counted per module.
printf 'let s = NSSelectorFromString("x:")\nview.setValue(1, forKey: "y")\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "new string dispatch passed: $out"; fi
[[ "$out" == *"swift M: dynamic_dispatch 0 -> 2"* ]] || fail "dynamic_dispatch is not reported: $out"
reset

echo "crash-ratchet-v2.test.sh: ok"
