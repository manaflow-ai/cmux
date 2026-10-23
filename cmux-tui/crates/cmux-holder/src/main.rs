//! `cmux-holder --socket PATH`: reads its 32-byte owner token as 64 hex
//! characters and a newline on stdin, binds PATH, writes `ready\n` on stdout
//! and serves until it is killed. It leaves the daemon's session first, and
//! ignores the hang-up, interrupt and termination signals a daemon's exit or
//! a cleanup script would send: only an explicit CLOSE ends a terminal.

use std::io::{BufRead, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-holder: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn run() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let mut socket = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" => socket = args.next().map(PathBuf::from),
            other => return Err(invalid(&format!("unknown argument {other}"))),
        }
    }
    let socket = socket.ok_or_else(|| invalid("--socket PATH is required"))?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let token = parse_token(line.trim()).ok_or_else(|| invalid("bad token on stdin"))?;

    // SAFETY: plain process-wide calls at startup, before any thread exists.
    unsafe {
        libc::setsid();
        for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGTERM, libc::SIGPIPE, libc::SIGQUIT] {
            libc::signal(signal, libc::SIG_IGN);
        }
    }
    // A socket file nobody listens on is a dead holder's; a live one is not
    // ours to take.
    if socket.exists() {
        if UnixStream::connect(&socket).is_ok() {
            return Err(invalid("another holder serves this socket"));
        }
        std::fs::remove_file(&socket)?;
    }
    let listener = UnixListener::bind(&socket)?;
    let mut holder = cmux_holder::holder::Holder::new(listener, token)?;
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(b"ready\n")?;
    stdout.flush()?;
    drop(stdout);
    // Stdio no longer leads anywhere the holder needs.
    // SAFETY: replaces fds 0-2 with /dev/null at startup.
    unsafe {
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if null >= 0 {
            libc::dup2(null, 0);
            libc::dup2(null, 1);
            libc::dup2(null, 2);
            if null > 2 {
                libc::close(null);
            }
        }
    }
    holder.run()
}

fn parse_token(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut token = [0u8; 32];
    for (index, byte) in token.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(index * 2..index * 2 + 2)?, 16).ok()?;
    }
    Some(token)
}

fn invalid(message: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidInput, message.to_string())
}
