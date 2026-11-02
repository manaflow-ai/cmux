#!/usr/bin/env bash
# scripts/cmux-next/check-app-capability-references.py fails a tree whose app
# gates a feature on a daemon capability the same-tree daemon never serves
# (decision P10). It reads source only, so this test builds a small tree:
# DaemonEndpoint.swift (enum DaemonCapability), one app file, cmux-tui-core with one dependency crate.
# A planted gate on an unserved capability is red; removing it is green.
set -euo pipefail

check="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-app-capability-references.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sources="$tmp/Packages/macOS/CmuxNext/Sources"
core="$tmp/cmux-tui/crates/cmux-tui-core"
mkdir -p "$sources/CmuxNextDaemon/Connection" "$sources/CmuxNextApp" "$core/src/server" \
  "$tmp/cmux-tui/crates/cmux-tui-cloud-conversations/src"

cat > "$tmp/cmux-tui/Cargo.toml" <<'EOF'
[workspace.dependencies]
cmux-tui-cloud-conversations = { path = "crates/cmux-tui-cloud-conversations" }
EOF
cat > "$core/Cargo.toml" <<'EOF'
[package]
name = "cmux-tui-core"

[dependencies]
cmux-tui-cloud-conversations.workspace = true
EOF
cat > "$core/src/server.rs" <<'EOF'
pub const WORKSPACE_REGISTRY_CAPABILITY: &str = "workspace-registry-v1";
pub const TAB_DRAG_CAPABILITY: &str = "tab-drag-v1";
pub const TERMINAL_RESOURCES_CAPABILITY: &str = "terminal-resources-v1";
EOF
cat > "$core/src/server/capabilities.rs" <<'EOF'
pub(super) fn advertised_capabilities() -> Vec<&'static str> {
    vec![WORKSPACE_REGISTRY_CAPABILITY, "attach-identity-v1", TAB_DRAG_CAPABILITY]
}
EOF
cat > "$tmp/cmux-tui/crates/cmux-tui-cloud-conversations/src/lib.rs" <<'EOF'
pub const CLOUD_CONVERSATIONS_CAPABILITY: &str = "cloud-conversations-v1";
EOF

write_endpoint() { # optional-identifiers (`.name, .name`)
  cat > "$sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift" <<EOF
public enum DaemonCapability: String, CaseIterable, Sendable {
    case workspaceRegistry = "workspace-registry-v1"
    case tabDrag = "tab-drag-v1"
    case attachIdentity = "attach-identity-v1"
    case cloudConversations = "cloud-conversations-v1"
    case terminalResources = "terminal-resources-v1"

    public enum Tier: Sendable {
        case required, optional, unservedByBundledDaemon
    }

    public var tier: Tier {
        switch self {
        case .workspaceRegistry:
            return .required
        case $1:
            return .optional
        }
    }
}
EOF
}
write_app() { # extra Swift lines
  cat > "$sources/CmuxNextApp/Feature.swift" <<EOF
struct TerminalResourcesRequest {
    static let capability = "terminal-resources-v1"
}
struct Feature {
    func run(daemon: DaemonService) {
        // daemon.supports("commented-out-v1") is not a reference.
        if daemon.supports(DaemonCapability.tabDrag.rawValue) {}
        if daemon.supports("attach-identity-v1") {}
        if daemon.supports(DaemonCapability.cloudConversations) {}
        registry.bindUnavailable(["later"], ActionFailure.needsDaemonCapability("layout-templates-v1"))
        let label = #"a raw "string" with { a brace"#, other = "interpolated \(f("}")) text"
        if ctx.require(DaemonCapability.tabDrag.rawValue, on: daemon) {}
$1
    }
}
EOF
}
run() { python3 -I "$check" --repo "$tmp" 2>&1; }

write_endpoint ".tabDrag, .attachIdentity, .cloudConversations, .terminalResources"
write_app ""
out="$(run)" || fail "a tree whose daemon serves every gate failed: $out"
[[ "$out" == *"PASS"* ]] || fail "no PASS line: $out"
[[ "$out" == *"layout-templates-v1"* ]] || fail "a refusal-only capability is not reported as not built yet: $out"
[[ "$out" != *"commented-out-v1"* ]] || fail "a commented-out call counted: $out"

# Green: a gate on a capability the same-tree acpmux advertises (its own capability list, not cmux-tui-core's).
mkdir -p "$tmp/cmux-tui/crates/acpmux/src"
cat > "$tmp/cmux-tui/crates/acpmux/src/capabilities.rs" <<'EOF'
pub const CAPABILITIES: &[Capability] = &[
    Capability { id: "acpmux-v1", wire: &[] },
    Capability {
        id: "planted-acpmux-v1",
        wire: &[method::MUX_MACHINE_CONSENT_SET],
    },
];
EOF
write_app '        struct AcpmuxFeature { static let capability = "planted-acpmux-v1" }'
out="$(run)" || fail "a gate on a capability acpmux advertises failed: $out"
[[ "$out" == *"PASS"* ]] || fail "no PASS line for an acpmux gate: $out"
# Red: the same gate on a name acpmux does not define.
write_app '        struct AcpmuxFeature { static let capability = "planted-acpmux-typo-v1" }'
if out="$(run)"; then fail "a gate on a name acpmux does not define passed: $out"; fi
[[ "$out" == *"planted-acpmux-typo-v1"* ]] || fail "the failure does not name the misspelled capability: $out"
# Red: an id acpmux names only in a comment, a nested block comment, a doc or another constant, never in
# its CAPABILITIES list. Green: an id in the list after a string holding a bracket and a comment marker.
cat > "$tmp/cmux-tui/crates/acpmux/src/capabilities.rs" <<'EOF'
//! Retired: Capability { id: "planted-doc-v1" }.
pub const CAPABILITIES: &[Capability] = &[
    Capability { id: "acpmux-v1", wire: &["_acpmux/[x", "// not a comment"] },
    // Capability { id: "planted-commented-v1", wire: &[] },
    /* Capability { id: "planted-block-v1", /* nested */ wire: &[] }, */
    Capability { id: "planted-kept-v1", wire: &[] },
];
pub const RETIRED: &[Capability] = &[Capability { id: "planted-retired-v1", wire: &[] }];
EOF
for ghost in planted-commented-v1 planted-block-v1 planted-doc-v1 planted-retired-v1; do
  write_app "        struct AcpmuxFeature { static let capability = \"$ghost\" }"
  if out="$(run)"; then fail "a gate on $ghost, outside acpmux's CAPABILITIES, passed: $out"; fi
  [[ "$out" == *"$ghost"* ]] || fail "the failure does not name $ghost: $out"
