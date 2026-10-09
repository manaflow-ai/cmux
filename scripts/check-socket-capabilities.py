#!/usr/bin/env python3
"""Check socket dispatcher cases against v2 capability discovery.

The dispatcher contains a few deliberately private test, debug, and host
bridges. They are listed explicitly below; every other dispatcher method must
be discoverable so a new public socket method cannot silently bypass the
capability catalog.
"""

import argparse
import pathlib
import re
import sys

# These methods are internal host/debug/test surfaces, not public socket API.
# Keep the list exact: a new dispatcher method outside this set must be added to
# v2Capabilities() or this guard fails.
INTENTIONALLY_UNADVERTISED_METHODS = frozenset("""
agent.hook.barrier
agent.hook.enqueue
chat.sessions.dump
debug.app.activate
debug.bonsplit_underflow.count
debug.bonsplit_underflow.reset
debug.browser.address_bar_focused
debug.browser.favicon
debug.canvas.command_scroll_hint
debug.cloudtree.gallery
debug.cloudtree.rows
debug.cloudtree.spacing
debug.command_palette.rename_input.delete_backward
debug.command_palette.rename_input.interact
debug.command_palette.rename_input.select_all
debug.command_palette.rename_input.selection
debug.command_palette.rename_tab.open
debug.command_palette.results
debug.command_palette.selection
debug.command_palette.toggle
debug.command_palette.visible
debug.empty_panel.count
debug.empty_panel.reset
debug.flash.count
debug.flash.reset
debug.global_search.query
debug.layout
debug.mobile.transport.disconnect
debug.mobile.transport.reconnect_loop
debug.notification.emit
debug.notification.focus
debug.notification.mode
debug.notification.status
debug.panel_snapshot
debug.panel_snapshot.reset
debug.portal.stats
debug.pro_welcome_checklist.show
debug.native_pricing.show
debug.right_sidebar.focus
debug.session_snapshot_benchmark
debug.session_snapshot_seed_scrollback
debug.shortcut.set
debug.shortcut.simulate
debug.sidebar.simulate_drag
debug.sidebar.visible
debug.terminal.is_focused
debug.terminal.read_text
debug.terminal.render_stats
debug.terminal.simulate_file_drop
debug.textbox.inline_fixture
debug.textbox.interact
debug.type
debug.window.screenshot
debug.workspace_todo.checklist_add_field
dogfood.feedback.submit
feed.text
mobile.dev_stack_auth.configure
mobile.directory.list
mobile.directory.search
mobile.rpc.methods
mobile.status.set
mobile.surface.focus
mobile.sync.fetch
mobile.terminal.close
mobile.terminal.participant.disconnect
mobile.terminal.reattach
mobile.terminal.rename
mobile.terminal.size_policy.set
mobile.workspace.changes.summary
notification.reconcile
phone_push.settings.update
phone_push.status.get
phone_push.test
project.get_state
project.open
project.set_configuration
project.set_scheme
project.set_selected_file
project.set_selected_target
project.set_settings_filter
project.set_tab
remote.tmux.root_frames
remote.tmux.sizing_settled
remote.tmux.test_exec
remote.tmux.test_perturb_divider
remote.tmux.test_set_frame
sidebar.custom.reload
sidebar.custom.select
sidebar.custom.validate
""".split())


def switch_cases(source):
    methods = set()
    for match in re.finditer(r"switch\s+(?:request\.)?method\b", source):
        opening = source.find("{", match.end())
        if opening < 0:
            continue
        depth = 0
        closing = None
        for index in range(opening, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    closing = index
                    break
        if closing is None:
            continue
        switch_body = source[opening:closing]
        for case in re.finditer(
            r'case\s+((?:"[A-Za-z0-9_.-]+"\s*,?\s*)+)',
            switch_body,
            flags=re.MULTILINE,
        ):
            methods.update(re.findall(r'"([A-Za-z0-9_.-]+)"', case.group(1)))
    return methods


def capability_methods(source, simulator_source=""):
    anchor = source.find("var methods: [String] = [")
    if anchor < 0:
        raise ValueError("v2 capability method list is missing")
    closing = source.find("\n        ]", anchor)
    if closing < 0:
        raise ValueError("v2 capability method list is unclosed")
    methods = set(re.findall(r'"([A-Za-z0-9_.-]+)"', source[anchor:closing]))
    # A small number of capabilities are appended conditionally after the
    # base list. Keep those additions in the parity check too, otherwise the
    # guard would report a false gap for methods that discovery really emits.
    for appended in re.findall(r'for method in \[([^\]]+)\]', source, flags=re.DOTALL):
        methods.update(re.findall(r'"([A-Za-z0-9_.-]+)"', appended))
    methods.update(re.findall(r'"([A-Za-z0-9_.-]+)"', simulator_source))
    return methods


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    capability_path = root / "Sources/TerminalController+Capabilities.swift"
    capability_text = capability_path.read_text(encoding="utf-8")
    simulator_path = root / (
        "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/"
        "ControlCommandExecutionPolicy+Simulator.swift"
    )
    simulator_text = simulator_path.read_text(encoding="utf-8") if simulator_path.exists() else ""
    advertised = capability_methods(capability_text, simulator_text)

    dispatched = set()
    for relative in (
        "Sources/TerminalController.swift",
        "Sources/Cloud",
        "Sources/Surfaces",
        "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator",
    ):
        path = root / relative
        paths = [path] if path.is_file() else sorted(path.rglob("*.swift"))
        for source_path in paths:
            dispatched.update(switch_cases(source_path.read_text(encoding="utf-8")))

    public = dispatched - INTENTIONALLY_UNADVERTISED_METHODS
    if not public:
        print("socket capability parity: no public dispatcher methods found", file=sys.stderr)
        return 1
    missing = sorted(public - advertised)
    if missing:
        print("Missing advertised capabilities:", file=sys.stderr)
        for method in missing:
            print("  - " + method, file=sys.stderr)
        return 1
    print("socket capability parity: ok ({0} public dispatcher methods)".format(len(public)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
