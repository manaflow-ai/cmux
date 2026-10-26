#!/usr/bin/env bash
# Tests scripts/cmux-next/gen-chromium-host-wire.py on a fixture tree (a small cmux_cef_shim.h, its
# ops JSON, Swift callers and remote_cocoa mojoms) and on this checkout's real header. No build.
#
# Not in CI (p01-process section 4, rule 4: no new CI tests); run it when you change the generator,
# the header or plans/cmux-next/chromium-host-ops.json.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
gen="$repo/scripts/cmux-next/gen-chromium-host-wire.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/gen-chromium-host-wire.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

shimh=Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h
ops=plans/cmux-next/chromium-host-ops.json
library=Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFShimLibrary.swift
caller=Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFCaller.swift
outputs=(
  Packages/macOS/CmuxNext/ChromiumHost/src/generated/host_dispatch.inc
  Packages/macOS/CmuxNext/ChromiumHost/client/generated/remote_shim.inc
  Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/ChromiumHost/Generated/ChromiumHostOps.swift
)

# expect <exit code> <stderr/stdout must match (grep -E), or ""> <name> -- <generator args...>
expect() {
  local want="$1" pattern="$2" name="$3"
  shift 4
  local out code=0
  out="$(python3 "$gen" "$@" 2>&1)" || code=$?
  [[ "$code" == "$want" ]] || fail "$name: exit $code, expected $want; output:"$'\n'"$out"
  if [[ -n "$pattern" ]] && ! grep -qE -- "$pattern" <<<"$out"; then
    fail "$name: output does not match /$pattern/:"$'\n'"$out"
  fi
}

# --- Fixture tree -----------------------------------------------------------------------------

