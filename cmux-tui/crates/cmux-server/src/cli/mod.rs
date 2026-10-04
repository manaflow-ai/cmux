//! `cmux server …` verbs. The `cmux` binary mounts [`run`] for the `server`
//! noun; the standalone `cmux-server` binary calls it too. Every verb takes
//! `--json`. Exit codes: 0 ok, 1 internal, 2 usage, 3 not found,
//! 4 rejected, 5 owner unreachable or deadline, 6 idempotency conflict,
//! 7 verification failed (signature, checksum, expiry, downgrade).
//!
//! Local verbs are idempotent by construction (an install of the installed
//! manifest is a no-op), so `--idempotency-key` is accepted and needs no
//! replay record here.

pub mod args;
mod db;
mod lifecycle;
mod pair;

use std::io::Write;
use std::process::ExitCode;

use cmux_server_core::layout::LayoutEnv;
use cmux_server_core::manifest::TrustedKey;
use cmux_server_core::reexec::GUARD_ENV;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::exec::{Exec, SystemExec};
use crate::process::{Runner, SystemRunner};
use crate::store::fetch::{Fetch, HttpsFetcher};
use crate::{host, keys};

pub use args::{Args, parse};

/// Everything a verb reads from outside its arguments.
pub struct Context<'a> {
    pub runner: &'a dyn Runner,
    /// `None`: the HTTPS fetcher is built on first use.
    pub fetcher: Option<&'a dyn Fetch>,
    /// Replaces the process for the one re-exec into a newer `cmux`.
    pub exec: &'a dyn Exec,
    pub keys: Vec<TrustedKey>,
    /// The running `cmux` version (manifest `min_cmux_version`).
    pub running_cmux: String,
    /// `CMUX_SERVER_REEXEC` (`reexec::GUARD_ENV`): set when this process is
    /// already the re-exec; it never re-execs again.
    pub reexec_guard: Option<String>,
    pub env: LayoutEnv,
    pub now_ms: u64,
}

impl Context<'_> {
    fn with_fetcher<T>(&self, f: impl FnOnce(&dyn Fetch) -> Result<T>) -> Result<T> {
        match self.fetcher {
            Some(fetcher) => f(fetcher),
            None => f(&HttpsFetcher::new()?),
        }
    }
}

/// The version this binary reports to the manifest check.
pub fn running_version() -> &'static str {
    cmux_server_core::manifest::CMUX_VERSION
}

/// Entry point. `args` excludes the program name and may start with
/// `server`.
pub fn run(args: &[String]) -> ExitCode {
    ExitCode::from(run_code(args, std::env::var(GUARD_ENV).ok(), running_version()))
}

/// [`run`] with the re-exec guard already read (the standalone binary
/// reads it and removes it from its environment before anything starts).
pub fn run_with_guard(args: &[String], guard: Option<String>) -> ExitCode {
    ExitCode::from(run_code(args, guard, running_version()))
}

/// The mount for `cmux server …` in the `cmux` binary: `running_cmux` is
/// that binary's release version (manifest `min_cmux_version`). Returns
/// the exit code.
pub fn run_code(args: &[String], guard: Option<String>, running_cmux: &str) -> u8 {
    let runner = SystemRunner;
    let ctx = Context {
        runner: &runner,
        fetcher: None,
        exec: &SystemExec,
        keys: keys::baked(),
        running_cmux: running_cmux.to_owned(),
        // Only ever stops a re-exec, so the environment cannot widen trust.
        reexec_guard: guard.filter(|v| !v.is_empty()),
        env: host::layout_env(),
        now_ms: host::now_ms(),
    };
    run_with_code(&ctx, args)
}

/// [`run`] with an explicit context (tests).
pub fn run_with(ctx: &Context<'_>, args: &[String]) -> ExitCode {
    ExitCode::from(run_with_code(ctx, args))
}

fn run_with_code(ctx: &Context<'_>, args: &[String]) -> u8 {
    let parsed = match parse(args) {
        Ok(parsed) => parsed,
        Err(e) => return fail(args.iter().any(|a| a == "--json"), &e),
    };
    if parsed.help {
        print!("{}", args::help());
        return 0;
    }
    match dispatch(ctx, &parsed) {
        Ok(Output { json: value, human }) => {
            let mut stdout = std::io::stdout().lock();
            let _ =
                if parsed.json { writeln!(stdout, "{value}") } else { write!(stdout, "{human}") };
            0
        }
        Err(e) => fail(parsed.json, &e),
    }
}

/// Errors go to stderr, as every other `cmux` scope writes them: one JSON
/// object with `--json`, else one human line.
fn fail(json: bool, e: &Error) -> u8 {
    let mut stderr = std::io::stderr().lock();
    let _ = if json {
        let body = json!({"error": {"kind": e.kind.as_str(), "message": e.message}});
        writeln!(stderr, "{body}")
    } else {
        writeln!(stderr, "cmux server: {}", e.message)
    };
    e.kind.code()
}

/// A verb's result: the `--json` object and the human text.
pub struct Output {
    pub json: Value,
    pub human: String,
}

impl Output {
    fn new(json: Value, human: impl Into<String>) -> Output {
        Output { json, human: human.into() }
    }
}

/// Runs one parsed verb.
pub fn dispatch(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let verb: Vec<&str> = args.verb.iter().map(String::as_str).collect();
    match verb.as_slice() {
        ["install"] => lifecycle::install(ctx, args),
        ["uninstall"] => lifecycle::uninstall(ctx, args),
        ["status"] => lifecycle::status(ctx, args),
        ["upgrade"] => lifecycle::upgrade(ctx, args),
        ["rollback"] => lifecycle::rollback(ctx, args),
        ["pin"] => lifecycle::pin(ctx, args),
        ["db", "create"] => db::create(ctx, args),
        ["db", "url"] => db::url(ctx, args),
        ["db", "archive-wal"] => db::archive_wal(ctx, args),
        ["db", "backup"] => db::backup(ctx, args),
        ["health"] => db::health(ctx, args),
        ["pair"] => pair::pair(ctx, args),
        _ => Err(Error::usage(format!("unknown verb: {}", args.verb_str()))),
    }
}
