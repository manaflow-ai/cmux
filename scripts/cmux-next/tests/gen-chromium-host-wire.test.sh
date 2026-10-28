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
CMUX_SHIM_EXPORT int cmux_shim_tab_add(int window_browser_id, const char* url);
CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id);
CMUX_SHIM_EXPORT int cmux_shim_tab_go_to_entry(int browser_id, int offset);
// Arguments named like the generator's own locals.
CMUX_SHIM_EXPORT int cmux_shim_before_unload_reply(int token, int accept);
CMUX_SHIM_EXPORT int cmux_shim_page_scheme_add(const char* id, const char* resource_root);
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
               ("url", "const char*")], "int", reply_event="CMUX_SHIM_ADDRESS", mint_returns="sent"),
        entry("cmux_shim_tab_add", "mint", [("window_browser_id", "int"), ("url", "const char*")], "int",
              reply_event="CMUX_SHIM_ADDRESS", mint_returns="id"),
        entry("cmux_shim_go_back", "post", [("browser_id", "int")], "void",
              pending_keys=["tab.navigation_state[browser_id]"]),
        entry("cmux_shim_tab_go_to_entry", "post", [("browser_id", "int"), ("offset", "int")], "int",
              pending_keys=["tab.navigation_state[*]"]),
        entry("cmux_shim_before_unload_reply", "post", [("token", "int"), ("accept", "int")], "int"),
        entry("cmux_shim_page_scheme_add", "preinit", [("id", "const char*"), ("resource_root", "const char*")],
              "int", reply_event="wire:REPLY"),
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
    "optional_exports": [
        entry("cmux_shim_tab_set_frozen", "async", [("browser_id", "int"), ("frozen", "int")], "int",
              reply_event="wire:REPLY", fork_api=29),
    ],
    "optional_events": [{"kind": "CMUX_SHIM_EVALUATE_RESULT", "value": 50, "refreshes": []}],
    "host_mode_rewrites": [],
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
        rendererClientIDs = try r("cmux_shim_renderer_client_ids")
        createWindow = try r("cmux_shim_create_window")
        setBackgroundColor = try r("cmux_shim_set_background_color")
        popupWindowAttach = try r("cmux_shim_popup_window_attach")
        tabSetFrozen = r.optional("cmux_shim_tab_set_frozen")
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
by = {e["name"]: e for e in d["exports"] + d.get("optional_exports", [])}
exec(code)
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
EOF
}

base="$work/base"
fixture "$base"
hand_written "$base"

# The header parse ignores comments and #define lines; counts come from the header.
expect 0 '"exports_count": 16' "dump-header counts" -- --root "$base" --dump-header
expect 0 '"events_count": 4' "dump-header events" -- --root "$base" --dump-header
python3 "$gen" --root "$base" --dump-header | grep -q cmux_shim_fake && fail "a #define counted as an export"
python3 "$gen" --root "$base" --dump-header | grep -q cmux_shim_commented_out && fail "a comment counted as an export"
expect 0 '"value": 5' "enum values continue after an explicit one" -- --root "$base" --dump-header
implicit="$work/implicit"
fixture "$implicit"
sed -i.bak 's/CMUX_SHIM_CONTEXT_INITIALIZED = 1,/CMUX_SHIM_CONTEXT_INITIALIZED,/' "$implicit/$shimh"
python3 "$gen" --root "$implicit" --dump-header | python3 -c '
import json, sys
events = json.load(sys.stdin)["events"]
sys.exit(0 if events[0] == {"kind": "CMUX_SHIM_CONTEXT_INITIALIZED", "value": 0} else 1)' ||
  fail "a first enumerator without an initializer is not 0"

summary="16/16 exports classified \(\+1 optional\), 4/4 event kinds \(\+1 optional\), 0 host-mode rewrites, 0 sync"
expect 0 "$summary" "fixture ops valid" -- --root "$base" --check-ops
expect 1 "stale: .*host_dispatch.inc" "check before generation" -- --root "$base" --check
expect 0 "wrote .*ChromiumHostOps.swift" "generate" -- --root "$base"
expect 0 "16/16 exports classified" "check after generation" -- --root "$base" --check

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
has() { # <file> <fixed string> <failure>
  grep -qF -- "$2" "$1" || fail "$3"
}
case_of() { # <file> <op constant>: the generated case block
  awk -v op="case $2: {" 'index($0, op) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"
}
has "$client" 'kShimAbiID[] = "' "the client has no header identity"
grep -q 'kWireID\[\] = "[0-9a-f]\{64\}"' "$client" || fail "the client has no wire identity"
has "$client" 'MarkPending(kOpTabNavigationState, op_token, pending_tab_navigation_state, 0x0u)' \
  "go_back does not mark tab.navigation_state pending"
has "$client" 'MarkPending(kOpTabNavigationState, op_token, pending_tab_navigation_state, 0x1u)' \
  "tab_go_to_entry does not mark tab.navigation_state[*] pending with a wildcard"
has "$client" '(void)PostPreinit(kOpSetBackgroundColor, 0, op_w);' "a void preinit is not queued"
has "$client" 'return PostPreinit(kOpPageSchemeAdd, op_token, op_w);' \
  "a non-void preinit does not return the client's check or await the host's verdict"
has "$client" '(void)PostInput(kOpSendBytes, 0, op_w);' "an input-channel op goes on the control channel"
has "$client" 'PostForReply(kOpRendererClientIds, op_token, op_w);' "a wire:REPLY async op is not sent"
has "$client" 'if (arg_out != nullptr && arg_capacity > 0) arg_out[0] = 0;' \
  "an async op leaves its out-parameter uninitialized"
has "$client" 'PostForReply(kOpVisitCookies, op_token, op_w);' "an event-answered async op is not sent"
has "$client" 'MintID(kOpCreateWindow)' "create_window does not mint"
grep -A12 'cmux_shim_create_window(' "$client" | grep -qF 'return op_sent ? 1 : 0;' ||
  fail "a mint_returns sent export does not return 1 when sent"
grep -A8 'cmux_shim_tab_add(' "$client" | grep -qF 'return op_sent ? minted_id : 0;' ||
  fail "a mint_returns id export does not return the minted id"
has "$client" 'MirrorLookup(kOpTabNavigationState, key_w)' "the mirror does not read the cache"
has "$client" 'CMUX_SHIM_EXPORT int cmux_shim_tab_set_frozen(int arg_browser_id, int arg_frozen)' \
  "an optional export has no remote definition"
