//! Cold scrollback on a terminal runtime: a compressed
//! terminal reads back byte-identical, every access restores it first, a
//! viewer keeps it hot, and the memory budget's size read leaves it cold.

use std::sync::atomic::AtomicUsize;

use super::*;

/// A terminal with `lines` rows of styled history.
fn terminal_with_history(lines: usize) -> (Arc<Mux>, Arc<Surface>) {
    let mux = Mux::new_for_test("cold-scrollback", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.with_terminal(|term| {
        for line in 0..lines {
            let color = 31 + line % 7;
            term.vt_write(
                format!(
                    "2026-10-26T10:{:02}:{:02} \x1b[{color}mINFO\x1b[0m build/{line:05}.o \x1b[1m{:08x}\x1b[0m\r\n",
                    line / 60 % 60,
                    line % 60,
                    line * 2_654_435_761 % 0xffff_ffff,
                )
                .as_bytes(),
            );
        }
        term.vt_write(b"\x1b[32mprompt$\x1b[0m ");
    });
    (mux, surface)
}

/// What `read-scrollback` and the screen read, all of it.
type Reads = (u32, u64, Vec<Vec<ghostty_vt::Cell>>, String, Option<(u16, u16)>);

fn reads(surface: &Surface) -> Reads {
    surface
        .try_with_terminal(|term| {
            let total = term.history_rows();
            let mut rows = Vec::new();
            let mut start = 0;
            while start < total {
                let page = term.styled_history_rows(start, 500).unwrap();
                start += u32::try_from(page.len()).unwrap();
                rows.extend(page);
            }
            (
                total,
                term.history_epoch(),
                rows,
                term.viewport_text().unwrap(),
                term.cursor_position(),
            )
        })
        .unwrap()
}

fn counting_wake() -> (ThawWake, Arc<AtomicUsize>) {
    let thaws = Arc::new(AtomicUsize::new(0));
    let counter = thaws.clone();
    (Arc::new(move || _ = counter.fetch_add(1, Ordering::Relaxed)), thaws)
}

#[test]
fn cold_scrollback_read_is_byte_identical_after_compression() {
    let (_mux, surface) = terminal_with_history(3_000);
    let before = reads(&surface);
    assert!(before.0 > 2_000, "the history did not scroll back: {} rows", before.0);
    let Some(ScrollbackMemory::Hot(hot)) = surface.scrollback_memory() else {
        panic!("a fresh terminal is hot");
    };
    let (wake, thaws) = counting_wake();

    let outcome = surface.freeze_cold_terminal(&[], &wake).unwrap();
    let ColdFreeze::Frozen { held_bytes } = outcome else { panic!("not frozen: {outcome:?}") };
    assert!(surface.terminal_is_cold());
    assert!(held_bytes as u64 * 4 < hot, "{held_bytes} compressed bytes of {hot} resident");
    assert_eq!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::AlreadyCold));
    assert_eq!(thaws.load(Ordering::Relaxed), 0);

    let after = reads(&surface);
    assert!(!surface.terminal_is_cold(), "a read restores the terminal first");
    assert_eq!(thaws.load(Ordering::Relaxed), 1, "one restore, one wake");
    assert_eq!(after.0, before.0);
    assert_eq!(after.1, before.1, "history epoch");
    assert!(after.2 == before.2, "styled history rows differ after a restore");
    assert_eq!(after.3, before.3);
    assert_eq!(after.4, before.4);
}

#[test]
fn cold_scrollback_output_and_attach_restore_first() {
    let (_mux, surface) = terminal_with_history(500);
    let (wake, thaws) = counting_wake();
    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));

    surface.apply_local_pty_output_for_test(b"\r\nafter the restore").unwrap();
    assert!(!surface.terminal_is_cold());
    assert_eq!(thaws.load(Ordering::Relaxed), 1);
    let (total, _, _, viewport, _) = reads(&surface);
    assert!(total >= 450, "history survived output after a restore: {total} rows");
    assert!(viewport.contains("after the restore"), "{viewport:?}");

    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));
    let attach = surface.attach_stream().unwrap();
    assert!(!surface.terminal_is_cold(), "an attach restores the terminal first");
    assert_eq!(thaws.load(Ordering::Relaxed), 2);
    let mut mirror = Terminal::new(attach.cols, attach.rows, 10_000, Callbacks::default()).unwrap();
    mirror.vt_write(&attach.replay);
    assert!(mirror.viewport_text().unwrap().contains("after the restore"));

    // A resize restores first too; the terminal keeps its history.
    drop(attach);
    let (cols, rows) = (surface.size().0, surface.size().1);
    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));
    surface.resize(cols + 4, rows).unwrap();
    assert!(!surface.terminal_is_cold());
    assert!(reads(&surface).0 > 0);
}

