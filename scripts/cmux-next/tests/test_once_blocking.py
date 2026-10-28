#!/usr/bin/env python3
"""guardrails.py's once-blocking rule (p02-threads-122) and its threading-inventory.py queue (MQ-22).

A blocking call (raw, seam or raw-blocking-ext) in a static, lazy or global initializer is refused: Swift runs it
once, on whichever thread reads the value first, while every other first reader waits (Chromium keeps blocking work
out of lazy singletons: base/memory/singleton.h, base/lazy_instance.h). The fixtures pin what is refused (an
immediately called `static let` closure, a `lazy var` closure, a file-scope `let`, a direct initializer, an inline
`flatMap {` inside one, a seam and a raw-blocking-ext call inside one, the Security calls of the 13 sites the audit
found) and what is not (a literal, a stored static closure that is not called, a computed static property, an
instance member's closure, a local closure in a function, a function body, an escaped line). The inventory test runs
threading-inventory.py on 772cdfc45ac (the audit's 11 files plus the two own-team readers) when the clone has it.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the rule:
  python3 -m pytest scripts/cmux-next/tests/test_once_blocking.py
  python3 -I scripts/cmux-next/tests/test_once_blocking.py
"""
from __future__ import annotations

import collections
import importlib.util
import subprocess
import sys
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # loading the tool below must not write __pycache__ beside it

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parents[1]
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_p02_122", SCRIPTS / "guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

SRC = "Packages/macOS/CmuxNext/Sources/"
UI = SRC + "CmuxNextUIKit"        # uiSwiftSettings: main-actor by default
SERVICE = SRC + "CmuxNextService"  # daemonSwiftSettings: nonisolated by default
MANIFEST = """// swift-tools-version: 6.2
let package = Package(name: "CmuxNext", targets: [
    .target(name: "CmuxNextUIKit", swiftSettings: uiSwiftSettings),
    .target(name: "CmuxNextService", swiftSettings: daemonSwiftSettings),
])
"""
DOC = "# threading model\n\n## Registered threads and queues\n\n- `com.cmuxterm.next.known`\n"
RULE = next(rule for rule in guardrails.RULES if rule.id == "once-blocking")
INVENTORY_REV = "772cdfc45ac"

REFUSED = {
    "static let closure": ("struct Words {\n    static let list: [String] = {\n"
                           "        guard let url = Bundle.module.url(forResource: \"w\", withExtension: \"txt\"),\n"
                           "              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }\n"
                           "        return text.split(separator: \"\\n\").map(String.init)\n    }()\n}\n"),
    "lazy var closure": ("final class Runtime {\n    private(set) lazy var manifest: Data? = {\n"
                         "        try? Data(contentsOf: url)\n    }()\n}\n"),
    "file-scope let closure": "let table: Data? = {\n    try? Data(contentsOf: tableURL)\n}()\n",
    "direct static initializer": "enum Keys {\n    static let data = try? Data(contentsOf: keysURL)\n}\n",
    "direct static initializer over two lines": "enum Keys {\n    static let data =\n        try? Data(contentsOf: keysURL)\n}\n",
    "inline closure in a static initializer": ("struct Keys {\n    public static let bundled: Keys = {\n"
                                               "        let url = Bundle.module.url(forResource: \"k\", withExtension: \"json\")\n"
                                               "        return Keys(json: url.flatMap { try? Data(contentsOf: $0) } ?? Data())\n    }()\n}\n"),
    "a seam in a static initializer": ("enum Words {\n    static let list: [String] = {\n"
                                       "        (try? String(blockingContentsOf: url, encoding: .utf8))?.components(separatedBy: \"\\n\") ?? []\n"
                                       "    }()\n}\n"),
    "a raw-blocking-ext call in a static initializer": ("enum Launch {\n    nonisolated static let start: Double = {\n"
                                                        "        var info = kinfo_proc()\n        var size = MemoryLayout<kinfo_proc>.stride\n"
                                                        "        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]\n"
                                                        "        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }\n"
                                                        "        return 1\n    }()\n}\n"),
    "a Security call in a static initializer": ("enum Peer {\n    static let ownTeam: String? = {\n        var code: SecCode?\n"
                                                "        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }\n"
                                                "        return nil\n    }()\n}\n"),
    "a static in an extension, behind a guard": ("extension Registry {\n    nonisolated(unsafe) static var shared: Registry = {\n"
                                                 "        if let url {\n            return (try? decode(Data(contentsOf: url))) ?? empty\n"
                                                 "        }\n        return empty\n    }()\n}\n"),
}
PASSED = {
    "a literal": ("enum HostTypos {\n    static let typos: [String: String] = [\"con\": \"com\", \"ent\": \"net\"]\n"
                  "    static let limit = 64\n}\n"),
    "a literal closure": "enum Words {\n    static let list: [String] = {\n        [\"a\", \"b\"]\n    }()\n}\n",
    "a stored static closure that is not called": ("enum Loader {\n    static let load: (URL) -> Data? = { url in\n"
                                                   "        try? Data(contentsOf: url)\n    }\n}\n"),
    "a computed static property": "enum Keys {\n    static var data: Data? {\n        try? Data(contentsOf: keysURL)\n    }\n}\n",
    "a static function": ("enum Words {\n    static func loadBundled() -> [String] {\n"
                          "        (try? String(blockingContentsOf: url, encoding: .utf8))?.components(separatedBy: \"\\n\") ?? []\n"
                          "    }\n}\n"),
    "an instance member's closure": ("struct Reader {\n    let data: Data? = {\n        try? Data(blockingContentsOf: url)\n"
                                     "    }()\n}\n"),
    "a local closure in a function": ("func read() -> Data? {\n    let data: Data? = {\n"
                                      "        try? Data(blockingContentsOf: url)\n    }()\n    return data\n}\n"),
    "a closure argument of a static initializer": ("enum Lanes {\n    static let reader = Reader(load: {\n"
                                                   "        try? Data(blockingContentsOf: url)\n    })\n}\n"),
    "an escaped line": ("enum Map {\n    static let main: Data? = {\n"
                        "        // blocking-allow: fixture for the escape\n        try? Data(contentsOf: url)\n    }()\n}\n"),
    "a comment and a string": "enum Text {\n    // static let x = try? Data(contentsOf: url)\n    static let s = \"Data(contentsOf: url)\"\n}\n",
}


