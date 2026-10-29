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
#  - dynamic_dispatch: string selectors and KVC by string key are counted;
#  - invariant_check / dump_will_be_check: report-only; the CI compare never judges them.
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

# 8b. Out-of-line test-only modules (2026-10-24: shell_integration's `#[cfg(all(test, unix))] mod test_pty;`
#     counted its unwraps as cmux-tui-core's): the file a `#[cfg(test)] mod name;` names (name.rs from lib.rs,
#     owner/name.rs from owner.rs, name/mod.rs, a #[path]) and the files below it are cut; a plain `mod name;`
#     and a `cfg(any(test, ...))` one still count.
src="$tmp/cmux-tui/crates/x/src"
mkdir -p "$src/shell/watch" "$src/helpers"
printf 'pub mod shell;\n#[cfg(test)]\nmod helpers;\n#[cfg(all(test, target_os = "macos"))]\n#[path = "odd/place.rs"]\nmod placed;\n' > "$src/lib.rs"
printf '#[cfg(all(test, unix))]\nmod test_pty;\n#[cfg(test)]\npub(crate) mod watch;\npub fn f() {}\n' > "$src/shell.rs"
printf 'fn t() { a.unwrap(); b.expect("x"); }\n' > "$src/shell/test_pty.rs"
printf 'mod deep;\nfn t() { a.unwrap(); }\n' > "$src/shell/watch/mod.rs"
printf 'fn t() { a.unwrap(); }\n' > "$src/shell/watch/deep.rs"
printf 'fn t() { a.unwrap(); }\n' > "$src/helpers/mod.rs"
mkdir -p "$src/odd"
printf 'fn t() { a.unwrap(); }\n' > "$src/odd/place.rs"
g add -A
out="$(ratchet)" || fail "an unwrap in an out-of-line cfg(test) module (or below one) counted: $out"
printf 'pub mod shell;\n#[cfg(any(test, feature = "x"))]\nmod helpers;\n' > "$src/lib.rs"
printf 'mod test_pty;\npub fn f() {}\n' > "$src/shell.rs"
rm -r "$src/shell/watch" "$src/odd"
g add -A
if out="$(ratchet)"; then fail "an unwrap in a plain or cfg(any(test, ...)) out-of-line module passed: $out"; fi
[[ "$out" == *"rust x: unwrap 0 -> 2"* ]] || fail "the plain and any(test) out-of-line hits are not reported: $out"
[[ "$out" == *"rust x: expect 0 -> 1"* ]] || fail "the plain out-of-line expect is not reported: $out"
g reset -q
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
printf 'var counts: [Int] = []\nfunc f() { counts[k] += 1 }\nlet lines = text.split(separator: " ")\nvar tally = [String: Int]()\nlet t = tally[k] + lines[i]\nlet u = reduce(into: [:]) { _ = into[k] }\n' > "$shared/Sources/MessagesLabHome/G.swift"
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
let e = self.transport.pending[i]
let b = Box.init(
    rows: [k: v]
)
let c = rows[j]
let d = UInt8(String(v, radix: 2).count)
SWIFT
printf 'struct T { var pending: [Int] = [] }\n' > "$shared/Sources/MessagesLabHome/G.swift"
g add -A
if out="$(ratchet)"; then fail "a qualified array member, an init label or a nested radix passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 3"* ]] || fail "transport.pending[i], self.transport.pending[i] or rows[j] was exempt: $out"
[[ "$out" == *"swift MessagesLabHome: int_conversion 0 -> 1"* ]] || fail "the nested radix exempted UInt8(...): $out"
g reset -q
reset