grep -Eq 'cmux_shim_(initialize|free)\(' "$client" && fail "the generator emitted a local export"
grep -Eq '\bwait\(|wait_for|cond_|semaphore|UnmigratedAsync' "$client" && fail "the remote shim waits or drops an op"
has "$host" 'case kOpGoBack:' "the host has no case for go_back"
has "$host" 'cmux_shim_go_back(ctx.Browser(arg_browser_id));' "the host does not map the browser id"
# A post's pending keys are pushed again after the op runs and before its ACK (task 016b), so the
# value cmux reads once the ACK clears its mark is the host's after the op.
back="$(case_of "$host" kOpGoBack)"
[[ "$(grep -A4 -F 'cmux_shim_go_back(ctx.Browser(arg_browser_id));' <<<"$back" | tail -n 4 | sed 's/^ *//')" == \
   "TlvWriter refresh_tab_navigation_state;
refresh_tab_navigation_state.I32(arg_browser_id);
ctx.RefreshMirror(kOpTabNavigationState, refresh_tab_navigation_state, 0x0u);  // tab.navigation_state[browser_id]
ctx.Ack(wire_token);" ]] ||
  fail "go_back does not refresh tab.navigation_state[browser_id] between the call and its ACK"
grep -qF 'ctx.RefreshMirror(kOpTabNavigationState, refresh_tab_navigation_state, 0x1u);' \
  <<<"$(case_of "$host" kOpTabGoToEntry)" || fail "tab_go_to_entry does not refresh tab.navigation_state[*]"
grep -qF 'RefreshMirror' <<<"$(case_of "$host" kOpBeforeUnloadReply)" && fail "an op without pending keys refreshes"
has "$swift" 'Row(.post, [.int32], [],' "Swift go_back row"
has "$swift" '[PendingKey(.tabNavigationState, [0])]),' "Swift go_back pending key (frame field 0)"
has "$swift" '[PendingKey(.tabNavigationState, [nil])]),' "Swift tab_go_to_entry wildcard pending key"
has "$swift" 'var pendingKeys: [PendingKey] { row.pending }' "Swift pendingKeys"
has "$host" 'ctx.BindMintedOnEvent(kOpCreateWindow, minted_id, 4 /* CMUX_SHIM_ADDRESS */, arg_request, call_result);' \
  "the host does not bind a mint_returns sent id when its event comes"
has "$host" 'ctx.BindMinted(kOpTabAdd, minted_id, call_result, arg_window_browser_id);' \
  "the host does not bind the minted id with the op's browser as cmux sent it"
has "$host" 'InstallPolicySetFocusRequestHandler(ctx, policy_installed);' "the policy is not installed"
has "$host" '{-1, -1, kOpTabNavigationState},  // attach' "attach does not refresh the mirror"
has "$host" '{5, 3, kOpTabNavigationState},  // CMUX_SHIM_TAB_EVENT:3' "sub-kind refresh missing"
has "$host" 'if (call_result != nullptr) cmux_shim_free(call_result);' "the host leaks a char* mirror result"
has "$host" '{kOpTabSetFrozen, "cmux_shim_tab_set_frozen"},' "the optional export is not in kOptionalExports"
has "$client" '{kOpTabSetFrozen, "cmux_shim_tab_set_frozen"},' \
  "the client cannot refuse an optional export the host's HELLO does not list"
has "$host" 'reinterpret_cast<int (*)(int, int)>(ctx.OptionalExport(kOpTabSetFrozen))' \
  "the host calls an optional export the header does not declare"
# A C argument named token or reply never stands for the frame's token or the reply writer.
unload="$(case_of "$host" kOpBeforeUnloadReply)"
grep -qF 'cmux_shim_before_unload_reply(arg_token, arg_accept);' <<<"$unload" || fail "token argument not passed"
grep -qF 'ctx.Ack(wire_token);' <<<"$unload" || fail "an export's token argument hides the wire token"
grep -Eq 'Ack\(arg_token\)|Ack\(token\)' <<<"$unload" && fail "the host acks the export's token, not the op's"
cookies="$(case_of "$host" kOpVisitCookies)"
grep -qF 'const auto arg_reply = r.I32();' <<<"$cookies" || fail "the reply argument is not decoded"
grep -qF 'ctx.Reply(wire_token, reply_w);' <<<"$cookies" || fail "the async reply goes to the wrong token"
scheme="$(case_of "$host" kOpPageSchemeAdd)"
grep -qF 'ctx.Reply(wire_token, reply_w);' <<<"$scheme" || fail "a non-void preinit sends no verdict"
grep -Eq '\bgoBack = 6\b' "$swift" || fail "Swift op ids are not header order"
grep -Eq '\btabSetFrozen = 17\b' "$swift" || fail "an optional export's op id does not follow the header's"
grep -A1 'static let optionalOps: Set<ChromiumHostOp> = \[$' "$swift" | grep -q '^        \.tabSetFrozen,$' ||
  fail "Swift optional ops"
has "$swift" 'nonisolated enum ChromiumHostOp: UInt16, CaseIterable, Sendable' "Swift op type"
has "$swift" 'case contextInitialized = 1, address = 4, tabEvent = 5, reply = 18, evaluateResult = 50' \
  "Swift event kinds (with the optional event)"
has "$swift" 'Refresh(5, 3, .tabNavigationState)' "Swift refresh table"
grep -Eq '^(public |package )?(enum|struct) [A-Za-z]+ *\{' "$swift" && fail "a Swift type is not nonisolated"

# Both .inc files compile against the documented interface (declarations only), with -Wshadow, so a
# generated local that collides with or hides a C argument fails here and not first on the fleet.
stub="$work/stub"
mkdir -p "$stub"
cat >"$stub/wire_interface.h" <<'EOF'
// The cmux_remote and cmux_host interface of gen-chromium-host-wire.py's docstring.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>
namespace cmux_remote {
struct TlvWriter {
  void I32(int32_t); void U32(uint32_t); void I64(int64_t); void F64(double); void Str(const char*);
  void Bytes(const void*, size_t); void View(void*); void StrList(const char* const*, int);
};
struct TlvReader {
  bool present() const; int32_t I32(); uint32_t U32(); int64_t I64(); std::optional<std::string> Str();
  std::string Bytes(); void I32Array(int* out, int capacity);
};
bool Post(uint16_t op, uint32_t token, const TlvWriter&);
bool PostInput(uint16_t op, uint32_t token, const TlvWriter&);
bool PostForReply(uint16_t op, uint32_t token, const TlvWriter&);
int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter&);
uint32_t NextToken();
int32_t MintID(uint16_t op);
char* Dup(const std::string&);
void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards);
TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key);
void SetPolicy(uint16_t op, void* fn);
}  // namespace cmux_remote
namespace cmux_host {
struct TlvReader {
  int32_t I32(); uint32_t U32(); int64_t I64(); double F64(); std::optional<std::string> Str();
  std::string Bytes(); uint64_t View(); std::vector<std::string> StrList(); bool ok() const; bool AtEnd() const;
};
struct TlvWriter {
  void I32(int32_t); void U32(uint32_t); void I64(int64_t); void F64(double); void Str(const char*);
  void Bytes(const void*, size_t); void View(void*); void StrList(const char* const*, int);
  void I32Array(const int*, size_t);
};
struct HostContext {
  int Browser(int32_t client_id); void* PageView(uint64_t token); void* OptionalExport(uint16_t op);
  void Ack(uint32_t token); void Reply(uint32_t token, const TlvWriter&);
  void BindMinted(uint16_t op, int32_t minted, int64_t result, int32_t client_browser);
  void BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int32_t request, int64_t started);
  void PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value);
  void RefreshMirror(uint16_t op, const TlvWriter& key, uint32_t wildcards);
};
void Wipe(std::vector<std::string>&);
}  // namespace cmux_host
EOF
compile_inc() { # <tree root> <name>: c++ -fsyntax-only both generated .inc files of the tree
  local root="$1" name="$2" side inc
  for side in 0 1; do
    inc="$root/${outputs[$side]}"
    printf '#include "wire_interface.h"\nextern "C" {\n#include "%s"\n}\n#include "%s"\n' \
      "$root/$shimh" "$inc" >"$stub/tu.cc"
    "$cxx" -std=c++17 -fsyntax-only -Wall -Wextra -Wshadow -Werror -I"$stub" "$stub/tu.cc" 2>"$stub/errors" ||
      fail "$name: $(basename "$inc") does not compile:"$'\n'"$(head -20 "$stub/errors")"
  done
}
cxx="$(command -v c++ || command -v clang++ || command -v g++ || true)"
if [[ -n "$cxx" ]]; then
  compile_inc "$base" "fixture"
