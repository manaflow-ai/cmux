# shellcheck shell=bash
# The Chromium host wire's C++ codec, built from cmux-tui/spec/chromium-host-wire.json
# (task p05-ipc-181). ChromiumHost/src/chromium_host_wire.h includes
# chromium_host_wire.generated.h, which is never in git: every script that compiles a file
# including it sources this, calls host_wire_headers, and adds -I<dir> to that compile.
#
#   host_wire_headers <repository root> <dir>
#     Writes chromium_host_wire.generated.h and chromium_host_wire_golden.generated.h into
#     <dir> (made when missing) with cmux-tui/bindings/codegen/host_wire_cpp.py. Fails
#     with the schema's problem when the schema is not one the codec can be built from.
#     PYTHON picks the interpreter (python3 by default; the macOS system 3.9 is enough).
host_wire_headers() {
  local repo="${1:?host_wire_headers: repository root}" dir="${2:?host_wire_headers: output directory}"
  "${PYTHON:-python3}" -I "$repo/cmux-tui/bindings/codegen/host_wire_cpp.py" \
    --schema "$repo/cmux-tui/spec/chromium-host-wire.json" --output-dir "$dir"
}