# 19. Dictionaries with an inferred or call-built type (lead, 2026-10-24; PL-main's push of
#     DaemonStore+SnapshotDiff.swift was refused for 3 lines that cannot trap): an assignment
#     through a subscript on a name not known to be indexable does not count (a Dictionary
#     cannot trap there), a `.reduce(into: [:])` / `Dictionary(...)` value is a dictionary for
#     reads too, and a true array or Data index still counts, read or assigned.
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
func record(memo: Memo, tree: Tree, workspaces: [WorkspaceModel]) {
    var applied = memo.applied
    for (id, snapshot) in tree.pairs { applied[id] = snapshot }
    applied[id] = nil
    var existing = workspaces.reduce(into: [:]) { $0[$1.id] = $1 }
    for model in workspaces { existing[model.id] = model }
    let seen = existing[key]
    let byKey = Dictionary(uniqueKeysWithValues: tree.pairs)
    _ = byKey[key]
}
SWIFT
g add -A
out="$(ratchet)" || fail "a dictionary subscript with an inferred or call-built type counted: $out"
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
func f(memo: Memo) {
    var rows: [Int] = []
    rows[i] = 1
    var bytes = Data()
    bytes[n] = 0
    var applied = memo.applied
    let v = applied[i]
}
SWIFT
g add -A
if out="$(ratchet)"; then fail "an array or Data index, or an inferred read, passed: $out"; fi
[[ "$out" == *"swift MessagesLabHome: index_subscript 0 -> 3"* ]] || fail "rows[i] = 1, bytes[n] = 0 or applied[i] (a read) was exempt: $out"
g reset -q
reset

# 20. The Invariant API: invariant_check and dump_will_be_check are report-only, so the CI
#    compare passes a check or dumpWillBeCheck site with no crash-allowlist entry, even when the allowlist names the
#    classes as banned (an unknown class bans nothing); --report counts each once. notFatalUntil is not a class, and a
#    doc comment that names a call never counts. guardrails.py's local-only invariant-site rule judges the sites.
cat > "$tmp/scripts/cmux-next/crash-allowlist.json" <<'JSON'
{"banned": ["swift.as_bang", "swift.objc_selector", "swift.invariant_check", "swift.dump_will_be_check"], "allow": []}
JSON
cat > "$app/Sources/M/A.swift" <<'SWIFT'
/// Invariant.check(a, "doc") in a doc comment.
Invariant.notFatalUntil(ok, "tab-in-workspace", build: 100)
Invariant.check(ok, "persisted-order")
Invariant.dumpWillBeCheck(ok, "cache-coherent")
SWIFT
g add -A
out="$(ratchet)" || fail "the CI compare judged an Invariant site: $out"
out="$(python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --report invariant_check,dump_will_be_check)" \
    || fail "--report invariant_check,dump_will_be_check failed: $out"
counts="$(printf '%s' "$out" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["invariant_check"]["total"], d["dump_will_be_check"]["total"])')"
[[ "$counts" == "1 1" ]] || fail "the Invariant sites are not reported once each: $out"
g reset -q
reset

