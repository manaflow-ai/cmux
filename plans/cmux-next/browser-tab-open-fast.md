# Browser tab open/close as fast as the bare New Tab page (ask-08552f8ea0)

Leo (2026-11-03): "i want us opening a browser tab to be that fast too... actually, we should be able to
optimistically just have a "thing" open. ... and the new tab at the top opening first in the main pane THEN in
the right split is still an issue... it shouldn't play the top new tab thing appearing there then appearing where
it should be..."

Shipped before this lane: an in-pane stand-in with its page in the key's turn (NewBrowserTabCommand, PL-cef-tab),
Split Browser / header Browser / links straight into their split (#32900, #33172, #33466, #33548), closes on the
click (#32876).

This lane:
1. Measure base (instant-new-surfaces bench, close-flash bench, frames) on cmux16/air-blue.
2. Close the remaining gaps the measurement and a path audit find (open paths that still wait for the
   daemon, or make a tab in the source pane and move it).
3. Same harness after; a capture showing no main-pane flash.