def change(path: str, text: str) -> guardrails.FileChange:
    lines = text.split("\n")
    return guardrails.FileChange(path, lines, [guardrails.Added(path, n + 1, t) for n, t in enumerate(lines)],
                                 is_new=True)


def hits(text: str, directory: str = SERVICE, name: str = "Added.swift") -> list:
    guardrails.load_blocking_context({}, "head")
    guardrails.BLOCKING_CONTEXT.update(threading_doc=DOC, manifest=MANIFEST)
    for scan in (guardrails.RAW_SCAN, guardrails.MAIN_SCAN, guardrails.ALWAYS_SCAN):
        scan.answers.clear()
    return RULE.find([change(f"{directory}/{name}", text)], collections.Counter())


class OnceBlockingTests(unittest.TestCase):
    def test_blocking_initializers_are_refused_in_both_kinds_of_target(self):
        for name, text in REFUSED.items():
            for directory in (SERVICE, UI):
                with self.subTest(name, directory=directory):
                    self.assertTrue(hits(text, directory), f"{name} not refused:\n{text}")

    def test_literals_functions_and_closures_that_run_later_pass(self):
        for name, text in PASSED.items():
            for directory in (SERVICE, UI):
                with self.subTest(name, directory=directory):
                    self.assertEqual([h.text for h in hits(text, directory)], [], f"{name} refused")

    def test_the_hit_is_the_blocking_line(self):
        self.assertEqual([h.number for h in hits(REFUSED["static let closure"])], [4])
        self.assertEqual([h.number for h in hits(REFUSED["inline closure in a static initializer"])], [4])
        self.assertEqual([h.number for h in hits(REFUSED["direct static initializer over two lines"])], [3])
        self.assertEqual([h.number for h in hits(REFUSED["a raw-blocking-ext call in a static initializer"])], [6])

    def test_top_level_code_in_main_swift_is_judged_as_a_global(self):
        """main.swift's top-level `let` is script code, not a lazy global, but it still runs on the main thread
        before anything else: once-blocking refuses it there too, and main-blocking judges the same line."""
        text = REFUSED["file-scope let closure"]
        self.assertTrue(hits(text, name="main.swift"))

    def test_seams_off_main_still_count_in_an_initializer(self):
        """A seam is fine on a lane, but in a static initializer it blocks whichever thread reads first."""
        found = hits(REFUSED["a seam in a static initializer"])
        self.assertEqual([h.number for h in found], [3])

    def test_the_rule_stays_fast_on_a_large_initializer_heavy_push(self):
        """10,000 refused initializers in 20 files of 60,000 lines: each block is judged once, under 1 s (the
        other blocking rules' bound)."""
        body = "".join(f"enum E{i} {{\n    static let v{i}: Data? = {{\n        guard ready else {{ return nil }}\n"
                       f"        return try? Data(contentsOf: u{i})\n    }}()\n}}\n" for i in range(500))
        changes = [change(f"{SERVICE}/Big{index}.swift", body) for index in range(20)]
        guardrails.load_blocking_context({}, "head")
        guardrails.BLOCKING_CONTEXT.update(threading_doc=DOC, manifest=MANIFEST)
        started = time.process_time()
        found = RULE.find(changes, collections.Counter())
        elapsed = time.process_time() - started
        self.assertEqual(len(found), 20 * 500)
        self.assertLess(elapsed, 1.0)

    def test_the_rule_is_a_blocking_rule_the_hook_runs(self):
        self.assertIn(RULE, guardrails.BLOCKING_RULES)
        self.assertEqual(RULE.escape, "// blocking-allow: <why no reader can be the main thread or wait on it>")

    def test_inventory_lists_the_audit_sites_at_the_reference_rev(self):
        probe = subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{INVENTORY_REV}^{{commit}}"],
                               capture_output=True)
        if probe.returncode != 0:
            self.skipTest(f"{INVENTORY_REV} is not in this clone")
        out = subprocess.run([sys.executable, "-I", str(SCRIPTS / "threading-inventory.py"), "--repo", str(REPO),
                              "--rev", INVENTORY_REV, "--rule", "once-blocking", "--jsonl",
                              # The audit read CmuxNext's Sources; the linked packages' sites are task 146's.
                              "--paths", "Packages/macOS/CmuxNext/Sources/"],
                             capture_output=True, text=True, check=True).stdout
        import json
        files = {json.loads(line)["path"].rsplit("/", 1)[-1] for line in out.splitlines() if line.strip()}
        self.assertEqual(files, {
            "AcpmuxServerPeer.swift", "DebugTimings.swift", "BrowserExportSource.swift", "SettingsPageProvider.swift",
            "AppScopeTable.swift", "CEFBuiltInExtensions.swift", "CEFRuntime.swift", "HostTypoFixup.swift",
            "BrowserSourceRegistry.swift", "ComputerUseHelperV2.swift", "AppSymbolMap.swift", "PairingWords.swift",
            "WebUpdatePointer.swift"})


if __name__ == "__main__":
    unittest.main()