# 21. trap_api (report-only): every pattern counts in every package's Sources (also outside
#     the app's closure), per module; a guarded removal, a checked offset, a safe count, comments and strings do
#     not; a crash-allow does not hide a hit from the report; the CI compare never sees the class.
report() { python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --report "$@"; }
hits() { python3 -c 'import json, sys; d = json.load(sys.stdin)[sys.argv[1]]; print(d["modules"].get(sys.argv[2], 0) if len(sys.argv) > 2 else d["total"])' "$@"; }
phone="$tmp/Packages/iOS/Phone/Sources/Phone"
mkdir -p "$phone"
cat > "$app/Sources/M/A.swift" <<'SWIFT'
let a = Dictionary(uniqueKeysWithValues: pairs)
let b = queue.removeFirst()
self.queue.removeLast(2)
let c = Array(repeating: 0, count: n)
let d = String(repeating: " ", count: width - used)
let e: [UInt8] = .init(repeating: 0, count: size)
let f = repeatElement(x, count: n)
let g = s.index(s.startIndex, offsetBy: n)
let h = s.index(
    s.startIndex,
    offsetBy: n
)
s.formIndex(&i, offsetBy: 2) // crash-allow: the report still counts it
let w = Array(
    repeating: 0,
    count: n
)
SWIFT
printf 'let p = items.removeLast()\n' > "$phone/P.swift"
g add -A
out="$(report trap_api)" || fail "--report trap_api failed: $out"
[[ "$(hits trap_api M <<<"$out")" == 11 ]] || fail "a trap_api pattern was missed (want 11 in M): $out"
[[ "$(hits trap_api Phone <<<"$out")" == 1 ]] || fail "trap_api outside the app's closure was missed: $out"
# Each hit's site: path, 1-based line of the call's opening, class and module (a wrapped call at its first line).
python3 - "$out" <<'PY' || fail "the report's hit sites are wrong: $out"
import json, sys
sites = {(s["path"], s["line"]): s for s in json.loads(sys.argv[1])["trap_api"]["hits"]}
a, p = "Packages/macOS/CmuxNext/Sources/M/A.swift", "Packages/iOS/Phone/Sources/Phone/P.swift"
want = [(a, n) for n in (1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14)] + [(p, 1)]
assert sorted(sites) == sorted(want), sorted(sites)
assert sites[(a, 9)] == {"path": a, "line": 9, "class": "trap_api", "module": "M", "hits": 1}, sites[(a, 9)]
assert sites[(a, 14)] == {"path": a, "line": 14, "class": "trap_api", "module": "M", "hits": 1}, sites[(a, 14)]
assert sites[(p, 1)]["module"] == "Phone", sites[(p, 1)]
PY
out="$(ratchet)" || fail "trap_api reached the CI compare: $out"
[[ "$out" != *trap_api* ]] || fail "the CI compare printed trap_api: $out"
cat > "$app/Sources/M/A.swift" <<'SWIFT'
guard !queue.isEmpty else { return }
let b = queue.removeFirst()
while let x = self.queue.first {
    queue.removeFirst()
}
if items.count > 3 { items.removeFirst(3) }
if name.hasPrefix("-") { name.removeFirst() }
let p = queue.popFirst()
mutating func removeLast() -> T { popLast()! }
let c = [Int](repeating: 0, count: 4)
let d = [UInt8](repeating: 0, count: 64 * 1024)
let e = Array(repeating: 0, count: rows.count)
let f = String(repeating: " ", count: max(0, width - used))
let v = SIMD4<Float>(repeating: 0)
let g = s.index(s.startIndex, offsetBy: n, limitedBy: s.endIndex)
let h = s.index(
    s.startIndex,
    offsetBy: n,
    limitedBy: s.endIndex
)
let i = s.index(after: i)
let w = Array(
    repeating: 0,
    count: rows.count
)
let x = String(
    describing: n
)
// let j = Dictionary(uniqueKeysWithValues: pairs)
let k = "removeFirst() uniqueKeysWithValues:"
SWIFT
printf 'let r = 1\n' > "$phone/P.swift"
out="$(report trap_api)" || fail "--report trap_api failed: $out"
[[ "$(hits trap_api <<<"$out")" == 0 ]] || fail "a guarded or safe form counted as trap_api: $out"
printf 'guard !other.isEmpty else { return }\nlet b = queue.removeFirst()\n' > "$app/Sources/M/A.swift"
out="$(report trap_api)" || fail "--report trap_api failed: $out"
[[ "$(hits trap_api M <<<"$out")" == 1 ]] || fail "another collection's guard exempted a removal: $out"
# 21b. validated counts and longer guards: a count shown non-negative (a literal comparison, a
#      guard above in scope, a `let` of a safe count, a `max` assignment, a type constant, a C constant, base64
#      padding, a ternary of literals, sums and products of those) and a removal behind a guard whose else block
#      runs several lines, or bounded by its receiver's count, do not count; the same shapes with a value that may
#      be negative still do.
cat > "$app/Sources/M/A.swift" <<'SWIFT'
enum Sizes {
    static let words = 8
    static let bytes = words * 4
}
func a(n: Int, keyLength: Int, side: Int, value: String, t: T, ipv6: Bool) {
    guard keyLength >= 1, keyLength <= 1024 else {
        return
    }
    let one = 1
    let two = 2
    let three = 3
    var key = [UInt8](repeating: 0, count: keyLength)
    let b = n > 0 ? Array(repeating: 0, count: n) : []
    let cols = max(1, t.columns)
    let c = [CGFloat](repeating: 16, count: cols)
    let d = [UInt8](repeating: 0, count: Sizes.bytes)
    let e = [CChar](repeating: 0, count: Int(clamping: INET6_ADDRSTRLEN))
    let f = String(repeating: "=", count: (4 - value.count % 4) % 4)
    let g = [UInt8](repeating: 0, count: ipv6 ? 16 : 4)
    let h = [UInt8](repeating: 0, count: cols * cols * 4)
    let w = max(0, side), hh = max(0, t.height)
    let i = [UInt32](repeating: 0, count: w * hh)
}
func next() -> Int? {
    guard let first = items.first else {
        idle()
        return nil
    }
    // the guard above holds here
    items.removeFirst()
    transcript.removeFirst(transcript.count / 4)
    scalars.removeLast(min(scalars.count, 64))
    return first
}
SWIFT
out="$(report trap_api)" || fail "--report trap_api failed: $out"
[[ "$(hits trap_api <<<"$out")" == 0 ]] || fail "a validated count or a longer guard counted as trap_api: $out"
cat > "$app/Sources/M/A.swift" <<'SWIFT'
enum Sizes {
    static let words = other - 1
}
func a(n: Int, side: Int, value: String, t: T, ipv6: Bool) {
    if n > 0 {
        a()
        b()
        c()
    }
    let a = Array(repeating: 0, count: n)
    let cols = t.columns - 1
    let c = [CGFloat](repeating: 16, count: cols)
    let d = [UInt8](repeating: 0, count: Sizes.words)
    let f = String(repeating: "=", count: 4 - remainder)
    let g = [UInt8](repeating: 0, count: ipv6 ? n : 4)
    let w = max(0, side), hh = t.height
    let i = [UInt32](repeating: 0, count: w * hh)
}
func next() -> Int? {
    guard let first = other.first else {
        idle()
        return nil
    }
    items.removeFirst()
    transcript.removeFirst(other.count / 4)
    scalars.removeLast(min(scalars.count, n))
    return first
}
SWIFT
out="$(report trap_api)" || fail "--report trap_api failed: $out"
[[ "$(hits trap_api M <<<"$out")" == 9 ]] || fail "an unvalidated count or an unguarded removal was missed (want 9): $out"
# 21c. a check that does not hold at the call proves nothing: each shape counts once. A
#      comparison in the false branch of a ternary, in an `if` block that closed before the call or in its `else`,
#      in a `||`; a `let` or a `guard` in another function; a C constant that is not a size; a clamp the value then
#      leaves (`max(0, x) - 10`); a clamp of `self.width` for a count of the parameter `width`; a reassignment, an
#      inout use or a later turn of a loop after the check; a closure parameter of the same name.
trap_shape() {
    local shape="$1"
    cat > "$app/Sources/M/A.swift"
    out="$(report trap_api)" || fail "--report trap_api failed: $out"
    [[ "$(hits trap_api M <<<"$out")" == 1 ]] || fail "a negative count passed as validated ($shape): $out"
}
trap_shape "the ternary's false branch" <<'SWIFT'
func f(n: Int) {
    let a = n > 0 ? [] : Array(repeating: 0, count: n)
}
SWIFT
trap_shape "an if block closed before the call" <<'SWIFT'
func f(n: Int) {
    if n > 0 { log() }
    let a = Array(repeating: 0, count: n)
}
SWIFT
trap_shape "the else of the check's if" <<'SWIFT'
func f(n: Int) {
    if n > 0 {
        log()
    } else {
        let a = Array(repeating: 0, count: n)
    }
}
SWIFT
trap_shape "a disjunction in the guard" <<'SWIFT'
func f(s: String, n: Int) {
    guard s.isEmpty || n > 0 else { return }
    let a = Array(repeating: 0, count: n)
}
SWIFT
trap_shape "a && under a || in the guard" <<'SWIFT'
func f(s: String, n: Int) {
    guard n > 0 && s.isEmpty || other else { return }
    let a = Array(repeating: 0, count: n)
}
SWIFT
trap_shape "a let in another function" <<'SWIFT'
func g() {
    let n = 4
    use(n)
}
func f(n: Int) {
    let a = Array(repeating: 0, count: n)
}
SWIFT
trap_shape "a guard in another function" <<'SWIFT'
func g(n: Int) {
    guard n >= 0 else { return }
    use(n)
}
func f(n: Int) {
    let a = Array(repeating: 0, count: n)
}
SWIFT
trap_shape "a C constant that is not a size" <<'SWIFT'
func f() {
    let a = Array(repeating: 0, count: Int(INT_MIN))
}
SWIFT
trap_shape "a clamp the value then leaves" <<'SWIFT'
func f(x: Int) {
    var m = max(0, x) - 10
    let a = Array(repeating: 0, count: m)
}
SWIFT
trap_shape "self.width clamped, the parameter width counted" <<'SWIFT'
init(width: Int) {
    self.width = max(0, width)
    self.cells = Array(repeating: 0, count: width)
}
SWIFT
trap_shape "a reassignment after the guard" <<'SWIFT'
func f(n: Int) {
    var n = n
    guard n >= 0 else { return }
    n -= 5
    let a = Array(repeating: 0, count: n)
}
SWIFT
trap_shape "an inout use after the binding" <<'SWIFT'
func f() {
    var size = 0
    query(&size)
    let a = [UInt8](repeating: 0, count: size)
}
SWIFT
trap_shape "a later turn of a loop" <<'SWIFT'
func f() {
    var room = 64
    for _ in 0 ..< 2 {
        let a = [Int32](repeating: 0, count: room)
        room = needed()
    }
}
SWIFT
trap_shape "a closure parameter of the same name" <<'SWIFT'
func f(n: Int) {
    guard n >= 0 else { return }
    let all = sizes.map { n in Array(repeating: 0, count: n) }
}
SWIFT
# ... and the same checks where they hold do not count.
cat > "$app/Sources/M/A.swift" <<'SWIFT'
init(width: Int, s: String, n: Int, x: Int) {
    self.width = max(0, width)
    self.cells = Array(repeating: 0, count: self.width)
    guard s.isEmpty && n >= 0 else {
        return
    }
    let a = Array(repeating: 0, count: n)
    var m = max(0, x)
    let b = Array(repeating: 0, count: m)
    let c = [CChar](repeating: 0, count: Int(PATH_MAX))
    if x > 0, s.isEmpty {
        let d = Array(repeating: 0, count: x)
    }
}
SWIFT
out="$(report trap_api)" || fail "--report trap_api failed: $out"
[[ "$(hits trap_api <<<"$out")" == 0 ]] || fail "a check that holds at the call did not validate its count: $out"
g reset -q
reset