fixture() { # <root>: a header with every class, its ops JSON, the Swift name map and a caller
  local root="$1"
  mkdir -p "$root/$(dirname "$shimh")" "$root/$(dirname "$ops")" "$root/$(dirname "$caller")"
  cat >"$root/$shimh" <<'EOF'
// Fixture header. A #define that looks like an export is not one:
#define CMUX_SHIM_EXPORT __attribute__((visibility("default")))
#define CMUX_SHIM_FAKE CMUX_SHIM_EXPORT int cmux_shim_fake(void);
typedef enum {
  CMUX_SHIM_CONTEXT_INITIALIZED = 1,
  CMUX_SHIM_ADDRESS = 4,  // gaps keep the header's values
  CMUX_SHIM_TAB_EVENT,
  CMUX_SHIM_REPLY = 18,
} cmux_shim_event_kind_t;
typedef void (*cmux_shim_event_fn)(void* ctx, int kind, int browser_id, int request, int64_t a, int64_t b,
                                   const char* s1, const char* s2);
typedef int (*cmux_shim_focus_request_fn)(void* ctx, int browser_id, int source);
/* CMUX_SHIM_EXPORT int cmux_shim_commented_out(void); */
CMUX_SHIM_EXPORT const char* cmux_shim_abi_id(void);
CMUX_SHIM_EXPORT int cmux_shim_initialize(const char* root_cache_path, void* ctx, cmux_shim_event_fn event);
CMUX_SHIM_EXPORT void cmux_shim_set_background_color(unsigned int argb);
CMUX_SHIM_EXPORT int cmux_shim_create_window(int request, void* parent_view, int width, int height,
                                             const char* url);
CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_tab_go_to_entry(int browser_id, int offset);
// Caller frees with cmux_shim_free.
CMUX_SHIM_EXPORT char* cmux_shim_tab_navigation_state(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_visit_cookies(int browser_id, int reply);
CMUX_SHIM_EXPORT int cmux_shim_renderer_client_ids(int browser_id, int* out, int capacity);
CMUX_SHIM_EXPORT void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn handler);
CMUX_SHIM_EXPORT int cmux_shim_popup_window_attach(int window_id, void* parent_view, int width, int height);
CMUX_SHIM_EXPORT int cmux_shim_send_bytes(int browser_id, const void* data, size_t length);
CMUX_SHIM_EXPORT void cmux_shim_free(char* s);
EOF
  python3 - "$root/$ops" <<'EOF'
import json, sys

def entry(name, cls, args, returns, reason="", **extra):
    e = {"name": name, "class": cls, "args": [{"name": n, "type": t} for n, t in args], "returns": returns,
         "result_used_by": [], "mirror_key": None, "refresh_events": [], "pending_keys": [], "reply_event": None,
         "reason": reason}
    e.update(extra)
    return e

init = entry("cmux_shim_initialize", "local",
             [("root_cache_path", "const char*"), ("ctx", "void*"), ("event", "cmux_shim_event_fn")], "int",
             "stores event_fn; the host initializes")
init["args"][2]["function_pointer"] = True
handler = entry("cmux_shim_set_focus_request_handler", "policy", [("handler", "cmux_shim_focus_request_fn")],
                "void", "the host decides focus from a pushed policy")
handler["args"][0]["function_pointer"] = True
data = {
    "version": 1,
    "header": "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h",
    "pseudo_events": {"attach": "the host's hello"},
    "exports": [
        entry("cmux_shim_abi_id", "local", [], "const char*", "the remote returns its own identity"),
        init,
        entry("cmux_shim_set_background_color", "preinit", [("argb", "unsigned int")], "void"),
        entry("cmux_shim_create_window", "mint",
              [("request", "int"), ("parent_view", "void*"), ("width", "int"), ("height", "int"),
               ("url", "const char*")], "int", reply_event="CMUX_SHIM_ADDRESS"),
        entry("cmux_shim_go_back", "post", [("browser_id", "int")], "void",
              pending_keys=["tab.navigation_state[browser_id]"]),
        entry("cmux_shim_tab_go_to_entry", "post", [("browser_id", "int"), ("offset", "int")], "int",
              pending_keys=["tab.navigation_state[*]"]),
        entry("cmux_shim_tab_navigation_state", "mirror", [("browser_id", "int")], "char*",
              mirror_key="tab.navigation_state[browser_id]",
              refresh_events=["attach", "CMUX_SHIM_ADDRESS", "CMUX_SHIM_TAB_EVENT:3"]),
        entry("cmux_shim_visit_cookies", "async", [("browser_id", "int"), ("reply", "int")], "int",
              reply_event="CMUX_SHIM_REPLY"),
        entry("cmux_shim_renderer_client_ids", "async",
              [("browser_id", "int"), ("out", "int*"), ("capacity", "int")], "int", reply_event="wire:REPLY"),
        handler,
        entry("cmux_shim_popup_window_attach", "view",
              [("window_id", "int"), ("parent_view", "void*"), ("width", "int"), ("height", "int")], "int"),
        entry("cmux_shim_send_bytes", "post",
              [("browser_id", "int"), ("data", "const void*"), ("length", "size_t")], "int", channel="input"),
        entry("cmux_shim_free", "local", [("s", "char*")], "void", "frees client memory"),
    ],
    "events": [
        {"kind": "CMUX_SHIM_CONTEXT_INITIALIZED", "value": 1, "refreshes": []},
        {"kind": "CMUX_SHIM_ADDRESS", "value": 4, "refreshes": ["tab.navigation_state[browser_id]"]},
        {"kind": "CMUX_SHIM_TAB_EVENT", "value": 5, "refreshes": ["tab.navigation_state[browser_id]"]},
        {"kind": "CMUX_SHIM_REPLY", "value": 18, "refreshes": []},
    ],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
EOF
  cat >"$root/$library" <<'EOF'
struct CEFShimLibrary {
    init(r: Resolver) throws {
        goBack = try r("cmux_shim_go_back")
        tabGoToEntry = try r("cmux_shim_tab_go_to_entry")
        tabNavigationState = try r("cmux_shim_tab_navigation_state")
        visitCookies = try r("cmux_shim_visit_cookies")
        createWindow = try r("cmux_shim_create_window")
        setBackgroundColor = try r("cmux_shim_set_background_color")
    }
}
EOF
  cat >"$root/$caller" <<'EOF'
final class CEFCaller {
    // shim.goBack(1) in a comment is no call site.
    func back(_ shim: CEFShimLibrary?) {
        shim?.goBack(1)
        _ = shim?.tabGoToEntry(1, -1)
        let state = shim?.tabNavigationState(1)
        print(state as Any, "shim?.tabGoToEntry(2, 1) == 1 in a string is no call site")
    }

    func color(_ shim: CEFShimLibrary) {
        shim.setBackgroundColor(0)
    }
}
EOF
}

# A local or policy export needs its hand-written side for --check (the live queue of tasks 013-033).
hand_written() { # <root>
  mkdir -p "$1/Packages/macOS/CmuxNext/ChromiumHost/client" "$1/Packages/macOS/CmuxNext/ChromiumHost/src"
  cat >"$1/Packages/macOS/CmuxNext/ChromiumHost/client/remote_shim_local.mm" <<'EOF'
int cmux_shim_initialize(const char* root_cache_path, void* ctx, cmux_shim_event_fn event) { return 1; }
void cmux_shim_free(char* s) { free(s); }
EOF
  cat >"$1/Packages/macOS/CmuxNext/ChromiumHost/src/host_policy.mm" <<'EOF'
void InstallPolicySetFocusRequestHandler(HostContext& ctx, bool installed) {}
EOF
}

edit_ops() { # <root> <python statements on `d` (the parsed ops JSON)>
  python3 - "$1/$ops" "$2" <<'EOF'
import json, sys
path, code = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
by = {e["name"]: e for e in d["exports"]}
exec(code)
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
EOF
}

base="$work/base"
fixture "$base"
hand_written "$base"

# The header parse ignores comments and #define lines; counts come from the header.
expect 0 '"exports_count": 13' "dump-header counts" -- --root "$base" --dump-header
expect 0 '"events_count": 4' "dump-header events" -- --root "$base" --dump-header
python3 "$gen" --root "$base" --dump-header | grep -q cmux_shim_fake && fail "a #define counted as an export"
python3 "$gen" --root "$base" --dump-header | grep -q cmux_shim_commented_out && fail "a comment counted as an export"
expect 0 '"value": 5' "enum values continue after an explicit one" -- --root "$base" --dump-header

expect 0 "13/13 exports classified, 4/4 event kinds, 0 sync" "fixture ops valid" -- --root "$base" --check-ops
expect 1 "stale: .*host_dispatch.inc" "check before generation" -- --root "$base" --check
expect 0 "wrote .*ChromiumHostOps.swift" "generate" -- --root "$base"
expect 0 "13/13 exports classified" "check after generation" -- --root "$base" --check

# Two runs are byte-identical, and a second run writes nothing.
mkdir -p "$work/first"
for f in "${outputs[@]}"; do cp "$base/$f" "$work/first/$(basename "$f")"; done
out="$(python3 "$gen" --root "$base")"
[[ -z "$out" ]] || fail "a second run rewrote files: $out"
for f in "${outputs[@]}"; do cmp -s "$base/$f" "$work/first/$(basename "$f")" || fail "second run differs: $f"; done
second="$work/second"
fixture "$second"
python3 "$gen" --root "$second" >/dev/null
for f in "${outputs[@]}"; do cmp -s "$base/$f" "$second/$f" || fail "a fresh tree generates a different $f"; done

# What the generated code says, op by op.
client="$base/${outputs[1]}"
host="$base/${outputs[0]}"
swift="$base/${outputs[2]}"
grep -q 'kShimAbiID\[\] = "[0-9a-f]\{64\}"' "$client" || fail "the client has no header identity"
grep -q 'MarkPending(kOpTabNavigationState, token, pending_tab_navigation_state, 0x0u)' "$client" ||
  fail "go_back does not mark tab.navigation_state pending"
grep -q 'MarkPending(kOpTabNavigationState, token, pending_tab_navigation_state, 0x1u)' "$client" ||
  fail "tab_go_to_entry does not mark tab.navigation_state[*] pending with a wildcard"
grep -q 'PostPreinit(kOpSetBackgroundColor, w);' "$client" || fail "preinit is not queued"
grep -q 'PostInput(kOpSendBytes, 0, w);' "$client" || fail "an input-channel op goes on the control channel"
grep -q 'UnmigratedAsync(kOpRendererClientIds);' "$client" || fail "a wire:REPLY async op answers synchronously"
grep -q 'Post(kOpVisitCookies, NextToken(), w);' "$client" || fail "an event-answered async op is not posted"
grep -q 'MintID(kOpCreateWindow)' "$client" || fail "create_window does not mint"
grep -q 'MirrorLookup(kOpTabNavigationState, key)' "$client" || fail "the mirror does not read the cache"
grep -Eq 'cmux_shim_(initialize|free)\(' "$client" && fail "the generator emitted a local export"
grep -Eq 'wait|cond_|semaphore' "$client" && fail "the remote shim waits"
grep -q 'case kOpGoBack:' "$host" || fail "the host has no case for go_back"
grep -q 'cmux_shim_go_back(ctx.Browser(browser_id));' "$host" || fail "the host does not map the browser id"
grep -q 'ctx.BindMinted(kOpCreateWindow, minted, result);' "$host" || fail "the host does not bind the minted id"
grep -q 'InstallPolicySetFocusRequestHandler(ctx, installed);' "$host" || fail "the policy is not installed"
grep -q '{0, -1, kOpTabNavigationState},  // attach' "$host" || fail "attach does not refresh the mirror"
grep -q '{5, 3, kOpTabNavigationState},  // CMUX_SHIM_TAB_EVENT:3' "$host" || fail "sub-kind refresh missing"
grep -q 'cmux_shim_free(result);' "$host" || fail "the host leaks a char* mirror result"
grep -q ' goBack = 5,' "$swift" || fail "Swift op ids are not header order"
grep -q 'nonisolated enum ChromiumHostOp: UInt16, CaseIterable, Sendable' "$swift" || fail "Swift op type"
grep -q 'case contextInitialized = 1, address = 4, tabEvent = 5, reply = 18' "$swift" || fail "Swift event kinds"
grep -q 'Refresh(5, 3, .tabNavigationState)' "$swift" || fail "Swift refresh table"
grep -Eq '^(public |package )?(enum|struct) [A-Za-z]+ *\{' "$swift" && fail "a Swift type is not nonisolated"

# The result-use check: the fixture caller drops every post result.
expect 0 "0 post results read" "dropped results pass" -- --root "$base" --check-return-use
sites="$(python3 "$gen" --root "$base" --swift-sites)"
grep -q $'CEFCaller.swift:4\t' <<<"$sites" && fail "a post whose result is dropped is a site"
grep -q $'CEFCaller.swift:6\tcmux_shim_tab_navigation_state' <<<"$sites" && fail "a mirror read is a site"
grep -q 'string is no call site' <<<"$sites" && fail "a string literal counted as a call"

for form in 'guard shim?.tabGoToEntry(1, 1) == 1 else { return }' \
            'let moved = shim?.tabGoToEntry(1, 1)' \
            'if shim?.tabGoToEntry(1, 1) != 0 { print("moved") }' \
            'return shim?.tabGoToEntry(1, 1) == 1'; do
  bad="$work/return-use"
  rm -rf "$bad"
  fixture "$bad"
  cat >"$bad/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFReads.swift" <<EOF
func reads(_ shim: CEFShimLibrary?) -> Bool {
    $form
    return true
}
EOF
  expect 1 "CEFReads.swift:2: cmux_shim_tab_go_to_entry is post; this caller reads its result" \
    "result read: $form" -- --root "$bad" --check-return-use
  expect 0 $'CEFReads.swift:2\tcmux_shim_tab_go_to_entry\tpost\tresult-read' "site: $form" -- --root "$bad" --swift-sites
done
expect 0 $'CEFReads.swift\t1\tcmux_shim_tab_go_to_entry' "sites by file" -- --root "$bad" --swift-sites --by-file

# Refusals: each one alone makes --check-ops fail with its message.
refuse() { # <name> <python edit> <message pattern>
  local root="$work/refuse"
  rm -rf "$root"
  fixture "$root"
  edit_ops "$root" "$2"
  expect 1 "$3" "$1" -- --root "$root" --check-ops
}
refuse "unclassified export" 'd["exports"] = [e for e in d["exports"] if e["name"] != "cmux_shim_go_back"]' \
  "cmux_shim_go_back: unclassified"
refuse "sync class" 'by["cmux_shim_visit_cookies"]["class"] = "sync"' "class sync is refused"
refuse "function pointer in a post" 'by["cmux_shim_set_focus_request_handler"]["class"] = "post"' \
  "function-pointer argument 'handler' in a post export"
refuse "stale entry" 'd["exports"].append(dict(by["cmux_shim_go_back"], name="cmux_shim_gone"))' \
  "cmux_shim_gone: classified but not exported"
refuse "args drift" 'by["cmux_shim_go_back"]["args"][0]["type"] = "int64_t"' "args drifted from the header"
refuse "mirror without key" 'by["cmux_shim_tab_navigation_state"]["mirror_key"] = None' "needs mirror_key"
refuse "char* result posted" 'by["cmux_shim_tab_navigation_state"]["class"] = "post"' \
  "a char\* result must be mirror or async"
refuse "unknown pending key" 'by["cmux_shim_go_back"]["pending_keys"] = ["tab.nothing[browser_id]"]' \
  "pending key 'tab.nothing\[browser_id\]' is no mirror's key"
refuse "pending key names a missing arg" 'by["cmux_shim_go_back"]["pending_keys"] = ["tab.navigation_state[offset]"]' \
  "'offset' is not an argument"
refuse "event refresh mismatch" 'd["events"][1]["refreshes"] = []' "refresh_events name"
refuse "missing event kind" 'd["events"] = d["events"][:-1]' "CMUX_SHIM_REPLY: event kind missing"
refuse "local without reason" 'by["cmux_shim_free"]["reason"] = ""' "class local needs a reason"
refuse "async without an answer" 'by["cmux_shim_visit_cookies"]["reply_event"] = None' "names its answer"
refuse "out-parameters in an event" 'by["cmux_shim_renderer_client_ids"]["reply_event"] = "CMUX_SHIM_REPLY"' \
  "out-parameters come back in wire:REPLY"
refuse "event value drift" 'd["events"][1]["value"] = 9' "value 9 drifted"

# A (*fn) parameter written inline in the header is a function pointer too.
inline="$work/inline"
fixture "$inline"
sed -i.bak 's/CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id);/CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id, void (*fn)(void* context), void* context);/' \
  "$inline/$shimh"
edit_ops "$inline" 'by["cmux_shim_go_back"]["args"] += [{"name": "fn", "type": "void (*)(void* context)", "function_pointer": True}, {"name": "context", "type": "void*"}]'
expect 1 "cmux_shim_go_back: function-pointer argument 'fn' in a post export" "inline (\*fn) in a post" -- \
  --root "$inline" --check-ops

# --list-missing: the live queue (export, class, missing side).
missing="$work/missing"
fixture "$missing"
edit_ops "$missing" 'd["exports"] = [e for e in d["exports"] if e["name"] != "cmux_shim_go_back"]'
expect 0 $'cmux_shim_go_back\t-\tclassification' "list-missing classification" -- --root "$missing" --list-missing
expect 0 $'cmux_shim_initialize\tlocal\tclient' "list-missing local side" -- --root "$missing" --list-missing
expect 0 $'cmux_shim_set_focus_request_handler\tpolicy\thost' "list-missing policy side" -- --root "$missing" --list-missing
python3 "$gen" --root "$base" --list-missing | grep -q . && fail "--list-missing lists rows for a complete tree"

# --check-view-parity against vendored mojoms.
parity="$work/parity"
fixture "$parity"
expect 1 "chromium-host-view-parity.json is missing" "parity without its JSON" -- --root "$parity" --check-view-parity
mkdir -p "$parity/plans/cmux-next/remote_cocoa_mojom"
cat >"$parity/plans/cmux-next/remote_cocoa_mojom/render_widget_host_ns_view.mojom" <<'EOF'
// Fixture mojom.
interface RenderWidgetHostNSView {
  [Sync] SyncIsKeyWindow() => (bool is_key);  // a comment
  SetBackgroundColor(uint32 color);
  enum Unused { kA };
  Show();
};
EOF
sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
  "$parity/plans/cmux-next/remote_cocoa_mojom/render_widget_host_ns_view.mojom")"