else
  echo "note: no C++ compiler; the generated .inc files were not compiled" >&2
fi

# A record struct of numbers only (as cmux_shim_ime_span: int, unsigned int, int64_t) goes field by
# field with each field's own wire type, and the host keeps no string slots to wipe for it.
records="$work/records"
fixture "$records"
hand_written "$records"
cat >>"$records/$shimh" <<'EOF'
typedef struct {
  int start;
  unsigned int color;
  int64_t stamp;
} cmux_shim_span;
CMUX_SHIM_EXPORT int cmux_shim_send_spans(int browser_id, const cmux_shim_span* spans, int span_count);
EOF
edit_ops "$records" 'd["exports"].append({"name": "cmux_shim_send_spans", "class": "post", "args": [
    {"name": "browser_id", "type": "int"}, {"name": "spans", "type": "const cmux_shim_span*"},
    {"name": "span_count", "type": "int"}], "returns": "int", "result_used_by": [], "mirror_key": None,
    "refresh_events": [], "pending_keys": [], "reply_event": None, "reason": "", "channel": "input"})'
expect 0 "17/17 exports classified" "a numeric record export is valid" -- --root "$records" --check-ops
python3 "$gen" --root "$records" >/dev/null
rclient="$records/${outputs[1]}"
has "$rclient" 'op_w.I32(arg_spans[i].start);' "a record's int field is not sent as I32"
has "$rclient" 'op_w.U32(arg_spans[i].color);' "a record's unsigned int field is not sent as U32"
has "$rclient" 'op_w.I64(arg_spans[i].stamp);' "a record's int64_t field is not sent as I64"
spans="$(case_of "$records/${outputs[0]}" kOpSendSpans)"
grep -qF 'arg_spans[i].start = r.I32();' <<<"$spans" || fail "a record's int field is not read as I32"
grep -qF 'arg_spans[i].color = r.U32();' <<<"$spans" || fail "a record's unsigned int field is not read as U32"
grep -qF 'arg_spans[i].stamp = r.I64();' <<<"$spans" || fail "a record's int64_t field is not read as I64"
grep -qE 'arg_spans_s|Wipe' <<<"$spans" && fail "a record without strings keeps string slots"
if [[ -n "$cxx" ]]; then
  compile_inc "$records" "numeric records"
fi

# The result-use check: the fixture caller drops every post result.
expect 0 "0 stand-in results read" "dropped results pass" -- --root "$base" --check-return-use
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

# A view export's remote returns a stand-in too: reading it is a result read, and the site keeps its
# view label.
view="$work/view-read"
fixture "$view"
cat >"$view/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPopup.swift" <<'EOF'
final class CEFPopup {
    func attach(_ shim: CEFShimLibrary) -> Int32 {
        let id = shim.popupWindowAttach(1, nil, 10, 10)
        return id
    }
}
EOF
expect 1 "CEFPopup.swift:3: cmux_shim_popup_window_attach is view; this caller reads its result" \
  "a bound view result" -- --root "$view" --check-return-use
expect 0 $'CEFPopup.swift:3\tcmux_shim_popup_window_attach\tview\tview,result-read' "a view site that reads" -- \
  --root "$view" --swift-sites

# An async site that reads its wire:REPLY answer in the call's turn is sync-reply until a
# host_mode_rewrites entry (needs reply) moves it to the token API (task 018); one whose answer is an
# event (visit_cookies: CMUX_SHIM_REPLY) reads only "sent" and is not.
sync="$work/sync-reply"
fixture "$sync"
cat >"$sync/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFProcesses.swift" <<'EOF'
extension CEFCaller {
    func ids(_ shim: CEFShimLibrary, _ out: UnsafeMutablePointer<Int32>) -> Int32 {
        let count = shim.rendererClientIDs(1, out, 4)
        guard shim.visitCookies(1, 9) == 1 else { return 0 }
        return count
    }
}
EOF
expect 0 $'CEFProcesses.swift:3\tcmux_shim_renderer_client_ids\tasync\tasync,sync-reply' "an out-parameter read at once" -- \
  --root "$sync" --swift-sites
expect 0 $'CEFProcesses.swift:4\tcmux_shim_visit_cookies\tasync\tasync$' "an event-answered start" -- \
  --root "$sync" --swift-sites
edit_ops "$sync" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/CEFProcesses.swift: CEFCaller.ids(_:_:)",
  "exports": ["cmux_shim_renderer_client_ids"], "needs": "reply", "change": "awaits the reply", "task": "p01-process-022"}]'