#[test]
fn cold_scrollback_viewer_keeps_the_terminal_hot() {
    let (_mux, surface) = terminal_with_history(200);
    let (wake, thaws) = counting_wake();
    let attach = surface.attach_stream().unwrap();

    assert_eq!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Viewed));
    assert!(!surface.terminal_is_cold());
    assert_eq!(thaws.load(Ordering::Relaxed), 0);
    drop(attach);
}

#[test]
fn cold_scrollback_busy_terminal_is_left_alone() {
    let (_mux, surface) = terminal_with_history(200);
    let (wake, _) = counting_wake();
    let pty = surface.as_pty().unwrap();
    let held = pty.term.lock().unwrap();

    assert_eq!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Busy));
    drop(held);
    assert!(!surface.terminal_is_cold());
}

#[test]
fn cold_scrollback_memory_read_leaves_the_terminal_cold() {
    let (_mux, surface) = terminal_with_history(1_000);
    let (wake, thaws) = counting_wake();
    let Some(ColdFreeze::Frozen { held_bytes }) = surface.freeze_cold_terminal(&[], &wake) else {
        panic!("not frozen");
    };

    assert_eq!(surface.scrollback_memory(), Some(ScrollbackMemory::Cold(held_bytes as u64)));
    assert_eq!(surface.scrollback_memory(), Some(ScrollbackMemory::Cold(held_bytes as u64)));
    assert!(surface.terminal_is_cold());
    assert_eq!(thaws.load(Ordering::Relaxed), 0);
}

#[test]
fn cold_scrollback_view_scrolled_back_keeps_its_offset_across_a_restore() {
    let (_mux, surface) = terminal_with_history(1_000);
    let scrolled = surface.view_scroll_delta(-100).unwrap().unwrap();
    assert_eq!(scrolled.offset, scrolled.total - scrolled.len - 100);
    let (wake, thaws) = counting_wake();

    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));
    assert_eq!(surface.view_scrollbar(), Some(scrolled), "the view moved across a restore");
    assert_eq!(thaws.load(Ordering::Relaxed), 1);

    // The anchor still follows its row: output after a restore grows the
    // history below it, and the view keeps showing the same rows.
    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));
    surface.apply_local_pty_output_for_test(b"\r\none\r\ntwo\r\nthree").unwrap();
    let after = surface.view_scrollbar().unwrap();
    assert_eq!(after.offset, scrolled.offset, "{scrolled:?} then {after:?}");
    assert!(after.total > scrolled.total);
}

#[test]
fn cold_scrollback_view_scrolled_on_the_inactive_screen_keeps_the_terminal_hot() {
    let (_mux, surface) = terminal_with_history(500);
    surface.view_scroll_delta(-50).unwrap().unwrap();
    surface.apply_local_pty_output_for_test(b"\x1b[?1049h").unwrap();
    let (wake, thaws) = counting_wake();

    assert_eq!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::InactiveScreenScrolled));
    assert!(!surface.terminal_is_cold());
    assert_eq!(thaws.load(Ordering::Relaxed), 0);
}

#[test]
fn cold_scrollback_hot_only_read_leaves_a_cold_terminal_cold() {
    let (_mux, surface) = terminal_with_history(500);
    let cols = surface.size().0;
    assert_eq!(surface.try_with_hot_terminal(|term| term.cols()).unwrap(), Some(cols));
    let (wake, thaws) = counting_wake();
    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));

    assert_eq!(surface.try_with_hot_terminal(|term| term.cols()).unwrap(), None);
    assert!(surface.terminal_is_cold());
    assert_eq!(thaws.load(Ordering::Relaxed), 0);
}
