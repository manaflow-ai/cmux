"""The one rule for `did a pane move in this act`, for the measure scripts that drive a real window.

The source is the pane trace (the reply of `debug.motion` trace_stop with the target `panes`): one sample for each
tick of the window's display link, and in it one row for each pane with where the pane ends and where it IS. A pane
that is not where it ends in 2 samples or more is a move. The app's own samples (`layout.travel`: a layout spring
moved; `layout.commit`: a commit motion had a pane in flight) are a second source: `layout.commit` is only in a
build with the probe, so a count of the 2 alone reads 0 for a zoom, a split or a close of a build without it.

A script that has neither source for an act says NO SOURCE and fails its row: it does not say that the app did not
move. The trace's sampler costs main-thread time at each tick, so a script runs it in a round of its own (a proof
round), not in a timed round.

Callers: pane-perf-terminal.py (each act of an arm's proof round, and a recorded act) and pane-zoom-terminal.py
(a layout's proof round). tests/test_pane_move.py holds both to it.
"""


def pane_in_a_move(sample):
    """If a pane of one sample of the pane trace IS not where it ends, by more than 0.5 pt: a pane row's last 4
    numbers against its first rect. A row of fewer than 22 entries does not say where the pane is: not in a move."""
    def moves(row):
        return isinstance(row, list) and len(row) >= 22 and any(abs(now - end) > 0.5 for now, end in zip(row[-4:], row[1:5]))
    return isinstance(sample, dict) and any(moves(row) for row in sample.get("panes") or [])


def move_facts(trace):
    """What a pane trace (the reply of `debug.motion` trace_stop) says of a move: `samples`, `samples_in_a_move` (the
    samples in which a pane IS not where it ends by more than 0.5 pt: a pane row's last 4 numbers against its first
    rect) and `no_source`: None, or why this trace cannot say if a pane moved (no sample, no pane in a sample, or a
    build with a sampler that says only where a pane ends: a pane row of fewer than 22 entries)."""
    samples = trace.get("samples") if isinstance(trace, dict) and isinstance(trace.get("samples"), list) else []
    rows = [row for sample in samples if isinstance(sample, dict) for row in sample.get("panes") or []]
    in_a_move = sum(1 for sample in samples if pane_in_a_move(sample))
    if not samples:
        no_source = f"no sample in the pane trace: {trace!r}"[:200]
    elif not rows:
        no_source = f"no pane in the {len(samples)} samples of the pane trace"
    elif not all(isinstance(row, list) and len(row) >= 22 for row in rows):
        no_source = "the build's pane trace does not say where a pane is in a sample (a pane row of fewer than 22 entries)"
    else:
        no_source = None
    return {"samples": len(samples), "samples_in_a_move": in_a_move, "no_source": no_source}


def animated_row(arm, moving, committed, move, notes):
    """The row of one timed act that says if the act moved: (its name, what it expects, what it saw, passed).
    `move`: `move_facts` of the pane trace that ran through the act; `moving` and `committed`: `moving_frames` and
    `commit_frames` of the same act (the app's own samples; `layout.commit` is only in a build with the probe).
    With the motion on (`arm` on, or None: the app's own setting) the act is animated when a pane is in a move in 2
    samples or more (a change that the app shows in one frame has 1 sample at the most: a new pane's first sample),
    or a spring or commit frame is there (New Column moves only the strip camera, and no pane). With the motion off
    it is still with 1 sample at the most and no such frame. A row with no source (no trace that says where a pane
    is, and no frame of the app's samples) says NO SOURCE and fails: it does not say that the app did not move."""
    counts = f"{moving} spring frames, {committed} commit frames"
    seen = (f"NO SOURCE: {move['no_source']}; {counts}" if move["no_source"]
            else f"{move['samples_in_a_move']} of {move['samples']} samples of the pane trace in a move; {counts}")
    traced = not move["no_source"]
    if arm == "off":
        return ("still (the pane motion is off)", "1 sample in a move at the most, 0 frames", seen,
                traced and move["samples_in_a_move"] <= 1 and not moving and not committed)
    animated = (moving or 0) > 0 or (committed or 0) > 0 or (traced and move["samples_in_a_move"] >= 2)
    return ("animated (a pane's rect moves in the pane trace, or a layout spring, the strip camera or a commit motion moved)",
            "2 samples in a move or more, or above 0 frames", seen + ("" if animated or not traced else f"; the app's notes: {list(notes)[:4]}"),
            animated)
