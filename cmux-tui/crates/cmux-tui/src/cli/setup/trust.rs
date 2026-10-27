//! `cmux setup trust [FOLDER] [--level L] [--dry-run]`: records the person's
//! trust for a folder in acpmux's own record (`acpmux::trust`), the answer
//! the agent pane's Trust question and the trust gate read.
//!
//! It goes through the running acpmux daemon when there is one, so a
//! sub-session waiting on the folder's Trust card goes on at once
//! (`acp.trust.set`); without a daemon it writes the same record itself.
//! Claude Code's and Codex's own files keep their one writer: this never
//! touches them. The record already holding the level is "ok" and writes
//! nothing; `undo` names the level the record held before.
//!
//! A linked worktree, or any folder in a repository, takes the record made
//! for its worktree's root or its repository's (`via` in `acp.trust.get`).
//! That answer already holding the level is "ok" too; forgetting it forgets
//! it there, as the pane's Undo does, so every worktree of the repository
//! asks again. `written` names the folder whose record changed.

use std::path::{Path, PathBuf};

use acpmux::trust::{self, Level, Paths};
use serde_json::{Value, json};

use super::{Outcome, Refusal};

const TASK: &str = "trust";

struct Request {
    folder: String,
    level: Level,
    dry_run: bool,
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let paths = paths()?;
    let folder = trust::normalize_cwd(&request.folder).map_err(Refusal::Usage)?;
    let before = recorded(&paths, &folder)?;
    let current = read(&paths, &folder)?;
    let wanted = (request.level != Level::Unknown).then_some(request.level);
    // The folder whose record answers for this one, when it is not this
    // folder's own, and the level it holds.
    let via = current["via"].as_str().map(str::to_owned);
    let held = match via {
        Some(_) => current["level"].as_str().and_then(Level::parse),
        None => before,
    };
    // Forgetting an inherited answer forgets it where it was made; anything
    // else is this folder's own record.
    let (written, old) = match (&via, wanted) {
        (Some(via), None) => (via.clone(), held),
        _ => (folder.clone(), before),
    };
    let undo = command(&written, old.unwrap_or(Level::Unknown));
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "dry_run": request.dry_run,
        "folder": folder,
        "level": request.level.as_str(),
        "recorded": before.map(Level::as_str),
        "via": via,
        "before": current,
        "after": Value::Null,
        "written": Value::Null,
        "through": Value::Null,
        "undo": Value::Null,
        "user_action": Value::Null,
    });
    if held == wanted {
        report["state"] = json!("ok");
        report["after"] = report["before"].clone();
        return Ok(Outcome { report, failed: false });
    }
    report["written"] = json!(written);
    if request.dry_run {
        report["state"] = json!("planned");
        report["undo"] = json!(undo);
        return Ok(Outcome { report, failed: false });
    }
    let through = write(&paths, &written, request.level)?;
    let after = read(&paths, &folder)?;
    report["state"] = json!("changed");
    report["after"] = after;
    report["through"] = json!(through);
    report["undo"] = json!(undo);
    Ok(Outcome { report, failed: false })
}

/// The trust check `cmux setup status` reports: this folder's answer.
pub(super) fn status() -> Result<Value, Refusal> {
    let paths = paths()?;
    let here = std::env::current_dir()
        .map_err(|error| Refusal::Failed(format!("cmux: setup: no current folder: {error}")))?;
    let folder = trust::normalize_cwd(&here.to_string_lossy()).map_err(Refusal::Usage)?;
    let recorded = recorded(&paths, &folder)?;
    let answer = read(&paths, &folder)?;
    let level = answer["level"].as_str().unwrap_or("unknown").to_owned();
    Ok(json!({
        "task": TASK,
        "state": if level == "unknown" { "needs_setup" } else { "ok" },
        "folder": folder,
        "level": level,
        "recorded": recorded.map(Level::as_str),
        "answer": answer,
        "fix": (level == "unknown").then(|| command(&folder, Level::Trusted)),
    }))
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut folder = None;
    let mut level = Level::Trusted;
    let mut dry_run = false;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--level" => {
                let value = args.next().ok_or_else(|| {
                    Refusal::Usage(
                        "cmux: setup trust: --level needs trusted, untrusted or unknown".into(),
                    )
                })?;
                level = Level::parse(value).ok_or_else(|| {
                    Refusal::Usage(format!(
                        "cmux: setup trust: --level must be trusted, untrusted or unknown, got {value:?}"
                    ))
                })?;
            }
            flag if flag.starts_with('-') => {
                return Err(Refusal::Usage(format!("cmux: setup trust: unknown option {flag:?}")));
            }
            path if folder.is_none() => folder = Some(path.to_owned()),
            extra => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup trust: unexpected argument {extra:?}; give one folder"
                )));
            }
        }
    }
    let folder = absolute(Path::new(folder.as_deref().unwrap_or(".")))?;
    Ok(Request { folder: folder.to_string_lossy().into_owned(), level, dry_run })
}

/// `path` against the current folder when it is relative.
fn absolute(path: &Path) -> Result<PathBuf, Refusal> {
    if path.is_absolute() {
        return Ok(path.to_owned());
    }
    std::env::current_dir()
        .map(|here| here.join(path))
        .map_err(|error| Refusal::Failed(format!("cmux: setup trust: no current folder: {error}")))
}

/// The files acpmux reads, at the home `cmux acp` uses.
fn paths() -> Result<Paths, Refusal> {
    crate::acp::configure_home();
    Paths::current().ok_or_else(|| Refusal::Failed("cmux: setup trust: no home directory".into()))
}

/// The level acpmux's record holds for `folder`, None without an entry: read as acpmux reads
/// it (`trust::person_decision`), so a decision recorded under another spelling of the folder
/// counts, and Undo forgets it.
fn recorded(paths: &Paths, folder: &str) -> Result<Option<Level>, Refusal> {
    trust::person_decision(paths, folder).map_err(failure)
}

/// `acp.trust.get`'s answer for `folder`.
fn read(paths: &Paths, folder: &str) -> Result<Value, Refusal> {
    trust::get(paths, folder).map_err(failure)
}

/// Records `level` for `folder`: through the running daemon when there is
/// one (it wakes what waits on the folder), else in the record itself.
/// Answers which way it went.
fn write(paths: &Paths, folder: &str, level: Level) -> Result<&'static str, Refusal> {
    let params = json!({"cwd": folder, "level": level.as_str()});
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| Refusal::Failed(format!("cmux: setup trust: {error}")))?;
    let through_daemon = runtime.block_on(async {
        let client = acpmux::deliver::connect().await.ok()?;
        Some(client.request(acpmux::rpc::method::ACP_TRUST_SET, params).await)
    });
    match through_daemon {
        Some(Ok(_)) => Ok("daemon"),
        Some(Err(error)) => {
            Err(Refusal::Failed(format!("cmux: setup trust: acpmux refused: {error:#}")))
        }
        None => trust::set(paths, folder, level.as_str()).map(|_| "record").map_err(failure),
    }
}

fn failure(failure: trust::Failure) -> Refusal {
    match failure {
        trust::Failure::Invalid(message) => Refusal::Usage(format!("cmux: setup trust: {message}")),
        trust::Failure::Record(message) => Refusal::Failed(format!("cmux: setup trust: {message}")),
    }
}

/// The command that records `level` for `folder`.
fn command(folder: &str, level: Level) -> String {
    format!(
        "cmux setup trust {} --level {}",
        super::super::fix_command::quote_arg(folder),
        level.as_str()
    )
}
