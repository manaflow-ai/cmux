#!/usr/bin/env python3
"""web-bundle-key.py --shared: every cmux-page://cmux.shared/ file a built web tree names is in the
tree's own pages/_shared, and the trees name one React between them (p13-webui-072). The Swift
WebUpdateTreeTests hold WebUpdateTree.missingSharedFiles() to the same reading."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY = ROOT / "scripts/cmux-next/web-bundle-key.py"
PAGES = "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
APP = "Resources/markdown-viewer/webviews-app"
ACTIVITY = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
REACT = "react-AB12CD34.js"


def tree(root: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


def whole() -> dict[str, str]:
    return {
        f"{PAGES}/_shared/{REACT}": "export const react$useState=1;",
        f"{PAGES}/settings/index.html": f'<link rel="modulepreload" href="cmux-page://cmux.shared/{REACT}" />',
        f"{APP}/chunks/vendor.mjs": f'import{{react$default as R}}from"cmux-page://cmux.shared/{REACT}";',
        f"{ACTIVITY}/index.html": "<meta content=\"script-src cmux-page://cmux.shared\" />"
        + f'<script type="module">import"cmux-page://cmux.shared/{REACT}";</script>',
    }


def shared(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(KEY), str(root), "--shared"], capture_output=True, text=True)


def test_a_whole_tree_names_one_react_it_holds() -> None:
    with tempfile.TemporaryDirectory() as work:
        result = shared(tree(Path(work), whole()))
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == f"shared React: {REACT}"


def test_a_file_the_tree_lacks_or_a_second_react_fails() -> None:
    with tempfile.TemporaryDirectory() as work:
        files = whole()
        files[f"{APP}/chunks/vendor.mjs"] = 'import"cmux-page://cmux.shared/react-OTHER.js";'
        files[f"{PAGES}/_shared/react-OTHER.js"] = "x"
        files[f"{ACTIVITY}/index.html"] = 'import"cmux-page://cmux.shared/missing.js";import"cmux-page://cmux.shared/../x.js";'
        result = shared(tree(Path(work), files))
        assert result.returncode == 1
        assert f"{ACTIVITY}/index.html: cmux-page://cmux.shared/../x.js is not in {PAGES}/_shared" in result.stderr
        assert f"{ACTIVITY}/index.html: cmux-page://cmux.shared/missing.js is not in {PAGES}/_shared" in result.stderr
        assert f"the bundles name 2 React files: {REACT}, react-OTHER.js" in result.stderr


def test_names_are_read_as_swift_reads_them() -> None:
    with tempfile.TemporaryDirectory() as work:
        files = whole()
        # A policy's bare origin and a source map name nothing.
        files[f"{APP}/chunks/map.mjs"] = "cmux-page://cmux.shared; cmux-page://cmux.shared/react-X.js.map"
        result = shared(tree(Path(work), files))
        assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_") and callable(test):
            test()
    print("ok")
