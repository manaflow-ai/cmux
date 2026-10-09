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
mkdir -p "$tmp/scripts/cmux-next" "$tmp/cmux-tui/crates/x/src" "$app/Sources/M" "$shared/Sources/RenderText" "$shared/Sources/MessagesLabHome"
cp "$here/crash_ratchet.py" "$tmp/scripts/cmux-next/"
printf 'pub fn f() {}\n' > "$tmp/cmux-tui/crates/x/src/lib.rs"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "CmuxNext", dependencies: [.package(path: "../../Shared/Render")])\n' > "$app/Package.swift"
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Render")\n' > "$shared/Package.swift"
printf 'let a = 1\n' > "$app/Sources/M/A.swift"
printf 'let r = 1\n' > "$shared/Sources/RenderText/T.swift"
printf 'let h = 1\n' > "$shared/Sources/MessagesLabHome/F.swift"
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

# 6. False positives (chief, 2026-10-08): string text and comments never count; as! and
#    try! count only under their own classes; an IUO type in a parameter or return type is
#    iuo, not force_unwrap; an interpolated unwrap still counts.
cat > "$app/Sources/M/A.swift" <<'SWIFT'
let a = "Hello! world" // x! and y!
let b = "escaped \"quote! here"
let c = d as? Int /* e! */
SWIFT
out="$(ratchet)" || fail "string or comment text counted: $out"
printf 'let c = try! f()\n' > "$app/Sources/M/A.swift"
out="$(ratchet)" || fail "try! counted as a force unwrap: $out"
printf 'func w(_ v: V, didFinish navigation: WKNavigation!) -> Foo! { }\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "IUO parameter and return types passed: $out"; fi
[[ "$out" == *"swift M: iuo 0 -> 2"* ]] || fail "IUO types are not reported as iuo: $out"
[[ "$out" != *"force_unwrap"* ]] || fail "IUO types also counted as force_unwrap: $out"
printf 'print("\\(value!) ok")\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "an unwrap inside an interpolation passed: $out"; fi
[[ "$out" == *"swift M: force_unwrap 0 -> 1"* ]] || fail "the interpolated unwrap is not reported: $out"
reset

# 6b. An enum case or member named unowned is not an unowned reference.
printf 'enum O { case unowned = 0 }\nlet o: O = .unowned\nswitch o { case .unowned: break }\n' > "$app/Sources/M/A.swift"
out="$(ratchet)" || fail "an enum case named unowned counted: $out"
printf 'final class C { unowned let p: P }\n' > "$app/Sources/M/A.swift"
if out="$(ratchet)"; then fail "a real unowned passed: $out"; fi
reset

# 7. render_font: in a background-render module a font made in place counts; a static let
#    (made once per process) and the same call in another module do not (cx-qpqs).
printf 'func f() -> NSFont { NSFont.systemFont(ofSize: 10) }\n' > "$shared/Sources/MessagesLabHome/F.swift"
if out="$(ratchet)"; then fail "a font made in place in a render module passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: render_font 0 -> 1"* ]] || fail "render_font is not reported: $out"
printf 'enum F { static let f = NSFont.systemFont(ofSize: 10) }\n' > "$shared/Sources/MessagesLabHome/F.swift"
printf 'func f() -> NSFont { .systemFont(ofSize: 10) }\n' > "$app/Sources/M/A.swift"
out="$(ratchet)" || fail "a static let font or a font outside the render modules counted: $out"
reset

# 8. Rust inline test modules: cfg(test) and cfg(all(..., test, ...)) are cut;
#    any(test, ...) and all(not(test), ...) also build outside tests and count.
rs="$tmp/cmux-tui/crates/x/src/lib.rs"
printf 'pub fn f() {}\n#[cfg(all(test, unix))]\nmod tests {\n    fn t() { x.unwrap(); }\n}\n' > "$rs"
out="$(ratchet)" || fail "an unwrap in a cfg(all(test, unix)) module counted: $out"
printf 'pub fn f() {}\n#[cfg(all(unix, not(windows), test))]\nmod tests {\n    fn t() { x.unwrap(); }\n}\n' > "$rs"
out="$(ratchet)" || fail "an unwrap in a cfg(all(unix, not(windows), test)) module counted: $out"
printf 'pub fn f() {}\n#[cfg(any(test, feature = "x"))]\nmod m {\n    fn t() { x.unwrap(); }\n}\n' > "$rs"
if out="$(ratchet)"; then fail "an unwrap in a cfg(any(test, ...)) module passed: $out"; fi
[[ "$out" == *"rust x: unwrap 0 -> 1"* ]] || fail "the any(test) hit is not reported: $out"
printf 'pub fn f() {}\n#[cfg(all(not(test), unix))]\nmod m {\n    fn t() { x.unwrap(); }\n}\n' > "$rs"
if out="$(ratchet)"; then fail "an unwrap in a cfg(all(not(test), unix)) module passed: $out"; fi
reset

