//! A shell's directory report (OSC 7) reaches the public graph off the
//! terminal's output thread. The PTY reader (`surface-<id>-reader`) and the
//! terminal-host reader (`surface-<id>-host`) are echo threads with blocking
//! disallowed (p02-threads 210); the publication is a SQLite workspace
//! registry commit (MQ-13, p02-threads-303). On the reader, the detector's
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