out="$(python3 "$gen" --root "$sync" --swift-sites)"
grep -q 'sync-reply' <<<"$out" && fail "a host_mode_rewrites site is still sync-reply: $out"
grep -q $'CEFProcesses.swift:3\tcmux_shim_renderer_client_ids\tasync\tasync$' <<<"$out" ||
  fail "the rewritten site lost its async row: $out"

# The same read through a closure: one passed inside a statement's head (CEFAgentRelay.send's
# `switch text.withCString({ shim.devToolsSend(browser, $0) })`), and one given the library by a
# function that takes a (CEFShimLibrary, ...) closure (CEFExtensionBackend's `call { $0.x($1) }`,
# by `$0` or a named parameter, behind an `if` on the same line). A dropped result is no read.
hidden="$work/sync-reply-closures"
fixture "$hidden"
cat >"$hidden/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFProcesses.swift" <<'EOF'
extension CEFCaller {
    func sent(_ shim: CEFShimLibrary, _ out: UnsafeMutablePointer<Int32>) -> Bool {
        switch "x".withCString({ _ in shim.rendererClientIDs(1, out, 4) }) {
        case 1: return true
        default: return false
        }
    }
    func through(_ out: UnsafeMutablePointer<Int32>) -> Bool { call { $0.rendererClientIDs($1, out, 4) } }
    func named(_ out: UnsafeMutablePointer<Int32>) -> Bool {
        if out.pointee > 0 { return call { library, browser in library.rendererClientIDs(browser, out, 4) } }
        return false
    }
    func dropped(_ out: UnsafeMutablePointer<Int32>) {
        call { library, browser in
            library.rendererClientIDs(browser, out, 4)
            return 1
        }
    }
    private func call(_ body: (CEFShimLibrary, Int32) -> Int32) -> Bool { body(library, 1) == 1 }
}
EOF
out="$(python3 "$gen" --root "$hidden" --swift-sites)"
for line in 3 8 10; do
  grep -q "CEFProcesses.swift:$line"$'\tcmux_shim_renderer_client_ids\tasync\tasync,sync-reply' <<<"$out" ||
    fail "the closure read on line $line is not sync-reply: $out"
done
grep -q $'CEFProcesses.swift:15\tcmux_shim_renderer_client_ids\tasync\tasync$' <<<"$out" ||
  fail "a dropped closure result is listed as read: $out"

# host_mode_rewrites accepts the listed function's calls of the listed exports, and nothing else.
rewrite="$work/rewrite"
fixture "$rewrite"
cat >"$rewrite/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFReads.swift" <<'EOF'
extension CEFCaller {
    func moves(_ shim: CEFShimLibrary?) -> Bool {
        shim?.tabGoToEntry(1, 1) == 1
    }

    func other(_ shim: CEFShimLibrary?) -> Bool {
        guard shim?.tabGoToEntry(1, 1) == 1 else { return false }
        return true
    }
}
EOF
edit_ops "$rewrite" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/CEFReads.swift: CEFCaller.moves(_:)",
  "exports": ["cmux_shim_tab_go_to_entry"], "needs": "reply", "change": "awaits the reply", "task": "p01-process-022"}]'
out="$(python3 "$gen" --root "$rewrite" --check-return-use 2>&1)" && fail "an unlisted read passed: $out"
grep -q 'CEFReads.swift:7:' <<<"$out" || fail "the unlisted read is not reported: $out"
grep -q 'CEFReads.swift:3:' <<<"$out" && fail "a host_mode_rewrites site is reported: $out"
edit_ops "$rewrite" 'd["host_mode_rewrites"][0]["site"] = "CmuxNextBrowser/CEF/CEFReads.swift: CEFCaller.moves(_:), other()"'
expect 1 "CEFReads.swift:7:" "only the head of a site names functions" -- --root "$rewrite" --check-return-use
edit_ops "$rewrite" 'd["host_mode_rewrites"][0]["site"] = "CmuxNextBrowser/CEF/CEFReads.swift: moves() and other()"'
expect 0 "0 stand-in results read" "a site that names two functions" -- --root "$rewrite" --check-return-use

# --swift-sites drops a site that is done: an async call, or a preinit whose
# verdict is a wire:REPLY, in the token form
# (inside a closure handed to sendAsync, siteCall or profileWrite), a mint_returns id call in the mint
# form (its id keys a `.reply(for:` wait), and a site listed with needs after_attach, host_exit or
# kept. A `reply` entry alone does not settle a site: its call must take the token form. A mint call
# in sendAsync and a mint read stay listed.
settled="$work/settled"
fixture "$settled"
python3 - "$settled/$library" <<'EOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('        goBack = try r("cmux_shim_go_back")\n',
                    '        goBack = try r("cmux_shim_go_back")\n        tabAdd = try r("cmux_shim_tab_add")\n'
                    '        initialize = try r("cmux_shim_initialize")\n'
                    '        pageSchemeAdd = try r("cmux_shim_page_scheme_add")\n')
open(path, "w", encoding="utf-8").write(text)
EOF
cat >"$settled/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFAsync.swift" <<'EOF'
extension CEFRuntime {
    func cookies() async throws -> CEFSiteReply {
        let reply = try await siteCall(1, what: "visit") { shim, id in shim.visitCookies(1, id) }
        return reply
    }

    func sent() -> Int32 {
        let answer = sendAsync { shim in
            "x".withCString { _ in shim.visitCookies(1, 2) }
        }
        return 0
    }

    func direct(_ shim: CEFShimLibrary) -> Bool {
        shim.visitCookies(1, 3) == 1
    }

    func window(_ shim: CEFShimLibrary) -> Int32 {
        shim.createWindow(1, nil, 1, 1, nil)
    }

    func later(_ shim: CEFShimLibrary) {
        let answer = sendAsync { _ in 0 }
        _ = shim.visitCookies(1, 4)
    }

    func mintedInToken() {
        let answer = sendAsync { shim in shim.tabAdd(1, nil) }
    }

    func minted(_ shim: CEFShimLibrary) async throws -> String {
        let id = shim.tabAdd(1, nil)
        let key = Key(browser: 1, id: id)
        return try await waits.reply(for: key, timeout: .seconds(1)) { Failure() }
    }

    func mintedRead(_ shim: CEFShimLibrary) -> Bool {
        shim.tabAdd(1, nil) != 0
    }

    func boot(_ library: Boot) {
        if case .inProcess = library, shim.initialize(nil, nil, nil) != 1 { return }
    }

    func scheme() {
        let verdict = sendAsync { shim in shim.pageSchemeAdd("x", "/tmp") }
    }

