#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write pending Windows notices for dogfood package builds only.

  windows_notice_pending.py --out-dir dist/package-notices

package_notices.py refuses x86_64-pc-windows-gnu until the mingw-w64 runtime
notices are reviewed, so no Windows notice exists. The cmux-tui full gate's
dogfood job (cmux-tui.yml build-artifacts, input windows_notices_pending) still
packages Windows; it writes this pending text in place of the notice. Publish
workflows never run this, so their packaging stops on the missing notice.
Refuses to replace a generated notice.
"""

from __future__ import annotations

import argparse
from pathlib import Path

TARGET = "x86_64-pc-windows-gnu"
KINDS = ("cmux-tui", "relay")
TEXT = (
    "# Third-party notices: pending review\n\n"
    f"This {TARGET} package is a dogfood build artifact. Its third-party notices\n"
    "(the mingw-w64 runtime and the other linked code) are pending review, so it\n"
    "must not be published. Publishing workflows refuse Windows until the review\n"
    "lands (cmux-tui/dist/scripts/package_notices.py).\n"
)


def write_pending(out_dir: Path) -> list[Path]:
    paths = [out_dir / f"{kind}-{TARGET}.md" for kind in KINDS]
    for path in paths:
        if path.exists():
            raise SystemExit(f"{path} exists; a generated Windows notice is never replaced by the pending text")
    for path in paths:
        path.write_text(TEXT)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    for path in write_pending(args.out_dir):
        print(f"windows_notice_pending: wrote {path} (dogfood only, not publishable)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
