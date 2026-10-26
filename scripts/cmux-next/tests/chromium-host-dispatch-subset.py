#!/usr/bin/env python3
"""Writes a subset of the Chromium Host's generated host_dispatch.inc for the host's C++ tests.

gen-chromium-host-wire.py renders the real file from cmux_cef_shim.h and
plans/cmux-next/chromium-host-ops.json; this keeps only the ops below, with their real ids, real
case bodies and real kMirrorRefreshes rows, so host_dispatch_test.cpp and host_mirror_test.cpp
check the dispatcher and the mirror producers against the current ops JSON with a fake shim that
defines only the exports these ops call. Used by chromium-host-dispatch.test.sh:

  chromium-host-dispatch-subset.py OUT_FILE
"""
from __future__ import annotations

import importlib.util
import sys
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# Every op host_dispatch.mm and host_mirror.mm name, and the ops the tests send.
OPS = [
    "cmux_shim_set_new_tab_page_url", "cmux_shim_initialize", "cmux_shim_create_window", "cmux_shim_tab_add",
    "cmux_shim_tab_duplicate", "cmux_shim_load_url", "cmux_shim_set_focus", "cmux_shim_devtools_call",
    "cmux_shim_shutdown", "cmux_shim_set_focus_request_handler", "cmux_shim_set_window_request_handler",
    "cmux_shim_set_unhandled_key_handler", "cmux_shim_devtools_set_key_handler",
    # Mirrors: host_mirror.mm's producers, one watched mirror, the attach capability.
    "cmux_shim_fork_api_version", "cmux_shim_tab_navigation_entries", "cmux_shim_tab_window_id",
    "cmux_shim_tab_navigation_state", "cmux_shim_navigation_restore_supported", "cmux_shim_foreign_browser_count",
    "cmux_shim_live_browser_count", "cmux_shim_window_count", "cmux_shim_side_panel_state",
    "cmux_shim_ext_actions", "cmux_shim_ext_list", "cmux_shim_ext_commands", "cmux_shim_omnibox_keywords",
    "cmux_shim_popup_window_bounds",
]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    spec = importlib.util.spec_from_file_location("gen_wire", ROOT / "scripts/cmux-next/gen-chromium-host-wire.py")
    gen = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gen  # dataclasses look their module up by name
    spec.loader.exec_module(gen)
    header = gen.parse_header(ROOT / gen.SHIMH)
    model, problems, _ = gen.load_ops(header, ROOT)
    if model is None or problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    missing = [name for name in OPS if name not in model.ops]
    if missing:
        print(f"not in the ops JSON: {', '.join(missing)}", file=sys.stderr)
        return 1
    keep = set(OPS)
    subset = replace(model,
                     exports=[e for e in model.exports if e.name in keep],
                     ops={name: op for name, op in model.ops.items() if name in keep})
    Path(argv[1]).write_text(gen.render_host(subset), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
