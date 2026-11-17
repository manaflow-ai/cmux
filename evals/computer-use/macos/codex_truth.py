# SPDX-License-Identifier: MIT
"""codex_truth.py: truthmatrix.py with the Codex Computer Use arm (codex_arm.py).

  python3 codex_truth.py --arm codex-cu --reps 3 --out DIR      (in a guest GUI session, through gr.sh)

Codex results carry no outcome enum: the claim is what the result says, `error` (isError) or `refused` (a policy
refusal in the text) against success (`ok`), scored against the oracle like Aside's.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import codex_arm  # noqa: E402
import truthmatrix as tm  # noqa: E402

tm.ACTING |= {"perform_secondary_action", "select_text"}

_orig_right = tm.right_click_el


def right_click_el(arm, w, n):
    if isinstance(arm, codex_arm.Codex):
        return arm.click_el(w, n, button="right")
    return _orig_right(arm, w, n)


tm.right_click_el = right_click_el

_orig_run_cell = tm.run_cell


def run_cell(arm, scene, app, cell, w, rep, scene_kind, ctx, out, late):
    note = codex_arm.select_window(arm, w)
    if note:
        with open(os.path.join(out, "codex-window-select.log"), "a") as f:
            f.write(f"{app} {cell.name} r{rep} {scene_kind}: {note}\n")
    return _orig_run_cell(arm, scene, app, cell, w, rep, scene_kind, ctx, out, late)


tm.run_cell = run_cell

if __name__ == "__main__":
    tm.main()
