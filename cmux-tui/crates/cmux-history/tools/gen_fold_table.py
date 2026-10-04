#!/usr/bin/env python3
"""Regenerates src/fold_table.rs from Python's Unicode Character Database.

Usage: python3 tools/gen_fold_table.py > src/fold_table.rs

DIACRITIC_BASES: every assigned Latin, Greek, Cyrillic or Kana character whose
canonical decomposition (NFD) is one base character followed only by
nonspacing marks (category Mn) maps to that base.
WIDTH_FORMS: every U+FF00..U+FFEF character with a single-character <wide> or
<narrow> compatibility decomposition maps to its target; U+3000 maps to space.
"""
import unicodedata as u

RANGES = [(0xC0, 0x24F), (0x1E00, 0x1EFF), (0x370, 0x3FF), (0x1F00, 0x1FFF), (0x400, 0x4FF), (0x3040, 0x30FF)]


def diacritic_bases():
    pairs = []
    for start, end in RANGES:
        for cp in range(start, end + 1):
            ch = chr(cp)
            if u.category(ch) == "Cn":
                continue
            d = u.normalize("NFD", ch)
            if len(d) > 1 and all(u.category(x) == "Mn" for x in d[1:]) and u.category(d[0]) != "Mn":
                pairs.append((cp, ord(d[0])))
    return sorted(pairs)


def width_forms():
    pairs = []
    for cp in range(0xFF00, 0xFFEF):
        dec = u.decomposition(chr(cp))
        if dec.startswith("<wide>") or dec.startswith("<narrow>"):
            parts = dec.split()[1:]
            if len(parts) == 1:
                pairs.append((cp, int(parts[0], 16)))
    pairs.append((0x3000, 0x20))
    return sorted(pairs)


def emit(name, doc, items):
    print(doc)
    print(f"pub(crate) const {name}: &[(char, char)] = &[")
    for i in range(0, len(items), 6):
        print("    " + " ".join(f"('\\u{{{a:04X}}}', '\\u{{{b:04X}}}')," for a, b in items[i:i + 6]))
    print("];")


print("//! Generated from the Unicode Character Database (Python unicodedata %s)." % u.unidata_version)
print("//! Do not edit by hand; the generator is described in `fold.rs`.")
print()
emit("DIACRITIC_BASES", "/// A precomposed letter and the base letter of its canonical decomposition, for\n/// Latin, Greek, Cyrillic and Kana letters whose decomposition is the base\n/// followed only by nonspacing marks. Sorted by the first field.", diacritic_bases())
print()
emit("WIDTH_FORMS", "/// A fullwidth or halfwidth form and its `<wide>`/`<narrow>` compatibility\n/// target, plus U+3000 IDEOGRAPHIC SPACE as a space. Sorted by the first field.", width_forms())
