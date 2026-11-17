//! `cmux app publish|versions|rollback|ls`: the words after `app`, and what each prints.

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::publish::{self, Failure, Host, PublishRequest};
use crate::slug::slugify;
use crate::state::{self, AppState, Version};

pub const USAGE: &str = "usage: cmux app publish [NAME] [--port P] [--cmd CMD] [--dir DIR] [--ref REF] [--include-dirty] [--share team] [--json]
       cmux app versions NAME [--json]
       cmux app rollback NAME [--to N] [--json]
       cmux app ls [--json]";

/// The verbs this crate owns under `cmux app`.
pub const VERBS: [&str; 4] = ["publish", "versions", "rollback", "ls"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    Help,
    Publish {
        name: Option<String>,
        port: Option<u16>,
        cmd: Option<String>,
        dir: Option<PathBuf>,
        git_ref: Option<String>,
        include_dirty: bool,
        share_team: bool,
    },
    Versions {
        name: String,
    },
    Rollback {
        name: String,
        to: Option<u32>,
    },
    Ls,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parsed {
    pub command: Command,
    pub json: bool,
}

/// What a command prints, and its exit code (0 done, 1 failed, 2 refused usage).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

fn usage(message: impl Into<String>) -> String {
    format!("{}\n{USAGE}", message.into())
}

/// Parses `words`, the arguments after `app` (`publish …`, `ls`, …).
pub fn parse(words: &[String]) -> Result<Parsed, String> {
    unimplemented!("red: parse")
}

/// Runs `parsed` on `host`; `cwd` is the caller's working directory.
pub fn run(host: &Host<'_>, parsed: &Parsed, cwd: PathBuf) -> Output {
    unimplemented!("red: run")
}

fn load(host: &Host<'_>, name: &str) -> Result<AppState, Failure> {
    let slug = slugify(name).unwrap_or_default();
    state::load(host.fs, &host.apps_root, &slug)
        .map_err(|e| Failure { code: "app.state", message: e, version: None })?
        .ok_or_else(|| Failure {
            code: "app.not_found",
            message: format!("no app {slug} was published on this machine"),
            version: None,
        })
}

/// An app's summary without its version list.
fn app_json(app: &AppState) -> Value {
    json!({"name": app.name, "slug": app.slug, "url": app.url, "live": app.live, "versions": app.versions.len()})
}

fn done_output(json: bool, body: Value, stderr: String, line: String) -> Output {
    let stdout = if json { format!("{body}\n") } else { line };
    Output { stdout, stderr, code: 0 }
}

fn failed(json: bool, failure: &Failure) -> Output {
    let code = if failure.is_usage() { 2 } else { 1 };
    if json {
        let body = json!({"error": {"code": failure.code, "message": failure.message}, "version": failure.version});
        return Output { stdout: format!("{body}\n"), stderr: String::new(), code };
    }
    let mut stderr = format!("cmux app: {}\n", failure.message);
    if let Some(tail) =
        failure.version.as_ref().and_then(|v| v.log_tail.as_deref()).filter(|t| !t.is_empty())
    {
        stderr.push_str("--- log tail ---\n");
        stderr.push_str(tail);
        if !tail.ends_with('\n') {
            stderr.push('\n');
        }
    }
    Output { stdout: String::new(), stderr, code }
}

/// A usage refusal from [`parse`], printed the way [`run`] prints a failure.
pub fn usage_output(json: bool, message: &str) -> Output {
    failed(json, &Failure { code: "usage.invalid", message: message.to_owned(), version: None })
}
