use super::*;

fn mirror_with(bytes: &[u8]) -> (TerminalMirror, Arc<AtomicBool>) {
    let title_changed = Arc::new(AtomicBool::new(false));
    let flag = title_changed.clone();
    let callbacks = Callbacks {
        on_title_changed: Some(Box::new(move || flag.store(true, Ordering::Relaxed))),
        ..Callbacks::default()
    };
    let mut term = Terminal::new(20, 4, 1 << 20, callbacks).unwrap();
    term.vt_write(bytes);
    (TerminalMirror::new(Box::new(term)), title_changed)
}

fn park(mirror: &TerminalMirror, title_changed: &Arc<AtomicBool>) -> bool {
    let flag = title_changed.clone();
    mirror.park(ParkMirror {
        geometry: PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 },
        scrollback: 1 << 20,
        defaults: DefaultColors::default(),
        callbacks: Callbacks {
            on_title_changed: Some(Box::new(move || flag.store(true, Ordering::Relaxed))),
            ..Callbacks::default()
        },
        title_changed,
    })
}

/// Text, history, title, cursor and colors as a lock reads them.
fn state(
    mirror: &TerminalMirror,
) -> (String, usize, Option<String>, Option<(u16, u16)>, TerminalColorOverrides) {
    let mut term = mirror.lock().unwrap();
    (
        term.plain_text().unwrap(),
        term.scrollback_rows(),
        term.title(),
        term.cursor_position(),
        term.color_overrides(),
    )
}

const SCREEN: &[u8] = b"\x1b]2;parked title\x07line 1\r\nline 2\r\nline 3\r\nline 4\r\nline 5\r\n\
    line 6\r\n\x1b[31mred\x1b[0m \x1b]11;rgb:10/20/30\x07pro";

#[test]
fn a_parked_mirror_rebuilds_to_the_same_terminal() {
    let (mirror, title_changed) = mirror_with(SCREEN);
    let before = state(&mirror);
    title_changed.store(false, Ordering::Relaxed);
    assert!(park(&mirror, &title_changed));
    assert!(mirror.is_parked());
    assert!(!park(&mirror, &title_changed), "a parked mirror does not park again");
    let after = state(&mirror);
    assert!(!mirror.is_parked());
    assert_eq!(before, after);
    assert!(!title_changed.load(Ordering::Relaxed), "the rebuild is no title change");
}

#[test]
fn output_after_a_rebuild_lands_where_it_would_have() {
    let (live, _) = mirror_with(SCREEN);
    let (mirror, title_changed) = mirror_with(SCREEN);
    assert!(park(&mirror, &title_changed));
    for terminal in [&live, &mirror] {
        terminal.lock().unwrap().vt_write(b"mpt$ \x1b[2Jcleared\r\nnext");
    }
    assert_eq!(state(&live), state(&mirror));
}

#[test]
fn try_lock_rebuilds_too() {
    let (mirror, title_changed) = mirror_with(SCREEN);
    let before = state(&mirror);
    assert!(park(&mirror, &title_changed));
    drop(mirror.try_lock().unwrap());
    assert!(!mirror.is_parked());
    assert_eq!(before, state(&mirror));
}

#[test]
fn a_parked_mirror_holds_no_scrollback() {
    let mut screen = Vec::new();
    for line in 0..2000 {
        screen.extend_from_slice(format!("history line {line}\r\n").as_bytes());
    }
    let (mirror, title_changed) = mirror_with(&screen);
    let rows = mirror.lock().unwrap().scrollback_rows();
    assert!(rows > 1000);
    assert!(park(&mirror, &title_changed));
    // Read the placeholder without rebuilding it.
    assert_eq!(mirror.term.lock().unwrap().scrollback_rows(), 0);
    assert_eq!(mirror.lock().unwrap().scrollback_rows(), rows);
}
