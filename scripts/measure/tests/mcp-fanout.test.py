#!/usr/bin/env python3
"""scripts/measure/mcp-fanout.py: which kind each process counts as. No fleet, no app.
Run: python3 -I scripts/measure/tests/mcp-fanout.test.py"""
import importlib.util, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("mcp_fanout", os.path.join(HERE, "..", "mcp-fanout.py"))
fanout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fanout)


class KindOf(unittest.TestCase):
    def test_acpmux_s_own_servers_count_as_tool_servers_under_acp_too(self):
        # The folded own-tools process runs as `acpmux acp tools-mcp`: before, it read as acpmux-acp.
        kind = fanout.kind_of("/app/bin/acpmux acp tools-mcp")
        self.assertEqual(kind, "acpmux-tools-mcp")
        self.assertIn(kind, fanout.TOOL_KINDS)
        self.assertEqual(fanout.kind_of("acpmux forum-mcp --session s"), "acpmux-forum-mcp")

    def test_other_acpmux_processes_keep_their_kind(self):
        self.assertEqual(fanout.kind_of("acpmux daemon"), "acpmux-daemon")
        self.assertEqual(fanout.kind_of("acpmux acp --agent claude"), "acpmux-acp")
        # A flag or a path that ends in -mcp is no server name.
        self.assertEqual(fanout.kind_of("acpmux acp --cwd /w/x-mcp"), "acpmux-acp")
        self.assertEqual(fanout.kind_of("acpmux acp --no-mcp"), "acpmux-acp")
        self.assertNotIn("acpmux-acp", fanout.TOOL_KINDS)


if __name__ == "__main__":
    unittest.main()
