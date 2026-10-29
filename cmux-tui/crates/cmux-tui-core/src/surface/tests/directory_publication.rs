//! A shell's directory report (OSC 7) reaches the public graph off the
//! terminal's output thread. The PTY reader (`surface-<id>-reader`) and the
//! terminal-host reader (`surface-<id>-host`) are echo threads with blocking
//! disallowed (p02-threads 210); the publication is a SQLite workspace
//! registry commit (MQ-13). On the reader, the detector's
//! panic mode (the Debug default) panicked it while it held the registry
//! and state locks: the terminal stopped reading and every later user of
//! those locks panicked on the poison.

use super::*;

const WAIT: Duration = Duration::from_secs(10);

fn wait_until(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        cmux_threads::checked::sync::sleep(Duration::from_millis(10));
    }
}

#[cfg(unix)]
#[test]
fn a_reported_directory_is_published_and_the_reader_keeps_reading_in_panic_mode() {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let script = "printf '\\033]7;file://localhost/usr\\007'; sleep 0.5; \
                  printf 'after-cwd-report'; exec cat";
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new(format!("directory-off-reader-{}", std::process::id()), options);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    wait_until("the reported directory is the terminal's published directory", || {
        surface.published_directory().as_deref() == Some("/usr")
    });
    wait_until("the reader shows the output after the report", || {
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .and_then(Result::ok)
            .is_some_and(|text| text.contains("after-cwd-report"))
    });
    // The registry is still usable from another thread: nothing poisoned it.
    assert!(mux.terminal_registry_revision().is_ok());
    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
}

/// The reader is the last to see a terminal end when a background child
/// still holds the PTY after the shell exited: the reaper records the exit
/// first, and the reader's EOF publishes it. That publication is a registry
/// commit (exit_state.rs), which the reader, an echo thread with blocking
/// disallowed, may not make: in panic mode it panicked and the exit was
/// never published.
#[cfg(unix)]
#[test]
fn an_exit_the_reader_sees_last_is_published_in_panic_mode() {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "(sleep 0.5) & exit 0".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new(format!("exit-off-reader-{}", std::process::id()), options);
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let deadline = Instant::now() + WAIT;
    let exited = loop {
        if events
            .try_iter()
            .any(|event| matches!(event, MuxEvent::SurfaceExited(id, _) if id == surface.id))
        {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        cmux_threads::checked::sync::sleep(Duration::from_millis(10));
    };
    assert!(exited, "the terminal's exit is published once its reader sees the end");
    assert!(mux.terminal_registry_revision().is_ok(), "nothing poisoned the registry");
    mux.shutdown();
}

/// A program's desktop notification (OSC 9) is posted off the reader too:
/// the post records it in the registry and reads the terminal's foreground
/// process from the system, which the reader may not do. In panic mode the
/// reader panicked at the post and the notification never arrived.
#[cfg(unix)]
#[test]
fn a_terminal_notification_is_posted_and_the_reader_keeps_reading_in_panic_mode() {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let script = "printf '\\033]9;nine\\007'; sleep 0.3; printf 'after-notification'; exec cat";
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new(format!("notification-off-reader-{}", std::process::id()), options);
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let deadline = Instant::now() + WAIT;
    let note = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "the terminal's notification was never posted");
        if let Ok(MuxEvent::Notification(note)) = events.recv_timeout(left) {
            break note;
        }
    };
    assert_eq!((note.title.as_str(), note.surface), ("nine", Some(surface.id)));
    wait_until("the reader shows the output after the notification", || {
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .and_then(Result::ok)
            .is_some_and(|text| text.contains("after-notification"))
    });
    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
}

/// A local terminal's registry publication runs on its publication
/// sequence at every load. It ran as a job of the terminal work pool, and
/// with that pool full the read worker ran it inline (`will_block`, which
/// frees the worker's slot but still disallows blocking): in panic mode the
/// reader panicked at the SQLite commit, exactly under load, and the
/// directory never reached the graph. A hosted terminal's publication
/// already took the sequence; now both take the one path.
#[cfg(unix)]
#[test]
fn publication_sequence_a_directory_report_with_the_terminal_pool_full_is_published_in_panic_mode()
{
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let script = "sleep 0.5; printf '\\033]7;file://localhost/usr\\007'; sleep 0.3; \
                  printf 'after-full-pool-report'; exec cat";
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new(format!("directory-pool-full-{}", std::process::id()), options);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let full = mux.fill_terminal_work_for_test();
    wait_until("the reported directory is the terminal's published directory", || {
        surface.published_directory().as_deref() == Some("/usr")
    });
    wait_until("the reader shows the output after the report", || {
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .and_then(Result::ok)
            .is_some_and(|text| text.contains("after-full-pool-report"))
    });
    drop(full);
    assert!(mux.terminal_registry_revision().is_ok());
    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
}
