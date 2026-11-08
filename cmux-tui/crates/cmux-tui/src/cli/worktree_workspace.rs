//! A git worktree and the workspace that works in it, in one command:
//!
//! - `cmux workspace create --worktree <name> [--repo <path>] [--base <rev>]
//!   [workspace create options]`: `git worktree create` (a new branch
//!   `cmux/<name>` in `~/.cmux/worktrees/<project>/<name>`), then a workspace
//!   whose first terminal starts in it, named `<name>` unless `--name`. The
//!   workspace records the folder as its agent folder
//!   (`workspace.agent_folder.set`), so its agent chats start there and
//!   `close --remove-worktree` knows which worktree is its own. The result
//!   is the `workspace create` result with the worktree result as
//!   `worktree` (`root` is the folder).
//! - `cmux workspace <ws> close --remove-worktree [--discard]`: `git
//!   worktree remove` of the workspace's recorded folder (refused, closing
//!   nothing, with uncommitted or unpushed work unless `--discard`), then the
//!   workspace close. The result is the close result with the removal as
//!   `worktree`.
//!
//! Each step is its own daemon request. With `--idempotency-key` each step's
//! key derives from it, so retrying the whole command after a lost reply
//! replays the steps that ran instead of repeating them; without one the
//! command makes a key and names it in a failure.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::command::{self, CommandPlan, RequestPlan};
use super::mcp::CallFailure;
use super::terminal_talk::send::Daemon;
use super::{GlobalArgs, Surface, UsageError, wire};

/// `Some(exit code)` for `workspace create --worktree` and `workspace <ws>
/// close --remove-worktree`; `None` for any other workspace command (`words`
/// follow `workspace`).
pub(in crate::cli) fn run(global: &GlobalArgs, words: &[String]) -> Option<i32> {
    let options = |words: &[String]| {
        words
            .iter()
            .take_while(|word| *word != "--")
            .any(|word| word == "--worktree" || word.starts_with("--worktree="))
    };
    match words {
        [verb, rest @ ..] if verb == "create" && options(rest) => Some(match parse_create(rest) {
            Ok(create) => create_command(global, &create),
            Err(error) => usage(global, &error),
        }),
        [target, verb, rest @ ..]
            if verb == "close" && rest.iter().any(|word| word == "--remove-worktree") =>
        {
            Some(match parse_close(target, rest) {
                Ok(close) => close_command(global, &close),
                Err(error) => usage(global, &error),
            })
        }
        _ => None,
    }
}

fn usage(global: &GlobalArgs, error: &UsageError) -> i32 {
    super::app::failure("usage.invalid", &format!("cmux: {}", error.0), global.output, 2)
}

/// `workspace create --worktree`, parsed.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct CreateRequest {
    /// The worktree's name (`git worktree create --name`).
    pub name: String,
    /// A path in the repository; `None` is the current directory.
    pub repo: Option<String>,
    pub base: Option<String>,
    /// The `workspace create` words, without the worktree options and
    /// before `--cwd <root>` is added.
    pub workspace_words: Vec<String>,
}

/// Splits the worktree options off `workspace create`'s words.
pub(in crate::cli) fn parse_create(words: &[String]) -> Result<CreateRequest, UsageError> {
    let split = words.iter().position(|word| word == "--").unwrap_or(words.len());
    let (options, argv) = words.split_at(split);
    let mut name = None;
    let mut repo = None;
    let mut base = None;
    let mut rest = Vec::new();
    let mut named = false;
    let mut iter = options.iter();
    while let Some(word) = iter.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let slot = match flag {
            "--worktree" => &mut name,
            "--repo" => &mut repo,
            "--base" => &mut base,
            "--cwd" => {
                return Err(UsageError(
                    "workspace create --worktree starts in the worktree; it takes no --cwd".into(),
                ));
            }
            "--empty" => {
                return Err(UsageError(
                    "workspace create --worktree needs a terminal; it takes no --empty".into(),
                ));
            }
            _ => {
                named |= flag == "--name";
                rest.push(word.clone());
                continue;
            }
        };
        let value = match inline {
            Some(value) => value,
            None => {
                iter.next().cloned().ok_or_else(|| UsageError(format!("{flag} needs a value")))?
            }
        };
        if value.is_empty() {
            return Err(UsageError(format!("{flag} needs a value")));
        }
        *slot = Some(value);
    }
    let name = name.ok_or_else(|| UsageError("--worktree needs a name".into()))?;
    let mut workspace_words = vec!["workspace".to_owned(), "create".to_owned()];
    if !named {
        workspace_words.extend(["--name".to_owned(), name.clone()]);
    }
    workspace_words.extend(rest);
    workspace_words.extend(argv.iter().cloned());
    Ok(CreateRequest { name, repo, base, workspace_words })
}

