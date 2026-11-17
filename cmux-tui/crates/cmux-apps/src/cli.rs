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
    let Some((verb, rest)) = words.split_first() else {
        return Err(usage("cmux app: name a verb"));
    };
    let mut json = false;
    let mut positional = vec![];
    let mut values: Vec<(&str, String)> = vec![];
    let mut include_dirty = false;
    let mut iter = rest.iter();
    while let Some(word) = iter.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "--help" | "-h" => return Ok(Parsed { command: Command::Help, json }),
            "--json" => json = true,
            "--include-dirty" => include_dirty = true,
            "--port" | "--cmd" | "--dir" | "--ref" | "--share" | "--to" => {
                let value = match inline {
                    Some(value) => value,
                    None => iter
                        .next()
                        .cloned()
                        .ok_or_else(|| usage(format!("{flag} needs a value")))?,
                };
                values.push((flag, value));
            }
            other if other.starts_with('-') && other.len() > 1 => {
                return Err(usage(format!("unknown option {other}")));
            }
            _ => positional.push(word.clone()),
        }
    }
    let allowed: &[&str] = match verb.as_str() {
        "publish" => &["--port", "--cmd", "--dir", "--ref", "--share"],
        "rollback" => &["--to"],
        "versions" | "ls" => &[],
        "help" => return Ok(Parsed { command: Command::Help, json }),
        other => return Err(usage(format!("unknown verb app {other}"))),
    };
    if let Some((flag, _)) = values.iter().find(|(flag, _)| !allowed.contains(flag)) {
        return Err(usage(format!("app {verb} takes no {flag}")));
    }
    if include_dirty && verb != "publish" {
        return Err(usage(format!("app {verb} takes no --include-dirty")));
    }
    let value =
        |name: &str| values.iter().rev().find(|(flag, _)| *flag == name).map(|(_, v)| v.clone());
    let max_positional = if verb == "ls" { 0 } else { 1 };
    if positional.len() > max_positional {
        return Err(usage(format!("unexpected argument {}", positional[max_positional])));
    }
    let name = positional.into_iter().next();
    let named = |name: Option<String>| name.ok_or_else(|| usage(format!("app {verb} needs NAME")));
    let command = match verb.as_str() {
        "publish" => {
            let port = value("--port")
                .map(|p| {
                    p.parse::<u16>()
                        .ok()
                        .filter(|p| *p != 0)
                        .ok_or_else(|| usage(format!("--port {p} is not a port")))
                })
                .transpose()?;
            let share_team = match value("--share").as_deref() {
                None => false,
                Some("team") => true,
                Some(other) => {
                    return Err(usage(format!("--share {other}: only --share team for now")));
                }
            };
            Command::Publish {
                name,
                port,
                cmd: value("--cmd"),
                dir: value("--dir").map(PathBuf::from),
                git_ref: value("--ref"),
                include_dirty,
                share_team,
            }
        }
        "versions" => Command::Versions { name: named(name)? },
        "rollback" => {
            let to = value("--to")
                .map(|t| {
                    t.trim_start_matches('v')
                        .parse::<u32>()
                        .ok()
                        .filter(|n| *n > 0)
                        .ok_or_else(|| usage(format!("--to {t} is not a version")))
                })
                .transpose()?;
            Command::Rollback { name: named(name)?, to }
        }
        _ => Command::Ls,
    };
    Ok(Parsed { command, json })
}

/// Runs `parsed` on `host`; `cwd` is the caller's working directory.
pub fn run(host: &Host<'_>, parsed: &Parsed, cwd: PathBuf) -> Output {
    let json = parsed.json;
    match &parsed.command {
        Command::Help => Output { stdout: format!("{USAGE}\n"), stderr: String::new(), code: 0 },
        Command::Publish { name, port, cmd, dir, git_ref, include_dirty, share_team } => {
            let mut req = PublishRequest::new(cwd.clone());
            req.name = name.clone();
            req.port = *port;
            req.cmd = cmd.clone();
            req.dir = dir.as_ref().map(|d| if d.is_absolute() { d.clone() } else { cwd.join(d) });
            req.git_ref = git_ref.clone().unwrap_or_else(|| "HEAD".to_owned());
            req.include_dirty = *include_dirty;
            req.share_team = *share_team;
            match publish::publish(host, &req) {
                Ok(done) => {
                    let body = json!({
                        "app": app_json(&done.app),
                        "version": done.version,
                        "url": done.url,
                        "inferred": done.inferred,
                        "warnings": done.warnings,
                    });
                    let mut text = String::new();
                    if let Some(i) = &done.inferred {
                        text.push_str(&format!(
                            "inferred: cd {} && {}\n",
                            i.dir.display(),
                            i.command
                        ));
                    }
                    for w in &done.warnings {
                        text.push_str(&format!("warning: {w}\n"));
                    }
                    let line =
                        format!("published {} v{}: {}\n", done.app.slug, done.version.n, done.url);
                    done_output(json, body, text, line)
                }
                Err(failure) => failed(json, &failure),
            }
        }
        Command::Versions { name } => match load(host, name) {
            Ok(app) => {
                let versions: Vec<&Version> = app.newest_first();
                let mut line = String::new();
                for v in &versions {
                    let live = if app.live == Some(v.n) { " (live)" } else { "" };
                    let short = v.commit.get(..12).unwrap_or(&v.commit);
                    line.push_str(&format!(
                        "v{}\t{}{live}\t{short}\t{}\n",
                        v.n,
                        v.state.word(),
                        v.command
                    ));
                }
                done_output(
                    json,
                    json!({"app": app_json(&app), "versions": versions}),
                    String::new(),
                    line,
                )
            }
            Err(failure) => failed(json, &failure),
        },
        Command::Rollback { name, to } => {
            let slug = slugify(name).unwrap_or_default();
            match publish::rollback(host, &slug, *to, publish::PROBE_TIMEOUT) {
                Ok(done) => {
                    let line = format!(
                        "rolled back {} to v{}: {}\n",
                        done.app.slug, done.version.n, done.url
                    );
                    let body = json!({"app": app_json(&done.app), "version": done.version, "url": done.url});
                    done_output(json, body, String::new(), line)
                }
                Err(failure) => failed(json, &failure),
            }
        }
        Command::Ls => match state::list(host.fs, &host.apps_root) {
            Ok(apps) => {
                let mut line = String::new();
                for app in &apps {
                    let live = app.live.map(|n| format!("v{n}")).unwrap_or_else(|| "-".to_owned());
                    line.push_str(&format!(
                        "{}\t{live}\t{}\n",
                        app.slug,
                        app.url.as_deref().unwrap_or("-")
                    ));
                }
                let items: Vec<Value> = apps.iter().map(app_json).collect();
                done_output(json, json!({"items": items}), String::new(), line)
            }
            Err(e) => failed(json, &Failure { code: "app.state", message: e, version: None }),
        },
    }
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
