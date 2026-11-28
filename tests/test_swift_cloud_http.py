#!/usr/bin/env python3
"""scripts/cmux-next/swift-cloud-http.py: which Swift files count as Cloud networking."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/swift-cloud-http.py"
spec = importlib.util.spec_from_file_location("swift_cloud_http", SCRIPT)
sch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sch)


class SwiftCloudHTTPTests(unittest.TestCase):
    def tree(self, files: dict[str, str]) -> Path:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-r", "--", str(tmp)], check=False))
        for rel, text in files.items():
            path = tmp / sch.SOURCES / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return tmp

    def test_counts_cloud_requests_only(self):
        root = self.tree({
            "CmuxNextCloud/API/CloudX.swift": "let r = URLRequest(url: u)\nlet (d, _) = try await s.data(for: r)\n",
            "CmuxNextApp/Feed/Feed.swift": 'let b = "https://api.cmux.dev"\nlet t = s.webSocketTask(with: u)\n',
            "CmuxNextApp/Other/Web.swift": "let r = URLRequest(url: u)\n",
            "CmuxNextCloud/Model/CloudModel.swift": "struct CloudModel {}\n",
            "CmuxNextCloud/Tests/CloudTest.swift": "let r = URLRequest(url: u)\n",
            "CmuxNextCloud/API/Commented.swift": "// URLRequest(url: u)\n/* .data(for: r) */\n",
        })
        got = sch.count(root)
        self.assertEqual([f["path"].split("/")[-1] for f in got["files"]], ["CloudX.swift", "Feed.swift"])
        self.assertEqual((got["http_files"], got["http_sites"]), (2, 3))
        self.assertEqual(got["http_bytes"], sum(f["bytes"] for f in got["files"]))

    def test_not_cloud_files_are_left_out(self):
        rel = next(iter(sch.NOT_CLOUD))
        root = self.tree({rel[len(sch.SOURCES) + 1:]: 'let h = "presence.cmux.dev"\nlet t = s.webSocketTask(with: u)\n'})
        self.assertEqual(sch.count(root)["http_files"], 0)

    def test_json_cli_runs_isolated(self):
        root = self.tree({"CmuxNextCloud/A.swift": "let r = URLRequest(url: u)\n"})
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(root), "--json"],
                             check=True, capture_output=True, text=True).stdout
        self.assertEqual(json.loads(out)["http_files"], 1)


if __name__ == "__main__":
    unittest.main()