/// `workspace <ws> close --remove-worktree`, parsed.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct CloseRequest {
    pub target: String,
    pub discard: bool,
}

pub(in crate::cli) fn parse_close(
    target: &str,
    words: &[String],
) -> Result<CloseRequest, UsageError> {
    if matches!(target, "caller" | "current") || target.starts_with('-') {
        return Err(UsageError(
            "workspace close --remove-worktree needs the workspace's ws_ id or name".into(),
        ));
    }
    let mut discard = false;
    for word in words {
        match word.as_str() {
            "--remove-worktree" => {}
            "--discard" => discard = true,
            other => {
                return Err(UsageError(format!(
                    "workspace close --remove-worktree takes only --discard, not {other}"
                )));
            }
        }
    }
    Ok(CloseRequest { target: target.to_owned(), discard })
}

/// One step's daemon key, derived from the command's key.
fn step_key(command_key: &str, step: &str) -> String {
    let mut hash = Sha256::new();
    for part in ["cmux.workspace.worktree.v1", command_key, step] {
        hash.update(part.as_bytes());
        hash.update([0]);
    }
    format!("workspace-worktree-{:x}", hash.finalize())
}

/// A failed step, and the exit code the CLI gives it.
#[derive(Debug)]
pub(in crate::cli) struct StepFailure {
    pub error: Value,
    pub exit: i32,
}

impl StepFailure {
    fn usage(message: impl Into<String>) -> Self {
        Self {
            error: json!({"code": "usage.invalid", "message": message.into(), "details": {},
                          "retryable": false}),
            exit: 2,
        }
    }

    /// `failure` of `step`, naming the command key that retries the whole
    /// command and what the steps before it made.
    fn step(failure: CallFailure, step: &str, command_key: &str, made: Value) -> Self {
        let mut error = failure.error;
        if !error.get("details").is_some_and(Value::is_object) {
            error.set("details", json!({}));
        }
        error.set_path(&["details", "step"], json!(step));
        error.set_path(&["details", "idempotency_key"], json!(command_key));
        if !made.is_null() {
            error.set_path(&["details", "made"], made);
        }
        Self { error, exit: 1 }
    }
}

/// The plan `words` make, with `key` when it is a mutation.
fn plan(words: &[String], key: Option<String>) -> Result<RequestPlan, StepFailure> {
    match command::parse(words, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) if plan.resolve.is_empty() => {
            let mut plan = *plan;
            plan.idempotency_key = key;
            Ok(plan)
        }
        Ok(_) => Err(StepFailure::usage(format!("{} is not a plain request", words.join(" ")))),
        Err(error) => Err(StepFailure::usage(error.0)),
    }
}

fn words(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|part| (*part).to_owned()).collect()
}

fn command_key(global: &GlobalArgs) -> Result<String, StepFailure> {
    match &global.idempotency_key {
        Some(key) => {
            cmux_tui_core::resource::validate_idempotency_key(key)
                .map_err(|error| StepFailure::usage(error.message))?;
            Ok(key.clone())
        }
        None => wire::random_idempotency_key().map_err(|error| StepFailure::usage(error.0)),
    }
}

/// Runs `workspace create --worktree` against `backend`; the result is the
/// workspace create result with the worktree as `worktree`.
pub(in crate::cli) fn create<B: Daemon + ?Sized>(
    backend: &B,
    request: &CreateRequest,
    command_key: &str,
) -> Result<Value, StepFailure> {
    let current = std::env::current_dir()
        .map_err(|error| StepFailure::usage(format!("current directory: {error}")))?;
    let repo = match &request.repo {
        Some(repo) => current.join(repo),
        None => current,
    };
    let mut create = words(&["git", "worktree", "create", "--name", &request.name, "--path"]);
    create.push(repo.to_string_lossy().into_owned());
    if let Some(base) = &request.base {
        create.extend(["--base".to_owned(), base.clone()]);
    }
    let worktree =
        backend
            .request(None, plan(&create, Some(step_key(command_key, "worktree")))?)
            .map_err(|failure| StepFailure::step(failure, "worktree", command_key, Value::Null))?;
    let worktree = worktree.get("value").cloned().unwrap_or(worktree);
    let root = worktree["root"].as_str().unwrap_or_default().to_owned();
    let made = json!({"worktree": worktree});
    let mut workspace_words = request.workspace_words.clone();
    let argv =
        workspace_words.iter().position(|word| word == "--").unwrap_or(workspace_words.len());
    workspace_words.splice(argv..argv, ["--cwd".to_owned(), root.clone()]);
    let mut result = backend
        .request(None, plan(&workspace_words, Some(step_key(command_key, "workspace")))?)
        .map_err(|failure| StepFailure::step(failure, "workspace", command_key, made))?;
    // The workspace's agent folder names its worktree for `close
    // --remove-worktree` (and starts its agent chats there). It must be the
    // canonical folder; `~/.cmux/worktrees` is a link.
    let folder = std::fs::canonicalize(&root).map(|path| path.to_string_lossy().into_owned());
    let workspace_id = created_workspace(&result);
    let recorded = match (folder, workspace_id) {
        (Ok(folder), Some(workspace)) => {
            let mut set = plan(&words(&["workspace", &workspace, "show"]), None)?;
            set.operation = command::WireOperation::Typed(
                cmux_tui_core::resource::ResourceOperation::WorkspaceAgentFolderSet,
            );
            if let Some(params) = set.params.as_object_mut() {
                params.insert("path".into(), json!(folder));
            }
            set.idempotency_key = Some(step_key(command_key, "agent_folder"));
            backend.request(None, set).is_ok()
        }
        _ => false,
    };
    let mut worktree = worktree;
    if let Some(object) = worktree.as_object_mut() {
        object.insert("workspace_folder".into(), json!(recorded));
    }
    if let Some(object) = result.as_object_mut() {
        object.insert("worktree".into(), worktree);
    }
    Ok(result)
}

