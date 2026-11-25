"""Natural ("human") ordering for file names, tab titles and session names.

Rules, in order:

1. A name splits into runs of ASCII digits ("0"-"9") and runs of everything else. Only ASCII digits count:
   other characters Python calls digits, such as "²" or "٣", are ordinary text.
2. Names compare run by run, left to right; a name that runs out of runs first sorts first.
3. Two digit runs compare by numeric value, whatever their length ("9" < "10" < "0000000011"; file names built
   from hashes and timestamps can have very long runs). Two text runs compare case-insensitively (by
   `str.casefold`). A digit run sorts before a text run at the same position ("1x" < "x").
4. Names still equal after that (they differ only in case or in leading zeros) are ordered by their digit runs'
   lengths, run by run, shorter first ("a1" < "a01"), and then by the names themselves, by code point
   ("A" < "a"). So two names are tied only when they are the same string.

`natural_sort(items, key=None, reverse=False)` returns a new list. `key` maps an item to the name to sort it by.
The sort is stable: items whose names are the same string keep their input order, also when `reverse` is
true. `natural_key(name)` returns a value with that order; equal names give equal values.
"""
import functools
import re

_RUN = re.compile(r"(\d+)")


def _runs(name):
    parts = _RUN.split(name)
    return [int(p) if i % 2 else p.casefold() for i, p in enumerate(parts)]


def compare(a, b):
    """-1, 0 or 1 by the rules above."""
    ra, rb = _runs(a), _runs(b)
    if ra != rb:
        return -1 if ra < rb else 1
    return 0


natural_key = functools.cmp_to_key(compare)


def natural_sort(items, key=None, reverse=False):
    name = key if key is not None else (lambda x: x)
    return sorted(items, key=lambda item: natural_key(name(item)), reverse=reverse)