    func schemeRead(_ shim: CEFShimLibrary) -> Bool {
        shim.pageSchemeAdd("y", "/tmp") == 1
    }
}
EOF
listed() { grep -q "CEFAsync.swift:$1"$'\t' <<<"$sites"; }
sites="$(python3 "$gen" --root "$settled" --swift-sites)"
# A preinit whose verdict is a wire:REPLY is done in the token form too.
for line in 3 9 32 46; do
  listed "$line" && fail "a call in the token or mint form is listed (line $line): $sites"
done
for line in 15 19 24 28 38 42 50; do
  listed "$line" || fail "a site in neither form is not listed (line $line): $sites"
done
edit_ops "$settled" 'd["host_mode_rewrites"] = [
  {"site": "CmuxNextBrowser/CEF/CEFAsync.swift: CEFRuntime.boot(_:)", "exports": ["cmux_shim_initialize"],
   "needs": "kept", "change": "Runs only for CEFRuntimeBoot.inProcess.", "task": "p01-process-021"},
  {"site": "CmuxNextBrowser/CEF/CEFAsync.swift: CEFRuntime.direct(_:)", "exports": ["cmux_shim_visit_cookies"],
   "needs": "reply", "change": "awaits the reply", "task": "p01-process-021"},
  {"site": "CmuxNextBrowser/CEF/CEFAsync.swift: CEFRuntime.mintedRead(_:)", "exports": ["cmux_shim_tab_add"],
   "needs": "host_exit", "change": "fails when the host exits", "task": "p01-process-091"}]'
expect 0 "" "kept, reply and host_exit entries are valid" -- --root "$settled" --check-ops
sites="$(python3 "$gen" --root "$settled" --swift-sites)"
listed 42 && fail "a kept site is listed: $sites"
listed 15 || fail "a reply entry settled a call not in the token form: $sites"
listed 38 && fail "a host_exit site is listed: $sites"
# needs client: a local export the client defines by hand (HOST/client, outside
# generated/) is the same call in both backends. change names its wire entry point; the site stays
# listed until HOST/client defines the export and calls that entry point (its own declarations,
# definitions and member forwarders are no call).
edit_ops "$settled" 'd["host_mode_rewrites"][0] = {"site": "CmuxNextBrowser/CEF/CEFAsync.swift: CEFRuntime.boot(_:)",
  "exports": ["cmux_shim_initialize"], "needs": "client", "change": "The same call in both backends.", "task": "p01-process-025"}'
expect 1 "needs client names the client's wire entry point" "a client entry that names no wire entry point" -- --root "$settled" --check-ops
edit_ops "$settled" 'd["host_mode_rewrites"][0]["change"] = "The same call in both backends, sent by cmux_remote::PostInitialize."'
expect 0 "" "a client entry is valid" -- --root "$settled" --check-ops
sites="$(python3 "$gen" --root "$settled" --swift-sites)"
listed 42 || fail "a client site whose export HOST/client does not define is not listed: $sites"
hand_written "$settled"
sites="$(python3 "$gen" --root "$settled" --swift-sites)"
listed 42 || fail "a client site whose wire entry point nothing calls is not listed: $sites"
wire_file="$settled/Packages/macOS/CmuxNext/ChromiumHost/client/remote_shim_wire.mm"
cat >"$wire_file" <<'EOF'
bool PostInitialize(uint32_t token, InitializedFn done);
char* PostInitialize(int unused);
bool PostInitialize(uint32_t token, InitializedFn done) { return R().PostInitialize(token, done); }
bool Runtime::PostInitialize(uint32_t token, InitializedFn done) { return runtime->PostInitialize(token, done); }
// cmux_remote::PostInitialize(token, &Deliver) in a comment is no call.
EOF
sites="$(python3 "$gen" --root "$settled" --swift-sites)"
listed 42 || fail "declarations, definitions and member calls of the wire entry point settled a client site: $sites"
cat >>"$wire_file" <<'EOF'
bool SendInitialize(void*, uint32_t token) { return cmux_remote::PostInitialize(token, &DeliverInitialize); }
EOF
sites="$(python3 "$gen" --root "$settled" --swift-sites)"
listed 42 && fail "a client site whose export HOST/client defines and whose wire entry point it calls is listed: $sites"
rm "$wire_file"
edit_ops "$settled" 'd["host_mode_rewrites"][0]["site"] = "CmuxNextBrowser/CEF/CEFAsync.swift: CEFRuntime.window(_:)"
d["host_mode_rewrites"][0]["exports"] = ["cmux_shim_create_window"]'
expect 1 "needs client is for local exports the client defines; cmux_shim_create_window is mint" "a client mint" -- --root "$settled" --check-ops
edit_ops "$settled" 'd["host_mode_rewrites"][0] = {"site": "CmuxNextBrowser/CEF/CEFAsync.swift: CEFRuntime.window(_:)",
  "exports": ["cmux_shim_create_window"], "needs": "kept", "change": "returns the minted id", "task": "p01-process-021"}'
expect 0 "" "a kept mint site is valid" -- --root "$settled" --check-ops
edit_ops "$settled" 'd["host_mode_rewrites"][0]["needs"] = "later"'
expect 1 "needs 'later' is not one of" "an unknown needs" -- --root "$settled" --check-ops

# --check-pre-attach: a mirror read on the startup path (CEFRuntime.initialize and what it hands the
# shim to) needs a host_mode_rewrites entry with needs after_attach.
attach="$work/pre-attach"
fixture "$attach"
cat >"$attach/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFLibraryLoader.swift" <<'EOF'
nonisolated struct CEFLibraryLoader {
    func load(_ shim: Int) -> Int { shim }
}
EOF
cat >"$attach/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFRuntime.swift" <<'EOF'
final class CEFRuntime {
    // The in-process load is CEFLibraryLoader.load, the other startup root.

    private func initialize(
        _ library: CEFLoadedLibrary,
        environment: [String: String]
    ) throws(BootError) {
        let shim = library.shim
        let state = shim.tabNavigationState(1)
        let features = CEFForkFeatures(shim)
        print(state as Any, features)
    }

    func later(_ shim: CEFShimLibrary) {
        print(shim.tabNavigationState(2) as Any)
    }
}

struct CEFForkFeatures {
    let state: String?

    init(_ shim: CEFShimLibrary) {
        state = shim.tabNavigationState(3)
    }
}
EOF
out="$(python3 "$gen" --root "$attach" --check-pre-attach 2>&1)" && fail "a pre-attach mirror read passed: $out"
grep -q 'CEFRuntime.swift:9: cmux_shim_tab_navigation_state is a mirror read in CEFRuntime.initialize' <<<"$out" ||
  fail "the startup read is not reported: $out"