done
write_app '        struct AcpmuxFeature { static let capability = "planted-kept-v1" }'
out="$(run)" || fail "an id in CAPABILITIES after a string holding a bracket and a comment marker failed: $out"

# Red: the app gates a feature on a capability no daemon crate defines.
write_app '        if daemon.supports("planted-unserved-v1") {}'
if out="$(run)"; then fail "a gate on an unserved capability passed: $out"; fi
[[ "$out" == *"planted-unserved-v1"* ]] || fail "the failure does not name the planted capability: $out"
[[ "$out" == *"Feature.swift:"* ]] || fail "the failure does not name the file and line: $out"

# The same through a constant of the type (`Self.capability`) is red too.
write_app '    }
    static let planted = "planted-constant-v1"
    func gate(daemon: DaemonService) {
        if daemon.supports(Self.planted) {}'
if out="$(run)"; then fail "a gate through a constant passed: $out"; fi
[[ "$out" == *"planted-constant-v1"* ]] || fail "the failure does not name the planted constant: $out"

# A literal in a two-argument require is a gate too.
write_app '        _ = ctx.require("planted-require-v1", on: daemon)'
if out="$(run)"; then fail "a two-argument require on an unserved capability passed: $out"; fi
[[ "$out" == *"planted-require-v1"* ]] || fail "the failure does not name planted-require-v1: $out"

# Green: the plant removed.
write_app ""
out="$(run)" || fail "the tree failed after the plant was removed: $out"

# A daemon capability the app gates on but leaves out of the lists is red:
# check-daemon-capabilities.sh would never prove the bundled binary serves it.
write_endpoint ".tabDrag, .attachIdentity, .cloudConversations"
python3 - "$sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# terminal-resources-v1 leaves the catalog; the app still gates on it through its own constant.
open(path, "w", encoding="utf-8").write(text.replace('    case terminalResources = "terminal-resources-v1"\n', ""))
PY
if out="$(run)"; then fail "an unlisted daemon capability passed: $out"; fi
[[ "$out" == *"terminal-resources-v1"* ]] || fail "the failure does not name terminal-resources-v1: $out"
[[ "$out" == *"optional"* ]] || fail "the failure does not say to list it in optional: $out"

# A capability constant declared outside the catalog's own list (a static in an extension in another
# file, which static members allow since cc7a964ef61) is in no list, so check-daemon-capabilities.sh
# never checks it and DaemonCompatibility never reports it missing. Red even when no daemon crate
# defines it yet.
write_endpoint ".tabDrag, .attachIdentity, .cloudConversations, .terminalResources"
write_app ""
cat > "$sources/CmuxNextApp/DaemonCapability+Orphan.swift" <<'SWIFT'
extension DaemonCapability {
    static let orphanExtension = "orphan-extension-v1"
}
SWIFT
if out="$(run)"; then fail "a capability constant in an extension passed: $out"; fi
[[ "$out" == *"orphan-extension-v1"* ]] || fail "the failure does not name the extension constant: $out"
rm "$sources/CmuxNextApp/DaemonCapability+Orphan.swift"

# A computed String static in an extension, used at a gate, is in no list and the resolver never
# followed it (`supports(DaemonCapability.orphanExt)` counted as no reference at all).
cat > "$sources/CmuxNextApp/DaemonCapability+Computed.swift" <<'SWIFT'
extension DaemonCapability {
    static var orphanExt: String { "orphan-ext-v1" }
}
struct Gate {
    func run(d: DaemonService) { _ = d.supports(DaemonCapability.orphanExt) }
}
SWIFT
if out="$(run)"; then fail "a computed String static in an extension passed: $out"; fi
[[ "$out" == *"orphanExt"* ]] || fail "the failure does not name the computed extension static: $out"
rm "$sources/CmuxNextApp/DaemonCapability+Computed.swift"

# The same declared in the catalog itself.
python3 - "$sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(
    "    public enum Tier: Sendable {",
    '    public static var orphanComputed: String { "orphan-computed-v1" }\n\n    public enum Tier: Sendable {', 1))
PY
grep -q orphanComputed "$sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift" || fail "the fixture lacks the computed static"
if out="$(run)"; then fail "a computed String static in the catalog passed: $out"; fi
[[ "$out" == *"orphanComputed"* ]] || fail "the failure does not name the computed catalog static: $out"
write_endpoint ".tabDrag, .attachIdentity, .cloudConversations, .terminalResources"
out="$(run)" || fail "the tree failed after the computed statics were removed: $out"

echo "app-capability-references.test.sh: ok"