# 9. index_subscript and int_conversion (Lawrence, 2026-10-09) count only in the
#    background, render and decoder modules; optional lookups, literal indexes,
#    types and checked conversions do not count.
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
let a = rows[i]
let b = bytes[n - 1]
let c = UInt8(value)
SWIFT
if out="$(ratchet)"; then fail "a computed index and a trapping conversion passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 2"* ]] || fail "index_subscript is not reported: $out"
[[ "$out" == *"swift MessagesLabHome: int_conversion 0 -> 1"* ]] || fail "int_conversion is not reported: $out"
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
let a = rows[0]
let b = map[key] ?? 0
if let c = map[key] { use(c) }
let d: [String: Int] = [:]
let e = UInt8(truncatingIfNeeded: value)
let f = Int(text) ?? 0
let g = UInt32(exactly: big)
SWIFT
printf 'let a = rows[i]\nlet c = UInt8(value)\n' > "$app/Sources/M/A.swift"
out="$(ratchet)" || fail "safe forms or code outside the index modules counted: $out"
reset

# 10. Forms that cannot trap (chief, 2026-10-09): UInt8(ascii:), a pure integer
#     literal, a checked accessor, a dictionary subscript (a name the module declares
#     only as a dictionary, in any file, or a `default:` argument). A name declared as
#     an array anywhere in the module still counts, and so does a literal expression.
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
var counts: [String: Int] = [:]
var byID = [UUID: [Row]]()
let a = UInt8(ascii: ".")
let b = UInt8(0) + UInt32(0xff) + Int64(1_000)
let c = rows[checked: i]
counts[key] = 1
let d = tally[key, default: 0]
SWIFT
printf 'func f(params: [String: Any]) { byID[id] = nil; counts[k] += 1; _ = params[key] }\n' > "$shared/Sources/MessagesLabHome/G.swift"
g add -A
out="$(ratchet)" || fail "a non-trapping form counted: $out"
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
var counts: [String: Int] = [:]
let e = UInt8(1 + x)
SWIFT
printf 'var counts: [Int] = []\nfunc f() { counts[k] += 1 }\nlet lines = text.split(separator: " ")\nvar tally = [String: Int]()\nlet t = tally[k] + lines[i]\nlet u = reduce(into: [:]) { into[k] = 1 }\n' > "$shared/Sources/MessagesLabHome/G.swift"
g add -A
if out="$(ratchet)"; then fail "an array subscript or a literal expression passed: $out"; fi
# counts (also an array), lines (inferred) and into (a call label) count; tally does not.
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 3"* ]] || fail "a name declared as an array, inferred, or a call label was exempt: $out"
[[ "$out" == *"swift MessagesLabHome: int_conversion 0 -> 1"* ]] || fail "UInt8(1 + x) was exempt: $out"
g reset -q
reset

# 11. objc_observer: a selector-based NotificationCenter registration counts in every
#     module, also when the arguments span lines (a @MainActor @objc target traps when
#     the notification is posted off main); the block form with queue: .main does not.
cat > "$app/Sources/M/A.swift" <<'SWIFT'
center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
DistributedNotificationCenter.default().addObserver(
    self,
    selector: #selector(layoutChanged),
    name: name, object: nil)
SWIFT
printf 'nc.addObserver(self, selector: #selector(moved), name: n, object: clip)\n' > "$shared/Sources/RenderText/T.swift"
if out="$(ratchet)"; then fail "a selector-based observer passed: $out"; fi
[[ "$out" == *"swift M: objc_observer 0 -> 2"* ]] || fail "objc_observer (one line and multi-line) is not reported: $out"
[[ "$out" == *"swift RenderText: objc_observer 0 -> 1"* ]] || fail "objc_observer in a linked package is not reported: $out"
printf 'let r = 1\n' > "$shared/Sources/RenderText/T.swift"
cat > "$app/Sources/M/A.swift" <<'SWIFT'
token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
    // main-proof: registered with queue: .main
    MainActor.assumeIsolated { self?.changed() }
}
func addObserver(_ handler: @escaping () -> Void) -> Int { 0 }
let id = trail.addObserver { }
// center.addObserver(self, selector: #selector(old), name: name, object: nil)
SWIFT
out="$(ratchet)" || fail "a block observer or an unrelated addObserver counted: $out"
reset

# 12. A per-module ban ("swift.<class>@<Module>"): that class fails in that module even with
#    an inline crash-allow, and stays a ratchet class elsewhere.
cat > "$tmp/scripts/cmux-next/crash-allowlist.json" <<'JSON'
{"banned": ["swift.as_bang", "swift.objc_selector", "swift.index_subscript@MessagesLabHome"], "allow": []}
JSON
printf 'let a = rows[i] // crash-allow: x\n' > "$shared/Sources/MessagesLabHome/F.swift"
if out="$(ratchet)"; then fail "a module-banned class passed: $out"; fi
[[ "$out" == *"banned index_subscript in"* ]] || fail "the module ban is not reported: $out"
reset

