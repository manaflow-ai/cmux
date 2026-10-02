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

use std::io::Write;
use std::process::ExitCode;

use cmux_server_core::layout::LayoutEnv;
use cmux_server_core::manifest::TrustedKey;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::process::{Runner, SystemRunner};
use crate::store::fetch::{Fetch, HttpsFetcher};
use crate::{host, keys};

pub use args::{Args, parse};

/// Everything a verb reads from outside its arguments.
pub struct Context<'a> {
    pub runner: &'a dyn Runner,
    /// `None`: the HTTPS fetcher is built on first use.
    pub fetcher: Option<&'a dyn Fetch>,
    pub keys: Vec<TrustedKey>,
    /// The running `cmux` version (manifest `min_cmux_version`).
    pub running_cmux: String,
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
    option_env!("CMUX_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// Entry point. `args` excludes the program name and may start with
/// `server`.
pub fn run(args: &[String]) -> ExitCode {
    let runner = SystemRunner;
    let ctx = Context {
        runner: &runner,
        fetcher: None,
        keys: keys::baked(),
        running_cmux: running_version().to_owned(),
        env: host::layout_env(),
        now_ms: host::now_ms(),
    };
    run_with(&ctx, args)
}

/// [`run`] with an explicit context (tests, and the `cmux` binary when it
/// knows its own version).
pub fn run_with(ctx: &Context<'_>, args: &[String]) -> ExitCode {
    let parsed = match parse(args) {
        Ok(parsed) => parsed,
        Err(e) => return fail(args.iter().any(|a| a == "--json"), &e),
    };
    if parsed.help {
        print!("{}", args::help());
        return ExitCode::SUCCESS;
    }
    match dispatch(ctx, &parsed) {
        Ok(Output { json: value, human }) => {
            let mut stdout = std::io::stdout().lock();
            let _ =
                if parsed.json { writeln!(stdout, "{value}") } else { write!(stdout, "{human}") };
            ExitCode::SUCCESS
        }
        Err(e) => fail(parsed.json, &e),
    }
}

fn fail(json: bool, e: &Error) -> ExitCode {
    if json {
        let body = json!({"error": {"kind": e.kind.as_str(), "message": e.message}});
        let _ = writeln!(std::io::stdout(), "{body}");
    }
    let _ = writeln!(std::io::stderr(), "cmux server: {}", e.message);
    ExitCode::from(e.kind.code())
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
        _ => Err(Error::usage(format!("unknown verb: {}", args.verb_str()))),
    }
}