# 22. --all-modules: index_subscript and int_conversion count in every module of every package with it, and in
#     the index modules (the CI rows, counted and waived together) without it; the CI compare stays on the index
#     modules only.
printf 'let a = rows[i]\nlet c = UInt8(value)\n' > "$app/Sources/M/A.swift"
printf 'let h = cells[j] // crash-allow: x\n' > "$shared/Sources/MessagesLabHome/F.swift"
out="$(report index_subscript,int_conversion)" || fail "--report index_subscript,int_conversion failed: $out"
[[ "$(hits index_subscript M <<<"$out")" == 0 ]] || fail "index_subscript counted outside the index modules without --all-modules: $out"
[[ "$(hits index_subscript MessagesLabHome <<<"$out")" == 1 ]] || fail "a waived index hit was hidden from the report: $out"
out="$(report index_subscript,int_conversion,trap_api --all-modules)" || fail "--all-modules failed: $out"
[[ "$(hits index_subscript M <<<"$out")" == 1 ]] || fail "--all-modules missed index_subscript in M: $out"
[[ "$(hits int_conversion M <<<"$out")" == 1 ]] || fail "--all-modules missed int_conversion in M: $out"
printf 'var m: [String: Int] = [:]\nlet a = m[key]\nlet c = UInt8(truncatingIfNeeded: value)\n' > "$app/Sources/M/A.swift"
out="$(report index_subscript,int_conversion --all-modules)" || fail "--all-modules failed: $out"
[[ "$(hits index_subscript M <<<"$out")" == 0 ]] || fail "--all-modules counted a dictionary subscript: $out"
[[ "$(hits int_conversion M <<<"$out")" == 0 ]] || fail "--all-modules counted a checked conversion: $out"
printf 'let a = rows[i]\n' > "$app/Sources/M/A.swift"
printf 'let h = 1\n' > "$shared/Sources/MessagesLabHome/F.swift"
out="$(ratchet)" || fail "--all-modules leaked into the CI compare: $out"
if out="$(python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --all-modules 2>&1)"; then
    fail "--all-modules without --report was accepted: $out"