cat >"$parity/plans/cmux-next/chromium-host-view-parity.json" <<EOF
{"mojoms": [{"file": "render_widget_host_ns_view.mojom", "sha256": "$sha"}],
 "methods": [
  {"mojom": "render_widget_host_ns_view.mojom", "interface": "RenderWidgetHostNSView", "method": "SyncIsKeyWindow",
   "not_needed": "cmux owns the window; the host reads key state from the pushed embedder-active policy"},
  {"mojom": "render_widget_host_ns_view.mojom", "interface": "RenderWidgetHostNSView", "method": "SetBackgroundColor",
   "op": "cmux_shim_set_background_color"}
 ]}
EOF
expect 1 "RenderWidgetHostNSView.Show: unmapped" "an unmapped method" -- --root "$parity" --check-view-parity
expect 0 "RenderWidgetHostNSView.Show" "list-unmapped" -- --root "$parity" --list-unmapped
python3 - "$parity/plans/cmux-next/chromium-host-view-parity.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["methods"].append({"mojom": "render_widget_host_ns_view.mojom", "interface": "RenderWidgetHostNSView",
                     "method": "Show", "event": "CMUX_SHIM_ADDRESS"})
json.dump(d, open(sys.argv[1], "w"))
EOF
expect 0 "" "all methods mapped" -- --root "$parity" --check-view-parity
echo "// drift" >>"$parity/plans/cmux-next/remote_cocoa_mojom/render_widget_host_ns_view.mojom"
expect 1 "changed since it was mapped" "mojom drift" -- --root "$parity" --check-view-parity

