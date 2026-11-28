"""check-bridge-on-main.py: a sync Rust bridge call in row code, and the whole settings file over the bridge.

The fixture is cmux#59531's shape (Leo, 2026-11-27: "can u guys take this thread:
https://manaflow-workspace.slack.com/archives/C0CG8V89NER/p1795759419492319"): `ChiefMascotPicks.picked` sent
`settings.fileRoot` to a `welcome.*` op, reached per row from the sidebar's `chiefAvatar:` closure. Both rules are
red on it and green on cmux#60927's fix (one key sent; the row reads a cache).
Run: python3 -I tests/test_check_bridge_on_main.py
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("check_bridge_on_main", ROOT / "scripts/cmux-next/check-bridge-on-main.py")
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

RULE = """nonisolated func welcomeRule<In: Encodable, Out: Decodable>(_ op: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
    do { return try HomeRules.call(op, input) } catch { return fallback() }
}
"""

PICKS_BEFORE = """public final class ChiefMascotPicks {
    public func picked(_ chief: String?, in file: JSONValue?) -> String? {
        let input = PicksInput(chief: chief, picks: picks, file: file)
        let reply: PickedReply = welcomeRule("welcome.mascotPicked", input, fallback: PickedReply(picked: nil))
        return reply.picked
    }
}
"""

PICKS_AFTER = """public final class ChiefMascotPicks {
    public func picked(_ chief: String?, in file: JSONValue?) -> String? {
        let input = PicksInput(chief: chief, picks: picks, file: isDefault(chief) ? file.map(Self.mascotKey) : nil)
        let reply: PickedReply = welcomeRule("welcome.mascotPicked", input, fallback: PickedReply(picked: nil))
        return reply.picked
    }
}
"""

SERVICES = """final class AppServices {
    func chosenPicture(of chief: String?) -> URL? {
        chiefMascotPicks.picked(chief, in: settings?.fileRoot).flatMap { avatarURL(of: $0) }
    }
    var chiefFaces: [String: URL] {
        var out: [String: URL] = [:]
        for chief in chiefs { out[chief] = chosenPicture(of: chief) }
        return out
    }
}
"""

SIDEBAR_BEFORE = """final class SidebarBridge {
    func observe() {
        let rows = feed.laneRowSource(chiefAvatar: { [weak services] in SidebarChiefAvatar(home: services?.chiefFaces[$0]) })
    }
}
"""

SIDEBAR_AFTER = """final class SidebarBridge {
    func observe() {
        let rows = feed.laneRowSource(chiefAvatar: { [weak services] in SidebarChiefAvatar(home: services?.faceCache[$0]) })
    }
}
"""

VIEW = """struct ChiefRow: View {
    var body: some View {
        Text(HomeRules.callName(chief))
    }
}
struct ChiefList: View {
    let names: [String]
    var body: some View {
        ForEach(names, id: \\.self) { name in
            Text(welcomeRule("welcome.title", name, fallback: name))
        }
    }
}
struct Reviewed: View {
    var body: some View {
        // bridge-ok: one call per settings open, not per row
        Text(welcomeRule("welcome.once", 1, fallback: ""))
    }
}
"""


def run(files: dict[str, str]) -> dict[str, dict[str, list]]:
    with tempfile.TemporaryDirectory() as folder:
        sources = Path(folder) / check.PACKAGE / "Sources" / "App"
        sources.mkdir(parents=True)
        for name, text in files.items():
            (sources / name).write_text(text, encoding="utf-8")
        return {Path(f).name: rules for f, rules in check.collect(folder).items()}


class BridgeOnMainTests(unittest.TestCase):
    def test_59531_shape_is_red_on_both_rules(self):
        found = run({"WelcomeRule.swift": RULE, "ChiefMascotPicks.swift": PICKS_BEFORE,
                     "AppServices.swift": SERVICES, "SidebarBridge.swift": SIDEBAR_BEFORE})
        self.assertIn(check.FILE_RULE, found["AppServices.swift"])
        row = found["SidebarBridge.swift"][check.ROW_RULE]
        self.assertEqual(len(row), 1)
        self.assertIn("chiefAvatar: closure: chiefFaces -> chosenPicture -> picked -> Rust bridge", row[0][1])

    def test_60927_shape_is_green(self):
        found = run({"WelcomeRule.swift": RULE, "ChiefMascotPicks.swift": PICKS_AFTER,
                     "AppServices.swift": SERVICES, "SidebarBridge.swift": SIDEBAR_AFTER})
        self.assertNotIn("SidebarBridge.swift", found)
        self.assertNotIn(check.FILE_RULE, found.get("AppServices.swift", {}))

    def test_body_and_for_each_and_allow(self):
        found = run({"WelcomeRule.swift": RULE, "Views.swift": VIEW})
        lines = [line for line, _ in found["Views.swift"][check.ROW_RULE]]
        self.assertEqual(lines, [10])  # ForEach's welcomeRule; `HomeRules.callName` is not a bridge call; bridge-ok skips

    def test_subscripted_file_root_is_not_the_whole_file(self):
        services = SERVICES.replace("settings?.fileRoot)", 'settings?.fileRoot["home"])')
        found = run({"WelcomeRule.swift": RULE, "ChiefMascotPicks.swift": PICKS_BEFORE, "AppServices.swift": services})
        self.assertNotIn(check.FILE_RULE, found.get("AppServices.swift", {}))

    def test_mask_keeps_length_and_lines(self):
        text = 'let a = "x(y" // c (\n/* {\n */ f("""\nq{\n""") #"r"#'
        masked = check.mask_code(text)
        self.assertEqual(len(masked), len(text))
        self.assertEqual(masked.count("\n"), text.count("\n"))
        self.assertNotIn("{", masked)

    def test_payload_ffi_from_headers_is_a_seed(self):
        """A `cmux_*` export that takes bytes or a C string, called straight from a row, is a sync bridge call;
        a scalar export (`cmux_motion_ease`) and the `_free` helper are not."""
        import subprocess
        header = """/* a doc comment naming cmux_not_a_decl(const char *x); */
int32_t cmux_layout_reducer_json(
    const uint8_t *request,
    size_t request_len,
    CmuxBytes *out);
double cmux_motion_ease(uint8_t curve, double t);
void cmux_layout_bytes_free(char *bytes);
"""
        row = """final class Feed {
    func flushRows() {
        _ = cmux_layout_reducer_json(ptr, len, &out)
        _ = cmux_motion_ease(1, 0.5)
    }
}
"""
        with tempfile.TemporaryDirectory() as folder:
            include = Path(folder) / "cmux-tui/crates/cmux-layout-reducer/include"
            include.mkdir(parents=True)
            (include / "cmux_layout_reducer.h").write_text(header, encoding="utf-8")
            sources = Path(folder) / check.PACKAGE / "Sources" / "App"
            sources.mkdir(parents=True)
            (sources / "Feed.swift").write_text(row, encoding="utf-8")
            subprocess.run(["git", "-C", folder, "init", "-q"], check=True)
            subprocess.run(["git", "-C", folder, "add", "-A"], check=True)
            self.assertEqual(check.payload_ffi(folder), ["cmux_layout_reducer_json"])
            hits = {Path(f).name: rules for f, rules in check.collect(folder).items()}
        lines = hits["Feed.swift"][check.ROW_RULE]
        self.assertEqual(len(lines), 1)
        self.assertIn("cmux_layout_reducer_json", lines[0][1])


if __name__ == "__main__":
    unittest.main()