grep -q 'CEFRuntime.swift:23: .* in CEFForkFeatures.init' <<<"$out" || fail "a callee given the shim is not followed: $out"
grep -q 'CEFRuntime.swift:15:' <<<"$out" && fail "a read after startup is reported: $out"
edit_ops "$attach" 'd["host_mode_rewrites"] = [
  {"site": "CmuxNextBrowser/CEF/CEFRuntime.swift: CEFRuntime.initialize(_:environment:)",
   "exports": ["cmux_shim_tab_navigation_state"], "needs": "after_attach", "change": "after the await",
   "task": "p01-process-015"},
  {"site": "CmuxNextBrowser/CEF/CEFRuntime.swift: CEFForkFeatures.init(_:)",
   "exports": ["cmux_shim_tab_navigation_state"], "needs": "reply", "change": "not an attach fix",
   "task": "p01-process-015"}]'
expect 1 "CEFRuntime.swift:23: .*CEFForkFeatures.init" "a rewrite that does not wait for attach" -- \
  --root "$attach" --check-pre-attach
edit_ops "$attach" 'd["host_mode_rewrites"][1]["needs"] = "after_attach"'
expect 0 "0 mirror reads before attach" "listed startup reads" -- --root "$attach" --check-pre-attach
rm "$attach/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFRuntime.swift"
expect 1 "startup root CEFRuntime.initialize is not in" "a startup root that moved" -- --root "$attach" --check-pre-attach

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
refuse "unknown top-level key" 'd["extras"] = []' "unknown top-level keys \['extras'\]"
refuse "mint without mint_returns" 'del by["cmux_shim_tab_add"]["mint_returns"]' "mint_returns is id or sent"
refuse "mint_returns outside mint" 'by["cmux_shim_go_back"]["mint_returns"] = "id"' "mint_returns is for mint exports"
refuse "mint sent without request" 'by["cmux_shim_tab_add"]["mint_returns"] = "sent"' \
  "mint_returns sent needs an int .request. argument"
refuse "non-void preinit without a verdict" 'by["cmux_shim_page_scheme_add"]["reply_event"] = None' \
  "a non-void preinit returns the client's own check"
refuse "void preinit with a verdict" 'by["cmux_shim_set_background_color"]["reply_event"] = "wire:REPLY"' \
  "a void preinit has no verdict"
refuse "wire:REPLY on a post" 'by["cmux_shim_tab_go_to_entry"]["reply_event"] = "wire:REPLY"' \
  "a post export returns at once"
refuse "optional export the header declares" \
  'd["optional_exports"].append(dict(by["cmux_shim_go_back"], fork_api=29)); d["exports"].remove(by["cmux_shim_go_back"])' \
  "cmux_shim_go_back: the header declares it now"
refuse "optional export without fork_api" 'del by["cmux_shim_tab_set_frozen"]["fork_api"]' "names the fork API"
refuse "optional event value taken" 'd["optional_events"][0]["value"] = 18' "value 18 is also CMUX_SHIM_REPLY's"
refuse "optional event the header lists" 'd["optional_events"].append({"kind": "CMUX_SHIM_REPLY", "value": 18})' \
  "CMUX_SHIM_REPLY: the header lists it now"
refuse "optional export bound with r()" 'd["optional_exports"].append(dict(by["cmux_shim_tab_set_frozen"], name="cmux_shim_tab_extra"))' \
  "optional export cmux_shim_tab_extra is not bound"
refuse "rewrite needs" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/CEFCaller.swift: CEFCaller.back(_:)",
  "exports": ["cmux_shim_go_back"], "needs": "later", "change": "x", "task": "p01-process-021"}]' "needs 'later' is not one of"
refuse "rewrite of a missing file" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/Gone.swift: Gone.f()",
  "exports": ["cmux_shim_go_back"], "needs": "reply", "change": "x", "task": "p01-process-021"}]' "Gone.swift does not exist"
refuse "rewrite of a missing function" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/CEFCaller.swift: CEFCaller.gone()",
  "exports": ["cmux_shim_go_back"], "needs": "reply", "change": "x", "task": "p01-process-021"}]' "CEFCaller.gone is no function of"
refuse "rewrite of a function that calls none of its exports" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/CEFCaller.swift: CEFCaller.color(_:)",
  "exports": ["cmux_shim_go_back"], "needs": "reply", "change": "x", "task": "p01-process-021"}]' \
  "CEFCaller.color uses none of cmux_shim_go_back"
edit_ops "$work/refuse" 'd["host_mode_rewrites"][0]["site"] = "CmuxNextBrowser/CEF/CEFCaller.swift: CEFCaller.back(_:)"'
expect 0 "1 host-mode rewrites" "a rewrite of the function that calls its export" -- --root "$work/refuse" --check-ops
refuse "after_attach on a post" 'd["host_mode_rewrites"] = [{"site": "CmuxNextBrowser/CEF/CEFCaller.swift: CEFCaller.back(_:)",
  "exports": ["cmux_shim_go_back"], "needs": "after_attach", "change": "x", "task": "p01-process-015"}]' \
  "needs after_attach is for mirror reads"

# A (*fn) parameter written inline in the header is a function pointer too.
inline="$work/inline"
fixture "$inline"
sed -i.bak 's/CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id);/CMUX_SHIM_EXPORT void cmux_shim_go_back(int browser_id, void (*fn)(void* context), void* context);/' \
  "$inline/$shimh"
edit_ops "$inline" 'by["cmux_shim_go_back"]["args"] += [{"name": "fn", "type": "void (*)(void* context)", "function_pointer": True}, {"name": "context", "type": "void*"}]'
expect 1 "cmux_shim_go_back: function-pointer argument 'fn' in a post export" "inline (\*fn) in a post" -- \
  --root "$inline" --check-ops

# An argument named like a local the generator derives from another argument is refused.
clash="$work/clash"
fixture "$clash"
sed -i.bak 's/const char\* resource_root);/const char* id_value);/' "$clash/$shimh"
edit_ops "$clash" 'by["cmux_shim_page_scheme_add"]["args"][1]["name"] = "id_value"'
expect 1 "argument 'id_value' has the name of a local generated for 'id'" "a derived-name clash" -- \
  --root "$clash" --check-ops