# --- This checkout ----------------------------------------------------------------------------

real="$(python3 "$gen" --root "$repo" --dump-header)"
want_exports="$(grep -oE 'CMUX_SHIM_EXPORT [^(]*\bcmux_shim_[a-z0-9_]+' "$repo/$shimh" | grep -c .)"
grep -q "\"exports_count\": $want_exports," <<<"$real" ||
  fail "the parsed export count differs from the header's $want_exports"
if [[ -f "$repo/$ops" ]]; then
  expect 0 "$want_exports/$want_exports exports classified" "the real header and ops JSON" -- --root "$repo" --check-ops
  # Generation from the real header is deterministic too (into a scratch tree, not the checkout).
  scratch="$work/real"
  mkdir -p "$scratch/$(dirname "$shimh")" "$scratch/$(dirname "$ops")"
  cp "$repo/$shimh" "$scratch/$shimh"
  cp "$repo/$ops" "$scratch/$ops"
  python3 "$gen" --root "$scratch" >/dev/null
  for f in "${outputs[@]}"; do cp "$scratch/$f" "$work/first/real-$(basename "$f")"; done
  rm -rf "$scratch/Packages/macOS/CmuxNext/ChromiumHost" \
    "$scratch/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/ChromiumHost"
  python3 "$gen" --root "$scratch" >/dev/null
  for f in "${outputs[@]}"; do
    cmp -s "$scratch/$f" "$work/first/real-$(basename "$f")" || fail "two runs on the real header differ: $f"
  done
else
  echo "note: $ops is not in this checkout (task p01-process-010); real-header ops check skipped" >&2
fi

echo "gen-chromium-host-wire tests: ok"