fi
reset

# 23. The report baseline (crash-safety-report-baseline.json): only --report CLASS --update-report-baseline writes
#     it, index classes only with --all-modules; a class's first row records the tree, after that rows only go
#     down (a row the tree is over stays and exits 1); --report shows the baseline and the rows over it; the CI
#     baseline is unchanged and the CI compare never reads the report baseline.
rb="$tmp/scripts/cmux-next/crash-safety-report-baseline.json"
ci="$tmp/scripts/cmux-next/crash-safety-baseline.json"
cp "$ci" "$tmp/ci-before.json"
printf 'let a = rows[i]\nlet b = queue.removeFirst()\nlet c = q.removeLast()\n' > "$app/Sources/M/A.swift"
if out="$(report index_subscript --update-report-baseline 2>&1)"; then
    fail "an index class was recorded in the report baseline without --all-modules: $out"
fi
[[ ! -e "$rb" ]] || fail "a refused update wrote the report baseline"
out="$(report trap_api,index_subscript,int_conversion --all-modules --update-report-baseline)" \
    || fail "the first report baseline was refused: $out"
python3 - "$rb" <<'PY' || fail "the report baseline rows are wrong: $(cat "$rb")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["trap_api"] == {"scope": "packages", "modules": {"M": 2}}, d
assert d["index_subscript"] == {"scope": "all-modules", "modules": {"M": 1}}, d
assert d["int_conversion"] == {"scope": "all-modules", "modules": {}}, d
PY
cmp -s "$ci" "$tmp/ci-before.json" || fail "--update-report-baseline changed crash-safety-baseline.json"
out="$(report trap_api)"
[[ "$(hits trap_api <<<"$out")" == 2 ]] && [[ "$out" == *'"baseline": 2'* ]] && [[ "$out" == *'"over": {}'* ]] \
    || fail "--report does not show the report baseline: $out"