/// The new workspace's id in a `workspace.create` result.
fn created_workspace(result: &Value) -> Option<String> {
    result.get("value").unwrap_or(result).get("workspace_id")?.as_str().map(str::to_owned)
}

/// Runs `workspace <ws> close --remove-worktree`; the result is the close
/// result with the removal as `worktree`.
pub(in crate::cli) fn close<B: Daemon + ?Sized>(
    backend: &B,
    request: &CloseRequest,
    command_key: &str,
) -> Result<Value, StepFailure> {
    let shown = backend
        .request(None, plan(&words(&["workspace", &request.target, "show"]), None)?)
        .map_err(|failure| StepFailure::step(failure, "show", command_key, Value::Null))?;
    let id = shown["id"].as_str().unwrap_or_default().to_owned();
    let Some(folder) = shown["extra"]["agent_folder"].as_str().map(str::to_owned) else {
        return Err(StepFailure {
            error: json!({
                "code": "worktree.not_recorded",
                "message": format!(
                    "workspace {id} has no worktree folder recorded (workspace create --worktree \
                     records it); remove a worktree with cmux git worktree remove --path <folder>"
                ),
                "details": {"workspace": id},
                "retryable": false,
            }),
            exit: 1,
        });
    };
    let mut remove = words(&["git", "worktree", "remove", "--path", &folder]);
    if request.discard {
        remove.push("--discard".into());
    }
    let removed = backend
        .request(None, plan(&remove, Some(step_key(command_key, "remove")))?)
        .map_err(|failure| StepFailure::step(failure, "remove", command_key, Value::Null))?;
    let removed = removed.get("value").cloned().unwrap_or(removed);
    let made = json!({"worktree": removed});
    let mut result = backend
        .request(
            None,
            plan(&words(&["workspace", &id, "close"]), Some(step_key(command_key, "close")))?,
        )
        .map_err(|failure| StepFailure::step(failure, "close", command_key, made))?;
    if let Some(object) = result.as_object_mut() {
        object.insert("worktree".into(), removed);
    }
    Ok(result)
}

fn finish(global: &GlobalArgs, outcome: Result<Value, StepFailure>, warn: impl Fn(&Value)) -> i32 {
    match outcome {
        Ok(result) => {
            warn(&result);
            wire::print_local_success(&result, global.output)
        }
        Err(failure) => wire::print_local_error(&failure.error, global.output, failure.exit),
    }
}

fn create_command(global: &GlobalArgs, request: &CreateRequest) -> i32 {
    let backend = super::mcp::cli_backend(global.clone());
    let outcome = command_key(global).and_then(|key| create(&backend, request, &key));
    finish(global, outcome, |result| {
        if result["worktree"]["workspace_folder"] == false {
            eprintln!(
                "cmux: the workspace did not record its worktree folder; close it with \
                 cmux git worktree remove --path <root>, then cmux workspace <ws> close"
            );
        }
    })
}

fn close_command(global: &GlobalArgs, request: &CloseRequest) -> i32 {
    let backend = super::mcp::cli_backend(global.clone());
    let outcome = command_key(global).and_then(|key| close(&backend, request, &key));
    finish(global, outcome, |_| {})
}

#[cfg(test)]
#[path = "worktree_workspace_tests.rs"]
mod tests;
