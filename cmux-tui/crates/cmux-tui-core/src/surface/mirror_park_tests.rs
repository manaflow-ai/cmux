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
    (TerminalMirror::new(Box::new(term), 1 << 20), title_changed)
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
fn a_look_at_a_parked_mirror_leaves_it_parked() {
    let (mirror, title_changed) = mirror_with(SCREEN);
    let read = |term: &mut Terminal, _: Option<&ParkedLook>| {
        (term.plain_text().unwrap(), term.scrollback_rows())
    };
    let live = mirror.with_terminal_kept_parked(|_| None, read);
    title_changed.store(false, Ordering::Relaxed);
    assert!(park(&mirror, &title_changed));
    assert_eq!(mirror.with_terminal_kept_parked(|_| None, read), live);
    assert_eq!(mirror.scratch_builds(), 1);
    assert!(mirror.is_parked(), "the look read a scratch rebuild");
    assert!(!title_changed.load(Ordering::Relaxed), "the scratch rebuild is no title change");
    let (text, history, ..) = state(&mirror);
    assert_eq!((text, history), live, "the mirror still rebuilds from the kept replay");
}

/// What the park wrote down of the screen is what a look at the live
/// terminal read, and a look it answers builds no scratch terminal: a
/// thousand parked tabs cost a snapshot pass nothing.
#[test]
fn a_look_answered_by_the_park_rebuilds_nothing() {
    let mirrors: Vec<_> = (0..16).map(|_| mirror_with(SCREEN)).collect();
    for (mirror, title_changed) in &mirrors {
        let live = mirror.with_terminal_kept_parked(
            |_| -> Option<Option<u64>> { unreachable!("a live mirror is not parked") },
            |term, look| {
                assert!(look.is_none());
                crate::output_store::snapshot::content_digest(term)
            },
        );
        assert!(live.is_some());
        assert!(park(mirror, title_changed));
        for _ in 0..3 {
            let parked = mirror.with_terminal_kept_parked(
                |look| {
                    assert_eq!(look.size, (20, 4));
                    assert!(!look.alternate && !look.upload);
                    Some(look.digest)
                },
                |_, _| unreachable!("the look answered"),
            );
            assert_eq!(parked, live, "the parked digest is the live one");
        }
        assert_eq!(mirror.scratch_builds(), 0);
        assert!(mirror.is_parked());
    }
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
    // Read the slot without rebuilding it: no terminal at all.
    assert!(mirror.term.lock().unwrap().is_none());
    assert_eq!(mirror.lock().unwrap().scrollback_rows(), rows);
}

#[cfg(unix)]
fn ended_terminal() -> Arc<Surface> {
    Surface::exited_terminal_placeholder(
        7,
        SurfaceOptions { cols: 20, rows: 4, ..SurfaceOptions::default() },
        Weak::new(),
        crate::terminal_host_runtime::TerminalHostIdentity {
            terminal_id: "00000000000040008000000000000007".into(),
            incarnation: "10000000000040008000000000000007".into(),
        },
    )
    .unwrap()
}

/// An ended terminal nobody views drops its parsed screen and last frame;
/// the next lock (a shown tab, an exited attach) gets the same terminal.
#[cfg(unix)]
#[test]
fn an_ended_terminal_parks_its_mirror_until_a_lock() {
    let surface = ended_terminal();
    let pty = surface.as_pty().unwrap();
    {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(SCREEN);
        let generation = pty.render.lock().unwrap().built_generation + 1;
        assert!(pty.build_frame_locked(&mut term, generation, false).unwrap());
    }
    assert!(pty.render.lock().unwrap().latest.is_some());
    let before = state(&pty.term);
    assert!(surface.park_exited_mirror());
    assert!(surface.mirror_parked());
    assert!(pty.render.lock().unwrap().latest.is_none(), "its last frame went with it");
    // Read the slot without rebuilding it: no terminal, so no page pool.
    assert!(pty.term.term.lock().unwrap().is_none());
    assert!(!surface.park_exited_mirror(), "a parked mirror does not park again");
    assert_eq!(before, state(&pty.term));
    assert!(!surface.mirror_parked());
    assert_eq!(pty.term.lock().unwrap().cols(), 20);
}

/// A live terminal is the reader's to park (`park_mirror`), never this.
#[cfg(unix)]
#[test]
fn a_running_terminal_does_not_park_as_ended() {
    let surface = ended_terminal();
    let pty = surface.as_pty().unwrap();
    pty.dead.store(false, Ordering::Release);
    assert!(!surface.park_exited_mirror());
    assert!(!surface.mirror_parked());
}

/// A snapshot bigger than the screen it stands for is not worth parking.
#[test]
fn a_replay_parks_only_when_it_is_the_smaller_copy() {
    let replay = |len: usize| VtReplay { bytes: vec![b'x'; len], ..VtReplay::default() };
    assert!(super::replay_pays(&replay(100), Some(10)), "a small replay beats the page floor");
    assert!(super::replay_pays(&replay(100_000), Some(1_000_000)));
    assert!(!super::replay_pays(&replay(1_000_000), Some(100_000)));
    assert!(!super::replay_pays(&replay(1_000_000), None));
}