out="$(report index_subscript)"
[[ "$out" != *'"baseline"'* ]] || fail "an index-modules report was compared with the all-modules row: $out"
printf 'let a = rows[i]\nlet b = queue.removeFirst()\nlet c = q.removeLast()\nlet d = r.removeLast()\n' > "$app/Sources/M/A.swift"
out="$(report trap_api)" || fail "--report judged a row over the report baseline: $out"
[[ "$out" == *'"M": {'*'"baseline": 2'*'"now": 3'* ]] || fail "the row over the report baseline is not shown: $out"
if out="$(report trap_api --update-report-baseline)"; then fail "--update-report-baseline raised a row: $out"; fi
[[ "$out" == *"not raised: trap_api M 2 -> 3"* ]] || fail "the held row is not printed: $out"
[[ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["trap_api"]["modules"]["M"])' "$rb")" == 2 ]] \
    || fail "--update-report-baseline raised the trap_api row: $(cat "$rb")"
printf 'let a = rows[i]\n' > "$app/Sources/M/A.swift"
out="$(report trap_api --update-report-baseline)" || fail "lowering the report baseline failed: $out"
python3 - "$rb" <<'PY' || fail "the report baseline was not lowered, or another class changed: $(cat "$rb")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["trap_api"] == {"scope": "packages", "modules": {}}, d
assert d["index_subscript"] == {"scope": "all-modules", "modules": {"M": 1}}, d
PY
printf '{"swift": {"force_unwrap": {"M": 999}}}\n' > "$rb"
out="$(ratchet)" || fail "the CI compare read the report baseline: $out"
python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --update-baseline >/dev/null || true
cmp -s "$ci" "$tmp/ci-before.json" || fail "--update-baseline wrote a report row into crash-safety-baseline.json: $(cat "$ci")"
rm -f "$tmp/ci-before.json" "$rb"
reset

# 24. --classify (Q21): every hit gets exactly one trap class, input or invariant, and the
#     rule that gave it. Input: a decode entry point (Swift parse*, Rust decode*), its same-file callees, a body
#     that reads file bytes, a `// trap-class: input` mark. Invariant: an `INVARIANT:` reason (Rust) or no rule.
#     A string or a block comment never declares a function, and a bad mark is an error (exit 1).
cp "$here/trap-classes.json" "$tmp/scripts/cmux-next/"
cat > "$shared/Sources/MessagesLabHome/F.swift" <<'SWIFT'
func parseHeader(_ text: String) -> Int {
    let n = Int(text.count)
    return width(n)
}
func width(_ n: Int) -> Int {
    rows[n + 1]
}
func layout() -> Int {
    let s = "func parseFake() { width(1) }"
    /* func parseFake() {
       width(2) } */
    return rows[k + 1]
}
func load(path: URL) -> Int {
    let data = try? Data(contentsOf: path)
    return cells[m + 1]
}
func marked() -> Int {
    // trap-class: input the count comes from a peer frame
    return cells[m + 2]
}
SWIFT
cat > "$tmp/cmux-tui/crates/x/src/lib.rs" <<'RUST'
pub fn decode_frame(text: &str) -> usize {
    let n: usize = text.parse().unwrap();
    width(n)
}
fn width(n: usize) -> usize {
    Some(n).expect("width")
}
pub fn layout() -> usize {
    let s = "fn decode_fake() { width(1) }";
    Some(1).unwrap()
}
pub fn checked() -> usize {
    // INVARIANT: the table is built with one row
    Some(2).expect("one row")
}
RUST
g add -A
classify() { python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --classify; }
out="$(classify)" || fail "--classify failed on good marks: $out"
summary="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for h in d["hits"]:
    print(h["path"].split("/")[-1], h["line"], h["kind"], h["class"], h["rule"].split(" ")[0])
print("classes", d["classes"]["input"], d["classes"]["invariant"], sum(h["hits"] for h in d["hits"]))
' <<<"$out")"
expect() { [[ "$summary" == *"$1"* ]] || fail "--classify: expected '$1' in: $summary"; }
expect "F.swift 2 int_conversion input entry:parseHeader"
expect "F.swift 6 index_subscript input callee:width"
expect "F.swift 12 index_subscript invariant default"
expect "F.swift 16 index_subscript input bytes:load"
expect "F.swift 20 index_subscript input annotation"
expect "lib.rs 2 unwrap input entry:decode_frame"
expect "lib.rs 6 expect input callee:width"
expect "lib.rs 10 unwrap invariant default"
expect "lib.rs 14 expect invariant invariant-reason"
# Nine hits, each in exactly one class.
expect "classes 6 3 9"
# --report's classes classify too.
printf 'func parseX() async { await withCheckedContinuation { c in c.resume() } }\nfunc idle() async { await withCheckedContinuation { c in c.resume() } }\n' > "$shared/Sources/MessagesLabHome/F.swift"
g add -A
out="$(python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" --report raw_continuation --classify)" \
  || fail "--report raw_continuation --classify failed: $out"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["classes"])' <<<"$out")" == "{'input': 1, 'invariant': 1}" ]] \
  || fail "--report --classify did not class one input and one invariant continuation: $out"
