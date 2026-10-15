"""Local file:// pages for browser socket tests.

`browser.navigate` resolves its URL like the omnibar, which loads only web and
file URLs: a `data:` URL is searched for instead of loaded. Tests that navigate
an existing surface write their fixture HTML to a temporary file instead.
"""

import atexit
import itertools
import shutil
import tempfile
from pathlib import Path

_root = Path(tempfile.mkdtemp(prefix="cmux-browser-test-pages-"))
atexit.register(shutil.rmtree, _root, ignore_errors=True)
_counter = itertools.count()


def local_html_url(html: str, name: str = "page") -> str:
    """Writes `html` to a new temporary file and returns its file:// URL."""
    path = _root / f"{name}-{next(_counter)}.html"
    path.write_text(html, encoding="utf-8")
    return path.resolve().as_uri()
