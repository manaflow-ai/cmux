//! The mount helper: `cmux-tui projfs …` (and the small `cmux-projfs` binary, which takes the
//! same arguments after its name).
//!
//! - `mount --mount ID --manifest FILE --at DIR --state DIR [--socket PATH]`: mounts the
//!   projection read-only at `STATE/lower` (FUSE, bytes fetched through the session daemon's
//!   `projfs.fetch`), puts an overlay over it at `DIR` (`sudo -n mount -t overlay`, upper layer
//!   `STATE/upper`), makes git's stat checks fit a projection for the machine's user
//!   (`core.checkStat=minimal`, `core.trustctime=false`, best effort: `git_settings`), prints
//!   one JSON line `{"ok":true,"mount","at","entries","bytes","git","ms"}` (`git`: `set`, `kept`
//!   or `unavailable`) and serves in the foreground until SIGTERM, SIGINT, or `unmount`. A
//!   failure before that line undoes what was done and prints `{"ok":false,"code","message"}`.
//! - `unmount --at DIR --state DIR`: stops the helper serving that state, unmounts the overlay
//!   and the lower (idempotent); the upper layer and the cache stay.
//! - `upper --state DIR`: the overlay's upper layer as a change set (JSON).
//! - `status --state DIR`: the read path's counters the helper last wrote (JSON).
//!
//! Exit codes: 0 done, 1 refused or failed (the JSON line says why), 2 bad arguments, 3 not
//! supported on this platform (only Linux mounts).
//!
//! The helper never needs the Mac to mount: the manifest is local, so listing and `stat` work
//! with no Mac at all; only byte reads wait for it.

#[cfg(target_os = "linux")]
mod daemon;
#[cfg(target_os = "linux")]
mod git_settings;
#[cfg(target_os = "linux")]
mod overlay;
#[cfg(target_os = "linux")]
mod serve;
#[cfg(target_os = "linux")]
mod state;

use std::io::Write;
use std::path::PathBuf;

use serde_json::{Value, json};

/// Exit code: done.
pub const EXIT_OK: i32 = 0;
/// Exit code: refused or failed; the JSON line has the code.
pub const EXIT_FAILED: i32 = 1;
/// Exit code: the arguments are wrong.
pub const EXIT_USAGE: i32 = 2;
/// Exit code: this platform cannot mount a projection.
pub const EXIT_UNSUPPORTED: i32 = 3;

const USAGE: &str =
    "usage: projfs mount --mount ID --manifest FILE --at DIR --state DIR [--socket PATH]
       projfs unmount --at DIR --state DIR
       projfs upper --state DIR
       projfs status --state DIR";

/// A refusal: its stable code and a line for a person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    pub(crate) fn new(code: &'static str, message: impl Into<String>) -> Failure {
        Failure { code, message: message.into() }
    }

    fn line(&self) -> Value {
        json!({ "ok": false, "code": self.code, "message": self.message })
    }
}

/// Runs the helper with the process's stdout; the exit code.
pub fn run(args: &[String]) -> i32 {
    run_with(args, None, &mut std::io::stdout())
}

/// Runs the helper, writing its JSON lines to `out`. `default_socket` is the session daemon's
/// socket when neither `--socket` nor `CMUX_TUI_SOCKET` names one (`cmux-tui` passes its own
/// resolution; the small binary mirrors the plain rule).
pub fn run_with(args: &[String], default_socket: Option<PathBuf>, out: &mut dyn Write) -> i32 {
    let Some((verb, rest)) = args.split_first() else {
        return usage(out, "no command");
    };
    if matches!(verb.as_str(), "-h" | "--help" | "help") {
        let _ = writeln!(out, "{USAGE}");
        return EXIT_OK;
    }
    let opts = match Opts::parse(rest) {
        Ok(opts) => opts,
        Err(why) => return usage(out, &why),
    };
    dispatch(verb, &opts, default_socket, out)
}

#[cfg(target_os = "linux")]
fn dispatch(verb: &str, opts: &Opts, default_socket: Option<PathBuf>, out: &mut dyn Write) -> i32 {
    let result = match verb {
        "mount" => serve::MountArgs::from_opts(opts, default_socket)
            .map(|args| serve::mount(&args, out).map(|()| None)),
        "unmount" => state::Paths::from_opts(opts, true).map(|p| serve::unmount(&p).map(Some)),
        "upper" => state::Paths::from_opts(opts, false).map(|p| state::upper(&p).map(Some)),
        "status" => state::Paths::from_opts(opts, false).map(|p| state::status(&p).map(Some)),
        other => return usage(out, &format!("unknown command {other:?}")),
    };
    let result = match result {
        Ok(result) => result,
        Err(why) => return usage(out, &why),
    };
    match result {
        Ok(None) => EXIT_OK,
        Ok(Some(line)) => {
            print_line(out, &line);
            EXIT_OK
        }
        Err(failure) => {
            print_line(out, &failure.line());
            EXIT_FAILED
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn dispatch(verb: &str, _opts: &Opts, _socket: Option<PathBuf>, out: &mut dyn Write) -> i32 {
    if !matches!(verb, "mount" | "unmount" | "upper" | "status") {
        return usage(out, &format!("unknown command {verb:?}"));
    }
    let failure =
        Failure::new("not_supported", "projected folders are mounted on Linux machines only");
    print_line(out, &failure.line());
    EXIT_UNSUPPORTED
}

pub(crate) fn print_line(out: &mut dyn Write, line: &Value) {
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

fn usage(out: &mut dyn Write, why: &str) -> i32 {
    print_line(out, &Failure::new("usage", format!("{why}\n{USAGE}")).line());
    EXIT_USAGE
}

/// `--name value` pairs, each at most once.
#[derive(Debug, Default)]
pub(crate) struct Opts {
    pairs: Vec<(String, String)>,
}

impl Opts {
    fn parse(args: &[String]) -> Result<Opts, String> {
        let mut opts = Opts::default();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let Some(name) = arg.strip_prefix("--").filter(|n| !n.is_empty()) else {
                return Err(format!("unexpected argument {arg:?}"));
            };
            if !matches!(name, "mount" | "manifest" | "at" | "state" | "socket") {
                return Err(format!("unknown option --{name}"));
            }
            let Some(value) = it.next() else {
                return Err(format!("--{name} needs a value"));
            };
            if opts.get(name).is_some() {
                return Err(format!("--{name} given twice"));
            }
            opts.pairs.push((name.to_owned(), value.clone()));
        }
        Ok(opts)
    }

    pub(crate) fn get(&self, name: &str) -> Option<&str> {
        self.pairs.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }

    pub(crate) fn need(&self, name: &str) -> Result<&str, String> {
        self.get(name).ok_or_else(|| format!("--{name} is required"))
    }

    /// Refuses any option outside `allowed`.
    pub(crate) fn only(&self, allowed: &[&str]) -> Result<(), String> {
        match self.pairs.iter().find(|(n, _)| !allowed.contains(&n.as_str())) {
            Some((n, _)) => Err(format!("--{n} does not apply here")),
            None => Ok(()),
        }
    }
}