# 13. A binding skips only its own bound value: a subscript or conversion elsewhere on a
#    binding line still counts (H7: guard let ctx = CGContext(width: Int(w * scale) ...)).
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
if let a = map[key] { use(a) }
guard let n = Int(text), let m = map[k] else { return }
guard let ctx = CGContext(width: Int(w * scale), height: rows[i]) else { return }
SWIFT
if out="$(ratchet)"; then fail "hits inside a binding's argument list passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 1"* ]] || fail "the index inside the binding is not reported: $out"
[[ "$out" == *"swift MessagesLabHome: int_conversion 0 -> 1"* ]] || fail "the conversion inside the binding is not reported: $out"
reset

# 14. async_closure_default_arg (cx-bsue, Swift 6.3.3 weak-symbol context size mismatch): an
#    async closure literal as a parameter default counts; a stored property with an async
#    closure value and a non-async default do not.
cat > "$app/Sources/M/A.swift" <<'SWIFT'
init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {}
func f(isOnline: @escaping @Sendable () async -> Bool = { true },
       other: Int = 1) {}
SWIFT
if out="$(ratchet)"; then fail "async closure defaults passed: $out"; fi
[[ "$out" == *"swift M: async_closure_default_arg 0 -> 2"* ]] || fail "async_closure_default_arg is not reported: $out"
cat > "$app/Sources/M/A.swift" <<'SWIFT'
var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
func g(done: @escaping () -> Void = {}) {}
SWIFT
out="$(ratchet)" || fail "a stored async closure or a sync default counted: $out"
reset

# 14b. The file's own declarations decide (H6 round 2): a dictionary declared in this
#     file stays a dictionary when another file of the module has a same-named array;
#     a name this file declares another way still counts.
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
var pending: [String: Int] = [:]
func f() { pending[key] = 1 }
SWIFT
printf 'var pending = Data()\nfunc g() { let x = pending.count }\n' > "$shared/Sources/MessagesLabHome/G.swift"
g add -A
out="$(ratchet)" || fail "a dictionary declared in its own file counted because of another file: $out"
printf 'var pending = Data()\nfunc g() { pending[i] = 1 }\n' > "$shared/Sources/MessagesLabHome/G.swift"
g add -A
if out="$(ratchet)"; then fail "an index on a file-local non-dictionary passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 1"* ]] || fail "the file-local Data index is not reported: $out"
g reset -q
reset

# 15. A string parse with radix: returns nil, so it does not count; Int(x) still does.
printf 'let a = Int(text, radix: 10) ?? 0\nlet b = UInt8(s, radix: 16)\nlet c = Int(x)\n' > "$shared/Sources/MessagesLabHome/F.swift"
if out="$(ratchet)"; then fail "Int(x) passed next to radix parses: $out"; fi
[[ "$out" == *"swift MessagesLabHome: int_conversion 0 -> 1"* ]] || fail "radix parses counted or Int(x) was missed: $out"
reset

# 16. Every dictionary parameter on a func line is a dictionary, not only the first.
printf 'func f(a: [String: Int], b: [String: String]) -> Bool { b[k] == nil }\n' > "$shared/Sources/MessagesLabHome/F.swift"
out="$(ratchet)" || fail "the second dictionary parameter counted: $out"
reset

# 17. A parameter list that continues on later lines declares its dictionaries too.
printf 'func f(\n    a: Int,\n    base: [String: String] = [:]\n) -> String? {\n    base[k]\n}\nlet x = foo(\n    base: other\n)\n' > "$shared/Sources/MessagesLabHome/F.swift"
out="$(ratchet)" || fail "a dictionary parameter on a continuation line counted: $out"
reset

# 18. Review findings: a member of another value uses the module rule (an array
#     member elsewhere still counts), a `.init(` call label is not a declaration,
#     and a radix: inside a nested call does not exempt the outer conversion.
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
var pending: [String: Int] = [:]
let a = transport.pending[i]
let b = Box.init(
    rows: [k: v]
)
let c = rows[j]
let d = UInt8(String(v, radix: 2).count)
SWIFT
printf 'struct T { var pending: [Int] = [] }\n' > "$shared/Sources/MessagesLabHome/G.swift"
g add -A
if out="$(ratchet)"; then fail "a qualified array member, an init label or a nested radix passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 2"* ]] || fail "transport.pending[i] or rows[j] was exempt: $out"
[[ "$out" == *"swift MessagesLabHome: int_conversion 0 -> 1"* ]] || fail "the nested radix exempted UInt8(...): $out"
g reset -q
reset

echo "crash-ratchet-v2.test.sh: ok"