# CEFShimLibrary binds header exports and optional exports only.
unbound="$work/unbound"
fixture "$unbound"
sed -i.bak 's/^    }$/        bogus = try r("cmux_shim_bogus")\n        frozen = try r("cmux_shim_tab_set_frozen")\n    }/' "$unbound/$library"
out="$(python3 "$gen" --root "$unbound" --check-ops 2>&1)" && fail "a stray binding passed: $out"
grep -q 'cmux_shim_bogus is neither a header export nor in optional_exports' <<<"$out" || fail "stray binding: $out"
grep -q 'cmux_shim_tab_set_frozen is an optional export: bind it with r.optional' <<<"$out" ||
  fail "an optional export bound with r(): $out"

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
{"mojoms": [{"file": "render_widget_host_ns_view.mojom", "source": "content/common/render_widget_host_ns_view.mojom",
             "chromium": "154.0.8037.98", "commit": "b859317bf11f6be47f9b7799ec690a0a42a1fb33", "sha256": "$sha"}],
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
# Counts come from the vendored text, never constants.
expect 0 "1 vendored mojoms at Chromium 154\.0\.8037\.98 \(b859317bf11f\): 3 methods, 1 \[Sync\]; 3 mapped \(op 1, event 1, not_needed 1\)" \
  "counts parsed from the mojom" -- --root "$parity" --check-view-parity
expect 0 "render_widget_host_ns_view.mojom RenderWidgetHostNSView: 3 methods, 1 \[Sync\]" "counts by interface" \
  -- --root "$parity" --check-view-parity
cat >"$parity/plans/cmux-next/remote_cocoa_mojom/alert.mojom" <<'EOF'
interface AlertBridge {
  Show(AlertBridgeInitParams params) => (AlertDisposition disposition);
  [Sync, MinVersion=1] Dismiss();
};
EOF
expect 1 "alert.mojom is not listed in" "an unlisted mojom" -- --root "$parity" --check-view-parity
expect 1 "alert.mojom AlertBridge.Dismiss: unmapped" "an unlisted mojom's methods count" -- --root "$parity" --check-view-parity
expect 1 "2 vendored mojoms at Chromium [^:]*: 5 methods, 2 \[Sync\]; 3 mapped" "counts with an unlisted mojom" \
  -- --root "$parity" --check-view-parity
rm "$parity/plans/cmux-next/remote_cocoa_mojom/alert.mojom"
mojom_entry() { # <python statements on e, the first mojoms entry, and d>: rewrite the mojoms list
  python3 - "$parity/plans/cmux-next/chromium-host-view-parity.json" "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
e = d["mojoms"][0]
exec(sys.argv[2])
json.dump(d, open(sys.argv[1], "w"))
EOF
}
mojom_entry 'e["role"] = "the page view"'
expect 0 "" "a mojom's role" -- --root "$parity" --check-view-parity
mojom_entry 'e["rol"] = e.pop("role")'
expect 1 "unknown mojoms field\(s\) rol" "a misspelled mojoms field" -- --root "$parity" --check-view-parity
mojom_entry 'e.pop("rol"); e["commit"] = "b859317bf11f"'
expect 1 "commit must be the 40-hex Chromium commit" "a short commit" -- --root "$parity" --check-view-parity
mojom_entry 'e["commit"] = "b859317bf11f6be47f9b7799ec690a0a42a1fb33"; e["source"] = "content/common/other.mojom"'
expect 1 "is not the Chromium path of this file" "a source of another file" -- --root "$parity" --check-view-parity
mojom_entry 'e["source"] = "content/common/render_widget_host_ns_view.mojom"; e["sha256_"] = e.pop("sha256")'
expect 1 "sha256 must be the file's 64-hex sha256" "a mojom without its sha" -- --root "$parity" --check-view-parity
mojom_entry 'e["sha256"] = e.pop("sha256_"); d["mojoms"].append(dict(e, file="menu.mojom", source="x/menu.mojom", chromium="153.0.1.1"))'
: >"$parity/plans/cmux-next/remote_cocoa_mojom/menu.mojom"
expect 1 "more than one Chromium revision" "mojoms from two revisions" -- --root "$parity" --check-view-parity
rm "$parity/plans/cmux-next/remote_cocoa_mojom/menu.mojom"
mojom_entry 'd["mojoms"] = d["mojoms"][:1]'
mkdir -p "$parity/scripts/cmux-next"
echo '{"chromium": "155.0.1.2"}' >"$parity/scripts/cmux-next/cef-manifest.json"
expect 1 "pins 155.0.1.2: vendor them again" "mojoms the fork pin moved past" -- --root "$parity" --check-view-parity
echo '{"chromium": "154.0.8037.98"}' >"$parity/scripts/cmux-next/cef-manifest.json"
expect 0 "" "mojoms at the fork pin" -- --root "$parity" --check-view-parity
# Each target is checked against what can carry it.
mkdir -p "$parity/Packages/macOS/CmuxNext/ChromiumHost/src" "$parity/plans/cmux-next/chrome-parity"
cat >"$parity/Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_wire.h" <<'EOF'
// Fixture wire. kNotAKind = 9 in a comment is not a Kind.
enum Kind : uint32_t {
  kGeometry = 2,  // v0 width
  kFocus = 6,
};
inline constexpr int kElsewhere = 7;
EOF
echo '{"programs": {"p01-process": {"tasks": [{"id": "p01-process-054"}]}}}' \
  >"$parity/plans/cmux-next/chrome-parity/design-result.json"
show_row() { # <python dict literal for the Show row>: rewrite that row
  python3 - "$parity/plans/cmux-next/chromium-host-view-parity.json" "$1" <<'EOF'
import json, sys
path, row = sys.argv[1], eval(sys.argv[2])
d = json.load(open(path))
d["methods"] = [m for m in d["methods"] if m["method"] != "Show"]
d["methods"].append({"mojom": "render_widget_host_ns_view.mojom", "interface": "RenderWidgetHostNSView",
                     "method": "Show", **row})
json.dump(d, open(path, "w"))
EOF
}
show_row '{"wire": "kFocus"}'
expect 0 "" "a wire Kind" -- --root "$parity" --check-view-parity
show_row '{"wire": "kElsewhere"}'
expect 1 "wire 'kElsewhere' is not a Kind" "a constant outside enum Kind" -- --root "$parity" --check-view-parity
show_row '{"wire": "kNotAKind"}'
expect 1 "wire 'kNotAKind' is not a Kind" "a Kind named only in a comment" -- --root "$parity" --check-view-parity
show_row '{"op": "cmux_shim_no_such_export"}'
expect 1 "op 'cmux_shim_no_such_export' is neither" "an op that is not an export" -- --root "$parity" --check-view-parity
edit_ops "$parity" 'd.setdefault("optional_exports", []).append(dict(by["cmux_shim_go_back"], name="cmux_shim_widget_dismiss"))'
show_row '{"op": "cmux_shim_widget_dismiss"}'
expect 0 "" "an optional export" -- --root "$parity" --check-view-parity
edit_ops "$parity" 'd.setdefault("optional_events", []).append({"kind": "CMUX_SHIM_WIDGET_CONTEXT", "value": 52, "refreshes": []})'
show_row '{"event": "CMUX_SHIM_WIDGET_CONTEXT"}'
expect 0 "" "an optional event" -- --root "$parity" --check-view-parity
# A pending row names who builds the carrier, not a carrier: the method stays unmapped.
show_row '{"pending": "p01-process-054", "note": "TOOLTIP {text}"}'
expect 1 "RenderWidgetHostNSView.Show: unmapped, pending on p01-process-054" "a pending row is unmapped" \
  -- --root "$parity" --check-view-parity
expect 0 "RenderWidgetHostNSView.Show" "list-unmapped lists a pending row" -- --root "$parity" --list-unmapped
expect 0 $'RenderWidgetHostNSView.Show\tp01-process-054' "list-pending" -- --root "$parity" --list-pending
python3 "$gen" --root "$parity" --list-pending 2>/dev/null | grep -q SyncIsKeyWindow &&
  fail "--list-pending lists a mapped row"
show_row '{"pending": "p01-process-054"}'
expect 1 "a pending row needs a note" "a pending row without its carrier" -- --root "$parity" --check-view-parity
show_row '{"pending": "p01-process-999", "note": "x"}'
expect 1 "pending task p01-process-999 is not in" "a pending task the design lacks" -- --root "$parity" --check-view-parity
show_row '{"pending": "later", "note": "x"}'
expect 1 "pending 'later' is not a task id" "a pending value that is no task id" -- --root "$parity" --check-view-parity
show_row '{"not_needed": " "}'
expect 1 "not_needed must be a non-empty string" "a blank reason" -- --root "$parity" --check-view-parity
show_row '{"wire": "kFocus", "evnt": "CMUX_SHIM_ADDRESS"}'
expect 1 "unknown field\\(s\\) evnt" "a misspelled field" -- --root "$parity" --check-view-parity
show_row '{"wire": "kFocus", "event": "CMUX_SHIM_ADDRESS"}'
expect 1 "needs exactly one of" "two targets" -- --root "$parity" --check-view-parity
# A row names a method of the vendored mojom (Chromium 154 has PinchEvent, not GestureBegin).
show_row '{"wire": "kFocus"}'
stale_row() { # add|drop: the RenderWidgetHostNSViewHost.GestureBegin row
  python3 - "$parity/plans/cmux-next/chromium-host-view-parity.json" "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["methods"] = [m for m in d["methods"] if m["method"] != "GestureBegin"]
if sys.argv[2] == "add":
    d["methods"].append({"mojom": "render_widget_host_ns_view.mojom", "interface": "RenderWidgetHostNSViewHost",
                         "method": "GestureBegin", "wire": "kFocus"})
json.dump(d, open(sys.argv[1], "w"))
EOF
}
stale_row add
expect 1 "RenderWidgetHostNSViewHost.GestureBegin: mapped, but the mojom has no such method" "a row for a method the mojom lacks" \
  -- --root "$parity" --check-view-parity
stale_row drop
expect 0 "" "the stale row gone" -- --root "$parity" --check-view-parity
rm "$parity/Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_wire.h"
show_row '{"wire": "kFocus"}'
expect 1 "chromium_host_wire.h is missing" "a wire row without the wire header" -- --root "$parity" --check-view-parity
show_row '{"event": "CMUX_SHIM_ADDRESS"}'
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
  if [[ -n "$cxx" ]]; then
    compile_inc "$scratch" "the real header"
  fi
  # A record field named *browser_id carries cmux's id: the host maps it as it maps a browser argument.
  policy="$(case_of "$scratch/${outputs[0]}" kOpSetWindowRequestPolicy)"
  grep -qF 'arg_windows[i].anchor_browser_id = ctx.Browser(static_cast<int32_t>(r.I64()));' <<<"$policy" ||
    fail "a record's browser id reaches the host shim unmapped"
  grep -qF 'arg_clicks[i].browser_id = ctx.Browser(static_cast<int32_t>(r.I64()));' <<<"$policy" ||
    fail "a click record's browser id reaches the host shim unmapped"
  grep -qF 'arg_windows[i].flags = r.I64();' <<<"$policy" || fail "a plain record field is mapped as a browser id"
  expect 0 "0 mirror reads before attach" "the real startup path" -- --root "$repo" --check-pre-attach
  # Every vendored remote_cocoa mojom method is mapped, except pending rows,
  # which the check counts unmapped until their task names the carrier: no other problem, and the
  # unmapped list is exactly the pending list. The counts are parsed from the vendored files.
  real_parity_code=0
  real_parity="$(python3 "$gen" --root "$repo" --check-view-parity 2>&1 >/dev/null)" || real_parity_code=$?
  other="$(grep -vE ': unmapped, pending on p[0-9]{2}-[a-z0-9-]+$' <<<"$real_parity" || true)"
  [[ -z "$other" ]] || fail "the real view parity has problems besides pending rows:"$'\n'"$other"
  real_unmapped="$(python3 "$gen" --root "$repo" --list-unmapped 2>/dev/null | sort)"
  real_pending="$(python3 "$gen" --root "$repo" --list-pending 2>/dev/null | cut -f1 | sort)"
  [[ "$real_unmapped" == "$real_pending" ]] ||
    fail "the real view parity's unmapped methods are not its pending rows:"$'\n'"$real_unmapped"
  want_code=0
  [[ -n "$real_pending" ]] && want_code=1
  [[ "$real_parity_code" == "$want_code" ]] ||
    fail "the real view parity exits $real_parity_code, expected $want_code (pending: ${real_pending:-none})"
  vendored="$(find "$repo/plans/cmux-next/remote_cocoa_mojom" -name '*.mojom' | grep -c .)"
  real_counts="$(python3 "$gen" --root "$repo" --check-view-parity 2>/dev/null || true)"
  grep -qE "^view parity: $vendored vendored mojoms at Chromium [^ ]+ \([0-9a-f]{12}\): [0-9]+ methods, [0-9]+ \[Sync\]" <<<"$real_counts" ||
    fail "the real view parity does not print the counts of its $vendored vendored mojoms"
else
  echo "note: $ops is not in this checkout (task p01-process-010); real-header ops check skipped" >&2
fi

echo "gen-chromium-host-wire tests: ok"
