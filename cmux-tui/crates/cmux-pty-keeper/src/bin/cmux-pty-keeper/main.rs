//! The cmux PTY keeper. It must stay tiny and frozen; read `PROTOCOL.md`
//! before changing anything here.

use std::ffi::{OsStr, OsString};
use std::io::Write;

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

pub struct Launch {
    pub endpoint: OsString,
    pub cols: u16,
    pub rows: u16,
    pub program: OsString,
    pub args: Vec<OsString>,
}

impl Launch {
    fn parse(mut args: impl Iterator<Item = OsString>) -> Result<Self, String> {
        const USAGE: &str =
            "usage: cmux-pty-keeper <endpoint> <cols> <rows> -- <program> [args...]";
        let _argv0 = args.next();
        let endpoint = args.next().ok_or(USAGE)?;
        let mut size = || -> Result<u16, String> {
            let value = args.next().ok_or(USAGE)?;
            match value.to_str().and_then(|text| text.parse().ok()) {
                Some(n) if n > 0 => Ok(n),
                _ => Err(format!("invalid terminal size {value:?}")),
            }
        };
        let cols = size()?;
        let rows = size()?;
        if args.next().as_deref() != Some(OsStr::new("--")) {
            return Err(USAGE.into());
        }
        let program = args.next().ok_or(USAGE)?;
        Ok(Self { endpoint, cols, rows, program, args: args.collect() })
    }
}

/// Writes the single readiness line. Failure to write means the spawner is
/// gone, which the keeper ignores.
pub fn report(line: &str) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
}

fn main() {
    let launch = match Launch::parse(std::env::args_os()) {
        Ok(launch) => launch,
        Err(message) => {
            report(&format!("error {message}"));
            std::process::exit(2);
        }
    };
    #[cfg(unix)]
    unix::run(launch);
    #[cfg(windows)]
    windows::run(launch);
}
