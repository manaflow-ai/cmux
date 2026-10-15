#!/usr/bin/env python3
"""A title command for tests: never a model. It records what it was asked
(argv[1], when given) and answers a quoted title with a trailing period, as a
model sometimes does."""
import sys

request = sys.stdin.read()
if len(sys.argv) > 1:
    with open(sys.argv[1], "a") as f:
        f.write(request + "\n---\n")
print('"Three-Dish Picnic Menu."')