# The trap classes of --report (task 092) classify over the scope --report counts them in: index_subscript and
# int_conversion over the index modules, or every module with --all-modules; trap_api over every package. Every hit
# --report counts has exactly one class (Q09: --report trap_api,index_subscript,int_conversion --all-modules --classify).
cat > "$app/Sources/M/A.swift" <<'SWIFT'
func parseRow(_ text: String) -> Int {
    let n = UInt8(text.count)
    return rows[Int(n)]
}
func layout() -> Int {
    queue.removeFirst()
    return cells[j]
}
SWIFT
printf 'func idle() -> Int {\n    return cells[k]\n}\n' > "$shared/Sources/MessagesLabHome/F.swift"
g add -A
crash() { python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" "$@"; }
rows() { python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for h in d["hits"]:
    print(h["path"].split("/")[-1], h["line"], h["kind"], h["hits"], h["class"], h["rule"].split(" ")[0])
print("classes", d["classes"]["input"], d["classes"]["invariant"])
'; }
out="$(crash --report index_subscript,int_conversion --classify)" || fail "--report index_subscript,int_conversion --classify failed: $out"
summary="$(rows <<<"$out")"
[[ "$summary" == $'F.swift 2 index_subscript 1 invariant default\nclasses 0 1' ]] \
    || fail "--classify without --all-modules left the index modules: $summary"
out="$(crash --report index_subscript,int_conversion --all-modules --classify)" \
    || fail "--report index_subscript,int_conversion --all-modules --classify failed: $out"
summary="$(rows <<<"$out")"
expect "A.swift 2 int_conversion 1 input entry:parseRow"
expect "A.swift 3 index_subscript 1 input entry:parseRow"
expect "A.swift 3 int_conversion 1 input entry:parseRow"
expect "A.swift 7 index_subscript 1 invariant default"
expect "F.swift 2 index_subscript 1 invariant default"
expect "classes 3 2"
out="$(crash --report trap_api,index_subscript,int_conversion --all-modules --classify)" \
    || fail "the Q09 command failed: $out"
summary="$(rows <<<"$out")"
expect "A.swift 6 trap_api 1 invariant default"
counted="$(crash --report trap_api,index_subscript,int_conversion --all-modules \
    | python3 -c 'import json, sys; print(sum(row["total"] for row in json.load(sys.stdin).values()))')"
[[ "$summary" == *"classes 3 3"* && "$counted" == 6 ]] \
    || fail "--classify does not give each of --report's $counted hits exactly one class: $summary"
if out="$(crash --report trap_api --classify --update-report-baseline 2>&1)"; then
    fail "--classify wrote the report baseline: $out"
fi
if out="$(crash --classify --all-modules 2>&1)"; then fail "--all-modules without --report was accepted: $out"; fi
# A mark without a class or a reason is an error.
printf 'func f() -> Int {\n    // trap-class: maybe\n    return rows[k + 1]\n}\n' > "$shared/Sources/MessagesLabHome/F.swift"
g add -A
if out="$(classify 2>&1)"; then fail "a trap-class mark without a class passed: $out"; fi
[[ "$out" == *"F.swift:2: a \`// trap-class:\` mark needs input or invariant and a reason"* ]] || fail "the bad mark is not named: $out"
g reset -q
reset

echo "crash-ratchet-v2.test.sh: ok"
