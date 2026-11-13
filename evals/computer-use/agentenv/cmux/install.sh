#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Manaflow, Inc.
# Linux, as root, in the driver's folder: the cmux binary overlay.py staged (bin/cmux-tui.gz) unpacked to bin/cmux.
# driver.py's ready check compares its sha256 with the pin.
set -eu
[ -f bin/cmux-tui.gz ] || { echo "bin/cmux-tui.gz is missing: stage it with overlay.py --cmux" >&2; exit 1; }
gunzip -c bin/cmux-tui.gz > bin/cmux
chmod 755 bin/cmux
rm -f bin/cmux-tui.gz
ln -sf "$PWD/bin/cmux" /usr/local/bin/cmux
