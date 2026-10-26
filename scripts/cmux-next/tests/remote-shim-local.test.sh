#!/usr/bin/env bash
# The remote shim's local class (task p01-process-014b), with no build:
#  1. every cmux_shim_* export with a function-pointer parameter is class local
#     or policy in plans/cmux-next/chromium-host-ops.json, with a reason; each
#     local one is defined by hand in ChromiumHost/client (outside generated/)
#     and the generated client defines none of them (no marshaller);
#  2. client/remote_shim_local.mm against a fake transport
#     (ChromiumHost/tests/remote_shim_local_test.cpp): one clang++ call.
# No CI job runs it (lead, 2026-10-23: no new CI tests); whoever changes the
# local class or a callback export runs it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shim_include="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"

python3 -I - "$root" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
header = (root / "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h").read_text()
ops = json.loads((root / "plans/cmux-next/chromium-host-ops.json").read_text())
client = root / "Packages/macOS/CmuxNext/ChromiumHost/client"

def strip(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

code = strip(header)
fn_types = set(re.findall(r"typedef\s+[^;()]*\(\s*\*\s*(\w+)\s*\)", code))
callback_exports = []
for m in re.finditer(r"CMUX_SHIM_EXPORT\s+[^;{]*?\b(cmux_shim_\w+)\s*\(", code):
    depth, i = 1, m.end()
    while depth:
        depth += {"(": 1, ")": -1}.get(code[i], 0)
        i += 1
    params = code[m.end():i - 1]
    if "(*" in params.replace(" ", "") or any(re.search(rf"\b{t}\b", params) for t in fn_types):
        callback_exports.append(m.group(1))

entries = {e["name"]: e for e in ops["exports"] + ops.get("optional_exports", [])}
problems = []
if len(callback_exports) < 9:  # 9 in the header today: the parser lost some
    problems.append(f"only {len(callback_exports)} callback exports parsed from the header")
local = []
for name in callback_exports:
    e = entries.get(name)
    if e is None:
        problems.append(f"{name}: not in the ops JSON")
        continue
    if e["class"] not in ("local", "policy"):
        problems.append(f"{name}: class {e['class']} (a function pointer is local or policy)")
    if not e.get("reason", "").strip():
        problems.append(f"{name}: no reason")
    if not any(a.get("function_pointer") for a in e.get("args", [])):
        problems.append(f"{name}: no arg marked function_pointer")
    if e["class"] == "local":
        local.append(name)

def defines(text, name):
    return re.search(rf"\b{name}\s*\([^;{{]*\)\s*\{{", text, flags=re.S) is not None

hand = "\n".join(strip(p.read_text()) for p in sorted(client.glob("*")) if p.suffix in (".mm", ".cc", ".cpp", ".h"))
generated = client / "generated/remote_shim.inc"
gen = strip(generated.read_text()) if generated.exists() else ""
for name in local:
    if not defines(hand, name):
        problems.append(f"{name}: local but not defined in {client.relative_to(root)}")
    if defines(gen, name):
        problems.append(f"{name}: local but the generated client marshals it")
for p in problems:
    print("FAIL", p, file=sys.stderr)
if problems:
    sys.exit(1)
print(f"callback exports: {len(callback_exports)} ({len(local)} local, "
      f"{len(callback_exports) - len(local)} policy), all hand-written or policy")
PY

work="$(mktemp -d "${TMPDIR:-/tmp}/remote-shim-local.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -I"$shim_include" \
  -o "$work/test" "$host/tests/remote_shim_local_test.cpp" -x c++ "$host/client/remote_shim_local.mm"
"$work/test"
