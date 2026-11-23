use super::*;

#[test]
fn plans() {
    let gap = |start, rows, skipped| WindowPlan::Gap { start, rows, skipped };
    let tail = |rows| WindowPlan::Tail { rows };
    let window = |start, rows| HistoryWindow { start: Some(start), rows };
    // (asked, history rows, plan)
    let cases = [
        // A tail is what it was: the newest rows asked for.
        (HistoryWindow::tail(0), 100_000, tail(0)),
        (HistoryWindow::tail(2_000), 100_000, tail(2_000)),
        (HistoryWindow::tail(50_000), 100_000, tail(50_000)),
        // The top of a 100k-row history: line 1 first, then the screen.
        (window(0, 4_000), 100_000, gap(0, 4_000, 96_000)),
        // Anywhere in the middle.
        (window(48_000, 4_000), 100_000, gap(48_000, 4_000, 48_000)),
        // A window is bounded.
        (window(0, 1_000_000), 100_000, gap(0, MAX_WINDOW_ROWS, 90_000)),
        (window(0, 0), 100_000, gap(0, 1, 99_999)),
        // Near the screen: one tail from the window's start, at most twice the window.
        (window(93_000, 4_000), 100_000, tail(7_000)),
        (window(96_000, 4_000), 100_000, tail(4_000)),
        (window(99_000, 4_000), 100_000, tail(1_000)),
        // Past the end (the history shrank): the screen alone.
        (window(120_000, 4_000), 100_000, tail(0)),
        // A short history.
        (window(0, 4_000), 3_000, tail(3_000)),
        (window(0, 4_000), 0, tail(0)),
    ];
    for (asked, history, plan) in cases {
        assert_eq!(asked.plan(history), plan, "{asked:?} over {history} rows");
    }
}

#[test]
fn a_reflow_keeps_the_window_size_as_a_tail() {
    assert_eq!(HistoryWindow::tail(2_000).after_reflow(), HistoryWindow::tail(2_000));
    assert_eq!(
        HistoryWindow { start: Some(40_000), rows: 4_000 }.after_reflow(),
        HistoryWindow::tail(4_000)
    );
    assert_eq!(
        HistoryWindow { start: Some(0), rows: 1_000_000 }.after_reflow(),
        HistoryWindow::tail(MAX_WINDOW_ROWS)
    );
}
