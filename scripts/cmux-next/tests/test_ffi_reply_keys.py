"""ffi_reply_keys.py: a Swift reply type may not require a key the pinned Rust FFI never writes (cmux#46136)."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/ffi_reply_keys.py"
spec = importlib.util.spec_from_file_location("ffi_reply_keys", SCRIPT)
keys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keys)

PLANNER = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Logic/SidebarCustomizationPlanner.swift"
RUST = "cmux-tui/crates/cmux-layout-reducer/src/sidebar_section_customization.rs"

# The planner reply before and after cmux#46136, trimmed.
BEFORE = '''struct SidebarCustomizationPlanner {
    private struct Reply: Decodable {
        var sectionOrder: [String]
        var hiddenWorkspaces: [String]

        enum CodingKeys: String, CodingKey {
            case sectionOrder = "section_order"
            case hiddenWorkspaces = "hidden_workspaces"
        }
    }

    static func apply() -> Reply? {
        RustSidebarClient.call("sidebar_section_customization", request, as: Reply.self)
    }
}
'''
REQUIRED = BEFORE.replace("var hiddenWorkspaces: [String]\n",
                          "var hiddenWorkspaces: [String]\n        var selectionSpared: Bool\n").replace(
    'case hiddenWorkspaces = "hidden_workspaces"\n',
    'case hiddenWorkspaces = "hidden_workspaces"\n            case selectionSpared = "selection_spared"\n')
OPTIONAL = REQUIRED.replace("var selectionSpared: Bool", "var selectionSpared: Bool?")
RUST_BEFORE = "pub struct Reply {\n    pub section_order: Vec<String>,\n    pub hidden_workspaces: Vec<String>,\n}\n"
RUST_AFTER = RUST_BEFORE.replace("}\n", "    pub selection_spared: bool,\n}\n")


class Repo:
    def __init__(self, tmp):
        self.path = tmp
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")

    def git(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["git", "-C", self.path, *args], check=True, capture_output=True, text=True,
                              env=env).stdout.strip()

    def commit(self, files):
        for rel, text in files.items():
            target = Path(self.path) / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "c")
        return self.git("rev-parse", "HEAD")


def pin(sha):
    return (f'{{"url": "https://example.invalid/releases/download/cmux-app-ffi-{sha}/CCmuxAppFFI.xcframework.zip", '
            f'"checksum": "{"0" * 64}"}}\n')


def judge(repo, base, head):
    out = subprocess.run(["python3", "-I", str(SCRIPT), "--repo", repo.path, "--base", base, "--head", head],
                         capture_output=True, text=True)
    return out.returncode, out.stdout


class ReplyKeys(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(self.tmp.name)
        # The pinned release is built from this commit: Rust before selection_spared.
        self.pinned = self.repo.commit({RUST: RUST_BEFORE, PLANNER: BEFORE, keys.PIN_FILE: "{}\n"})
        self.base = self.repo.commit({keys.PIN_FILE: pin(self.pinned)})

    def tearDown(self):
        self.tmp.cleanup()

    def test_46136_rust_and_swift_together_is_refused(self):
        head = self.repo.commit({RUST: RUST_AFTER, PLANNER: REQUIRED})
        code, out = judge(self.repo, self.base, head)
        self.assertEqual(code, 1, out)
        self.assertIn("Reply requires `selection_spared` in the Rust `sidebar_section_customization` reply", out)
        self.assertIn(self.pinned[:12], out)

    def test_an_optional_key_passes(self):  # cmux#47028's shape
        head = self.repo.commit({RUST: RUST_AFTER, PLANNER: OPTIONAL})
        self.assertEqual(judge(self.repo, self.base, head), (0, ""))

    def test_the_key_required_after_the_repin_passes(self):
        rust = self.repo.commit({RUST: RUST_AFTER})
        repinned = self.repo.commit({keys.PIN_FILE: pin(rust)})
        head = self.repo.commit({PLANNER: REQUIRED})
        self.assertEqual(judge(self.repo, repinned, head), (0, ""))

    def test_a_key_the_base_already_lacked_is_not_the_changes(self):
        skewed = self.repo.commit({PLANNER: REQUIRED})
        head = self.repo.commit({PLANNER: REQUIRED.replace("static func apply", "static func applied")})
        self.assertEqual(judge(self.repo, skewed, head), (0, ""))

    def test_a_pinned_commit_this_clone_lacks_is_a_note_not_a_refusal(self):
        head = self.repo.commit({PLANNER: REQUIRED, keys.PIN_FILE: pin("f" * 40)})
        code, out = judge(self.repo, self.base, head)
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("note: ffi reply keys not judged: the pinned FFI source commit"), out)

    def test_the_pre_push_gate_refuses_it(self):
        gate_spec = importlib.util.spec_from_file_location("prepush_gate", ROOT / "scripts/cmux-next/prepush-gate.py")
        gate = importlib.util.module_from_spec(gate_spec)
        gate_spec.loader.exec_module(gate)
        script = {gate.FFI_REPLY_SCRIPT: SCRIPT.read_text()}
        base = self.repo.commit(script)
        head = self.repo.commit({RUST: RUST_AFTER, PLANNER: REQUIRED})
        found = dict(gate.gate(Path(self.repo.path), base, head, {"ffi-reply-keys"}, False))
        self.assertIn(gate.FFI_REPLY_CHECK, found)
        self.assertIn("selection_spared", found[gate.FFI_REPLY_CHECK][0])
        head = self.repo.commit({PLANNER: OPTIONAL})
        self.assertEqual(dict(gate.gate(Path(self.repo.path), base, head, {"ffi-reply-keys"}, False)), {})

    def test_required_keys_reads_swift_decoding(self):
        text = '''
struct Outer: Decodable {
    var rows: [Row]
    var camelKey: Int
    var maybe: String?
    var defaulted: Bool = false
    let fixed = 3
    static var shared: Int = 0
    var computed: Int { 1 }
}
struct Row: Codable { var id: String }
struct Custom: Decodable {
    var a: Int
    init(from decoder: any Decoder) throws { a = 0 }
}
func f() { _ = Client.call("an_op", x, as: Outer.self); _ = Client.call("other", x, as: Custom.self) }
'''
        self.assertEqual(keys.file_keys(text), {("an_op", "Outer", "rows"), ("an_op", "Row", "id"),
                                                ("an_op", "Outer", "camelKey"), ("an_op", "Outer", "defaulted")})
        self.assertEqual(keys.snake("camelKey"), "camel_key")


if __name__ == "__main__":
    unittest.main()
