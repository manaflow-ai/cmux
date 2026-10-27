//! `cmux-holder --socket PATH`: reads its 32-byte owner token as 64 hex
//! characters and a newline on stdin, binds PATH, writes `ready\n` on stdout
//! and serves until launchd ends it (logout, shutdown) or it has had no
//! terminal and no daemon for a while. It leaves the daemon's session
//! first, and ignores the hang-up, interrupt and termination signals a
//! daemon's exit or a cleanup script would send: only an explicit CLOSE
//! ends a terminal.

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    // The black box first (p09-observability-095), in the holder-lifetime
    // directory beside its socket; the file opens on a one-shot thread.
    if let Some(dir) = cmux_holder::blackbox_dir(&args) {
        drop(cmux_trace::init_blackbox(dir, cmux_trace::Role::Holder));
    }
    // Chromium's SetCurrentTaskDefaultRole: echo is on a person's input path.
    if let Err(error) = cmux_threads::process_role::set_default_role() {
        eprintln!("cmux-holder: {error}");
    }
    match cmux_holder::serve(&args) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-holder: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(not(unix))]
fn main() {}
