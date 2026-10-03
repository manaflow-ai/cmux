//! What `git.commit` and `git.push` share: the repository a request names
//! and its identity for the mutation ledger, one lock per repository and
//! operation, refusals with a machine reason, and the hooks a run may start.
//!
//! A mutation is keyed: a retry with the same key replays the first result,
//! the same key with other arguments is `idempotency.conflict`, and a key
//! whose target now resolves to another repository or worktree is
//! `repository_changed`. The identity is the canonical common git directory
//! and the worktree's own git directory, so a key never follows a path to
//! another repository.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use serde_json::{Map, Value, json};

use super::checkpoint::ledger::{self, Identity};
use super::run::GitFailure;
use super::user_run::{DEADLINE, MAX_STDERR_BYTES, run_user_git};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

/// A resolved mutation target.
pub(super) struct Target {
    pub repository: Repository,
    common_dir: PathBuf,
    git_dir: PathBuf,
}

impl Target {
    pub(super) fn resolve(
        mux: &Arc<Mux>,
        request: &ParsedResourceRequest,
        operation: &'static str,
    ) -> Result<Self, ResourceError> {
        let directory = super::target::directory(mux, request, operation).map_err(normalized)?;
        let repository = Repository::open(&directory, operation).map_err(normalized)?;
        let arguments = ["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"];
        let output = repository
            .run(&arguments, MAX_SMALL_OUTPUT_BYTES)
            .map_err(|failure| read_failed(operation, &failure))?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut lines = text.lines();
        let (Some(common_dir), Some(git_dir)) = (lines.next(), lines.next()) else {
            let message = "git did not name the repository's directories";
            return Err(refused(operation, "git_failed", message, Value::Null));
        };
        let canonical = |path: &str| {
            fs::canonicalize(path).map_err(|error| {
                refused(operation, "git_failed", format!("{path}: {error}"), Value::Null)
            })
        };
        Ok(Self { common_dir: canonical(common_dir)?, git_dir: canonical(git_dir)?, repository })
    }

    /// The worktree's own git directory, where in-progress state lives.
    pub(super) fn git_dir(&self) -> &Path {
        &self.git_dir
    }

    /// The request's operation, normalized arguments and resolved identity.
    pub(super) fn fingerprint(&self, request: &ParsedResourceRequest) -> Value {
        let selectors = serde_json::to_value(&request.selectors).unwrap_or(Value::Null);
        let fields = Value::Object(request.fields.clone());
        let operation = request.envelope.operation.wire_name();
        let common_dir = self.common_dir.to_string_lossy();
        let git_dir = self.git_dir.to_string_lossy();
        let identity = Identity { repository_id: &common_dir, worktree_id: &git_dir };
        ledger::fingerprint(operation, &selectors, &fields, &identity)
    }

    /// Runs `body` while no other `operation` runs in this repository. A
    /// retry of a running request waits here and then replays its result.
    pub(super) fn exclusive<T>(&self, operation: &'static str, body: impl FnOnce() -> T) -> T {
        type Locks = Mutex<HashMap<(PathBuf, &'static str), Arc<Mutex<()>>>>;
        static LOCKS: OnceLock<Locks> = OnceLock::new();
        let lock = LOCKS
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry((self.common_dir.clone(), operation))
            .or_default()
            .clone();
        let _held = lock.lock().unwrap_or_else(PoisonError::into_inner);
        body()
    }
}

/// The key a catalog-validated mutation carries.
pub(super) fn key(request: &ParsedResourceRequest) -> String {
    request.envelope.idempotency_key.clone().expect("catalog-validated mutations have a key")
}

/// `operation.failed` with the machine `reason` and the explanation in
/// `extra.message`, beside the object `extra` fields.
pub(super) fn refused(
    operation: &str,
    reason: &str,
    message: impl Into<String>,
    extra: Value,
) -> ResourceError {
    let mut extra = match extra {
        Value::Object(fields) => fields,
        _ => Map::new(),
    };
    extra.insert("message".into(), Value::String(message.into()));
    ResourceError::operation_failed(operation, reason, Value::Object(extra))
}

/// A read-runner failure: always `git_failed`.
pub(super) fn read_failed(operation: &str, failure: &GitFailure) -> ResourceError {
    refused(operation, "git_failed", failure.reason(), Value::Null)
}

/// A user run that did not finish: `timed_out` past the deadline, else
/// `git_failed`.
pub(super) fn run_failed(operation: &str, failure: &GitFailure) -> ResourceError {
    match failure {
        GitFailure::TimedOut => refused(
            operation,
            "timed_out",
            format!("git did not finish within {} s and was stopped", DEADLINE.as_secs()),
            Value::Null,
        ),
        other => refused(operation, "git_failed", other.reason(), Value::Null),
    }
}

/// `extra.output`: what git and its hooks printed, cut at 16 KiB.
pub(super) fn output_extra(output: &str) -> Value {
    let output = output.trim();
    let mut end = output.len().min(MAX_STDERR_BYTES);
    while !output.is_char_boundary(end) {
        end -= 1;
    }
    json!({"output": &output[..end]})
}

/// Rewrites a shared git refusal that carries its reason in `extra.code`
/// (target and repository failures) into the mutation shape, with the
/// machine reason in `details.reason`.
pub(super) fn normalized(error: ResourceError) -> ResourceError {
    if error.code != "operation.failed" {
        return error;
    }
    let details = &error.details;
    let (Some(code), Some(operation)) =
        (details["extra"]["code"].as_str(), details["operation"].as_str())
    else {
        return error;
    };
    let mut extra = details["extra"].clone();
    if let Some(fields) = extra.as_object_mut() {
        fields.remove("code");
    }
    let message = details["reason"].as_str().unwrap_or(code).to_string();
    refused(operation, code, message, extra)
}

/// The hooks among `names` that git would run in `root`: present and
/// executable in the effective hooks directory (`core.hooksPath` or the
/// repository's own).
pub(super) fn active_hooks(root: &Path, names: &[&str]) -> Vec<String> {
    let mut arguments = vec!["rev-parse".to_string()];
    for name in names {
        arguments.extend(["--git-path".to_string(), format!("hooks/{name}")]);
    }
    let Ok(run) = run_user_git(root, &arguments) else { return Vec::new() };
    if !run.success {
        return Vec::new();
    }
    let stdout = String::from_utf8_lossy(&run.stdout).into_owned();
    names
        .iter()
        .zip(stdout.lines())
        .filter(|(_, path)| executable(&root.join(path)))
        .map(|(name, _)| (*name).to_string())
        .collect()
}

fn executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else { return false };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        metadata.is_file()
    }
}
