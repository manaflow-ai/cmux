#!/usr/bin/env bash
# Builds the app's Swift markdown parser alone and prints its parses of tests/parity/corpus.json
# (main.swift). The image placeholder and URL(string:) step take the Rust DefaultPolicy's
# English and rule, so both sides answer the same; everything else is the app's file as is.
# Usage: run.sh OUT [ROUNDS]  (ROUNDS: time the parse instead, the best round to OUT)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../../../.." && pwd)
src=$root/Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/MarkdownParser.swift
work=$(mktemp -d)
python3 - "$src" "$work/parser.swift" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("        let scheme = String(String.UnicodeScalarView(head)).lowercased()")
b = s.index("        return s\n    }\n", a) + len("        return s\n    }\n")
s = s[:a] + "        let s = String(String.UnicodeScalarView(u))\n        return parityAllows(s) ? s : nil\n    }\n" + s[b:]
old = 'String(format: MessagesLabLocalization.string("markdown.image.placeholder", "[Image: %@]"), alt)'
assert old in s
s = s.replace(old, '"[Image: " + alt + "]"')
open(sys.argv[2], "w").write(s)
PY
swiftc -O "$here/shims.swift" "$work/parser.swift" "$here/main.swift" -o "$work/dump"
"$work/dump" "$here/../corpus.json" ${2:-} > "$1"
