# Terminal corruption experiment

This diagnostic preserves the current resize policy. It tests the hypothesis
that terminal output meets a different grid from the size reported to its
process. It does not claim to fix or reproduce the corruption reported in
https://github.com/manaflow-ai/cmux/issues/12681.

Inside a disposable terminal in the tagged app:

    python3 scripts/terminal-resize-probe.py --output /tmp/cmux-resize-probe

The fixture uses incremental character updates and gray input bands on the
primary screen. Space pauses the animation, s saves the expected synthetic
text, and q exits. The --alternate-screen option provides a separate control.

Run the stationary case first. Then switch away and back, create and close a
sibling pane, and resize between narrow and wide layouts while output runs.
Test restored sessions separately from fresh ones. Capture the first damaged
frame before refreshing or restarting it.

The fixture compares TIOCGWINSZ, the dimensions reported by the kernel, with
a cursor-position report after a cursor move that Ghostty clamps to its actual
parser grid. It saves and restores the cursor, keeps only one query outstanding,
and stops measuring after a timeout because an untagged late reply cannot be
safely assigned to another query.

Evidence:

- events.jsonl: kernel dimensions before and after each reply, parser grid,
  resize-signal sequence, timestamps, and reply latency.
- summary.json: matches, mismatches, overlapping resizes, and timeouts.
- expected-screen.txt: the synthetic screen the fixture intended to draw.
- /tmp/cmux-debug-TAG.log: surface.size.apply records plus
  surface.size.settlement.finish, labelled hide, detach,
  visibility.false, external.stable, external.retryExhausted,
  deferred.stable, or deferred.retryExhausted.

A mismatch with unchanged kernel observations supports a grid disagreement.
A resize during a query is labelled separately. Matching dimensions do not
exclude a shorter race, a damaged earlier redraw, or a graphics-only defect.
The fixture's queries also perturb scheduling, so repeat any discovered trigger
with the real affected terminal app.

For each damaged frame, retain the screenshot and read-screen text before
requesting a refresh. If the text is already damaged, investigate parsing,
resize, or the terminal app's output. If the text is correct but pixels are
damaged, investigate the renderer and presentation path.

Compare any proposed repair against the same source revision with diagnostics
alone. A successful clean run is not evidence that the original bug is fixed
unless the unmodified control reproduces it.
