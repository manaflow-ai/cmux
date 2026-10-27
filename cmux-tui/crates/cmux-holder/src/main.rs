//! `cmux-holder --socket PATH`: reads its 32-byte owner token as 64 hex
//! characters and a newline on stdin, binds PATH, writes `ready\n` on stdout
//! and serves until launchd ends it (logout, shutdown) or it has had no
//! terminal and no daemon for a while. It leaves the daemon's session
//! first, and ignores the hang-up, interrupt and termination signals a
//! daemon's exit or a cleanup script would send: only an explicit CLOSE
//! ends a terminal. Each panic appends one line to `holder-panics.jsonl`
//! beside the socket (`cmux_holder::panic_log`).

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    cmux_holder::panic_log::install(&args);
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
