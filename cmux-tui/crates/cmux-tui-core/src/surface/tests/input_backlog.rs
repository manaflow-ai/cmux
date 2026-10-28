//! A terminal whose program does not read its input (H1, audit batch 3).
//!
//! A paste bigger than the PTY's input buffer into a program that never
//! reads must not hold any lock the rest of the terminal needs: a resize,
//! the terminal's output, a later key and every other terminal keep working.
//! Before the per-terminal input queue the paste's blocking write held
//! `pty.runtime` until the program read, and a resize waited for that lock
//! while it held the parser and the terminal lock, so the screen froze.

use super::*;

/// How long each step may take; the bug made them wait forever.
const STEP: Duration = Duration::from_secs(5);

/// Bigger than any PTY input buffer (macOS ~1 KiB queue; Linux's tty
/// buffers stop taking input at a few hundred KiB).
const PASTE_BYTES: usize = 4 * 1024 * 1024;

/// Runs `f` on its own thread and returns its result, or `None` when it did
/// not finish within `limit` (the thread is left behind, stuck).
fn within<R: Send + 'static>(limit: Duration, f: impl FnOnce() -> R + Send + 'static) -> Option<R> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    rx.recv_timeout(limit).ok()
}

fn screen(surface: &Arc<Surface>) -> Option<String> {
    let surface = surface.clone();
    within(STEP, move || {
        surface.try_with_terminal(|term| term.viewport_text()).ok().and_then(Result::ok)
    })
    .flatten()
}

/// The largest `tick-<n>` on `text`.
fn last_tick(text: &str) -> Option<u64> {
    text.split("tick-")
        .skip(1)
        .filter_map(|rest| {
            let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
            digits.parse().ok()
        })
        .max()
}

fn wait_for(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    done()
}

/// Kills the terminal's process group, so a write stuck on its PTY (the bug)
/// ends with EIO and the test process can exit.
struct KillGroup(Option<u32>);

impl Drop for KillGroup {
    fn drop(&mut self) {
        if let Some(pid) = self.0.and_then(|pid| libc::pid_t::try_from(pid).ok()) {
            // SAFETY: signals the group the test's own child leads.
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}

#[test]
fn a_paste_into_a_program_that_does_not_read_never_freezes_resize_output_or_other_terminals() {
    let mux = Mux::new_for_test("input-backlog-freeze", SurfaceOptions::default());
    // Prints a tick every 50 ms and never reads its input.
    let busy = Surface::spawn(
        9_800,
        SurfaceOptions {
            cols: 80,
            rows: 24,
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                "stty -icanon -echo min 1; i=0; while :; do echo tick-$i; i=$((i+1)); sleep 0.05; done"
                    .into(),
            ]),
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .expect("spawn the busy terminal");
    let _kill_busy = KillGroup(busy.process_id());
    // Another terminal: answers one line.
    let other = Surface::spawn(
        9_801,
        SurfaceOptions {
            cols: 80,
            rows: 24,
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                "read line; echo got-$line; sleep 30".into(),
            ]),
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .expect("spawn the other terminal");
    let _kill_other = KillGroup(other.process_id());

    assert!(
        wait_for(STEP, || screen(&busy).and_then(|text| last_tick(&text)).is_some()),
        "the busy terminal never printed"
    );

    // The paste: more than the PTY takes while nothing reads it.
    let paste = vec![b'p'; PASTE_BYTES];
    let pasting = {
        let busy = busy.clone();
        std::thread::spawn(move || busy.write_paste(&paste))
    };
    // Let it fill the PTY's buffers.
    std::thread::sleep(Duration::from_millis(500));

    // A resize finishes.
    let resized = {
        let busy = busy.clone();
        within(STEP, move || busy.resize(100, 30))
    };
    assert!(resized.is_some(), "a resize waited behind the paste's PTY write");
    assert!(resized.unwrap().is_ok(), "the resize failed");

    // The busy terminal's output keeps reaching its screen.
    let before = screen(&busy).and_then(|text| last_tick(&text));
    assert!(before.is_some(), "the busy terminal's screen could not be read after the resize");
    assert!(
        wait_for(STEP, || {
            screen(&busy)
                .and_then(|text| last_tick(&text))
                .is_some_and(|tick| tick > before.unwrap() + 3)
        }),
        "the busy terminal's output stopped after the paste"
    );

    // A key typed after the paste does not wait for the program to read.
    let typed = {
        let busy = busy.clone();
        within(STEP, move || busy.write_bytes(b"x"))
    };
    assert!(typed.is_some(), "a key waited behind the paste");

    // Another terminal still takes input and shows its output.
    let other_typed = {
        let other = other.clone();
        within(STEP, move || other.write_bytes(b"hello\r"))
    };
    assert!(matches!(other_typed, Some(Ok(()))), "the other terminal's input failed or waited");
    assert!(
        wait_for(STEP, || screen(&other).is_some_and(|text| text.contains("got-hello"))),
        "the other terminal stopped working"
    );

    // The paste itself is accepted at once: it waits in the terminal's input
    // queue for the program, not on a thread.
    assert!(
        wait_for(STEP, || pasting.is_finished()),
        "the paste's caller is still blocked on the PTY"
    );
    pasting.join().unwrap().expect("the paste was queued");
}

/// The queued input reaches a program that starts reading later, whole and
/// in order, and input typed after it lands after it.
#[test]
fn queued_input_drains_in_order_when_the_program_reads() {
    let mux = Mux::new_for_test("input-backlog-drain", SurfaceOptions::default());
    let total = PASTE_BYTES + 3;
    let script = format!(
        "stty -icanon -echo min 1; sleep 1; head -c {total} | tail -c 8 | od -An -c; sleep 30"
    );
    let surface = Surface::spawn(
        9_802,
        SurfaceOptions {
            cols: 120,
            rows: 24,
            command: Some(vec!["/bin/sh".into(), "-c".into(), script]),
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .expect("spawn");
    let _kill = KillGroup(surface.process_id());
    std::thread::sleep(Duration::from_millis(200));

    let paste = vec![b'p'; PASTE_BYTES];
    let written = {
        let surface = surface.clone();
        within(STEP, move || {
            surface.write_paste(&paste)?;
            surface.write_bytes(b"END")
        })
    };
    assert!(matches!(written, Some(Ok(()))), "the input was not queued at once: {written:?}");
    // `od -c` of the last 8 of exactly the bytes queued: the paste, then END.
    assert!(
        wait_for(Duration::from_secs(20), || {
            screen(&surface).is_some_and(|text| text.contains("p   p   p   p   p   E   N   D"))
        }),
        "the program never got the whole input in order: {:?}",
        screen(&surface)
    );
}
