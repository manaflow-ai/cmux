#!/usr/bin/env python3
"""A rolling-summary command for tests: never a model. It appends what it was asked to argv[1]
(each request followed by a `---` line) and answers in the summary format the daemon asks for,
with a stray blank line and a quoted next action, as a model sometimes does. A request that
carries a status so far (a later turn) gets a new status, so the daemon has a change to tell."""
import sys

request = sys.stdin.read()
if len(sys.argv) > 1:
    with open(sys.argv[1], "a") as f:
        f.write(request + "\n---\n")
if "The status so far:" in request:
    print("Summary: The vegetarian picnic menu is final.")
    print()
    print("Next: Write the shopping list.")
else:
    print("Summary: The picnic menu has three dishes, all vegetarian.")
    print()
    print('Next: "Pick a dessert."')
