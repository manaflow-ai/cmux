#!/usr/bin/env python3
"""scripts/measure/mcp-fanout.py: which kind each process counts as. No fleet, no app.
Run: python3 -I scripts/measure/tests/mcp-fanout.test.py"""
import importlib.util, os, tempfile, unittest

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

    def test_an_executable_under_a_folder_with_a_space_keeps_its_kind(self):
        # The app's binaries run from `~/Library/Application Support/...`: before, each read as other:Application.
        with tempfile.TemporaryDirectory() as root:
            bin_dir = os.path.join(root, "Application Support", "cmux", "bin")
            os.makedirs(bin_dir)
            for name in ("cmux", "acpmux", "server.js"):
                with open(os.path.join(bin_dir, name), "w"):
                    pass
            self.assertEqual(fanout.kind_of(f"{bin_dir}/cmux mcp serve --all-tools"), "cmux-mcp-serve")
            self.assertEqual(fanout.kind_of(f"{bin_dir}/acpmux acp tools-mcp"), "acpmux-tools-mcp")
            self.assertEqual(fanout.kind_of(f"{bin_dir}/acpmux daemon"), "acpmux-daemon")
            # A script `node` runs from such a folder is named by its own file, not the folder word.
            self.assertEqual(fanout.kind_of(f"/usr/bin/node {bin_dir}/server.js --stdio"), "node:server.js")
            # A path that names no file (the process's binary gone) splits as before.
            self.assertEqual(fanout.split_exe(f"{root}/gone dir/cmux mcp serve"),
                             [f"{root}/gone", "dir/cmux", "mcp", "serve"])

    def test_other_acpmux_processes_keep_their_kind(self):
        self.assertEqual(fanout.kind_of("acpmux daemon"), "acpmux-daemon")
        self.assertEqual(fanout.kind_of("acpmux acp --agent claude"), "acpmux-acp")
        # A flag or a path that ends in -mcp is no server name.
        self.assertEqual(fanout.kind_of("acpmux acp --cwd /w/x-mcp"), "acpmux-acp")
        self.assertEqual(fanout.kind_of("acpmux acp --no-mcp"), "acpmux-acp")
        self.assertNotIn("acpmux-acp", fanout.TOOL_KINDS)


if __name__ == "__main__":
    unittest.main()
