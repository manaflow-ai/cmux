//! `git.checkpoint.create|get|list|pin|unpin`: immutable repository
//! checkpoints the session host captures without changing HEAD, the index or
//! the worktree, published as `refs/cmux/checkpoints/<worktree>/<id>`.
//! Mutations are serialized by one per-session lock and recorded in the
//! session's `resource_mutations` ledger, bound to their arguments and the
//! repository and worktree their target resolved to. Reads take no lock.

mod capture;
mod ledger;
mod reads;
mod record;
mod refs;
mod scan;
mod store;

/// Test seams for failures a test cannot otherwise time.
#[cfg(test)]
pub(super) mod seams {
    use std::cell::{Cell, RefCell};

    thread_local! {
        /// Stops a create right after its ref is published, as a crash would.
        pub static CRASH_AFTER_PUBLISH: Cell<bool> = const { Cell::new(false) };
        /// Runs after a capture hashed its files and before it verifies them.
        pub static AFTER_HASHING: RefCell<Option<Box<dyn Fn()>>> = const { RefCell::new(None) };
    }
}

use std::sync::Arc;

use serde_json::{Map, Value, json};

use super::Repository;
use super::write_run::WriteGit;
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use capture::{Include, Request, Stamp};
use ledger::Identity;
use record::{Checkpoint, Limits, Pin, Stored, now_ms, rfc3339};
use scan::{Layout, refused};
use store::{Pending, Store, io_failed, mint};

/// Pin ids with these prefixes belong to the handoff and restore owners.
const MANAGED_PINS: [&str; 2] = ["handoff:", "restore:"];

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitCheckpointCreate
            | ResourceOperation::GitCheckpointGet
            | ResourceOperation::GitCheckpointList
            | ResourceOperation::GitCheckpointPin
            | ResourceOperation::GitCheckpointUnpin
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation.wire_name();
    let store = Store::open(mux, operation)?;
    let result = match request.envelope.operation {
        ResourceOperation::GitCheckpointCreate => create(mux, &store, &request),
        ResourceOperation::GitCheckpointGet => reads::get(mux, &store, &request),
        ResourceOperation::GitCheckpointList => reads::list(mux, &store, &request),
        ResourceOperation::GitCheckpointPin | ResourceOperation::GitCheckpointUnpin => {
            pin(mux, &store, &request)
        }
        other => unreachable!("checkpoint does not handle {other:?}"),
    };
    result.map_err(scan::normalized)
}

/// The repository a request names, with its git directories and ids.
struct Target {
    repository: Repository,
    layout: Layout,
    repository_id: String,
    worktree_id: String,
}

impl Target {
    fn identity(&self) -> Identity<'_> {
        Identity { repository_id: &self.repository_id, worktree_id: &self.worktree_id }
    }
}

/// Resolves the request's target and its ids. With `mint`, the first sight
/// of a repository or worktree mints its ids; without, an unseen one is
/// `None`.
fn target(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
    operation: &'static str,
    mint: bool,
) -> Result<Option<Target>, ResourceError> {
    let directory = super::target::directory(mux, request, operation)?;
    let repository = Repository::open(&directory, operation)?;
    let layout = Layout::locate(&repository, operation)?;
    let ids = if mint {
        store.identify(&layout.common_dir, &layout.git_dir).map(Some)
    } else {
        store.known(&layout.common_dir, &layout.git_dir)
    };
    let ids = ids.map_err(|error| io_failed(operation, &error))?;
    Ok(ids.map(|(repository_id, worktree_id)| Target {
        repository,
        layout,
        repository_id,
        worktree_id,
    }))
}

/// [`target`], minting ids: what every mutation resolves.
fn resolved(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
    operation: &'static str,
) -> Result<Target, ResourceError> {
    Ok(target(mux, store, request, operation, true)?.expect("minting resolves ids"))
}

fn writer<'a>(target: &'a Target, hooks: &'a std::path::Path) -> WriteGit<'a> {
    WriteGit { root: &target.repository.root, overrides: &target.repository.overrides, hooks }
}

/// The request's operation, normalized arguments and resolved identity.
fn fingerprint(request: &ParsedResourceRequest, target: &Target) -> Value {
    let selectors = serde_json::to_value(&request.selectors).unwrap_or(Value::Null);
    let fields = Value::Object(request.fields.clone());
    let operation = request.envelope.operation.wire_name();
    ledger::fingerprint(operation, &selectors, &fields, &target.identity())
}

fn mutation_key(request: &ParsedResourceRequest) -> String {
    request.envelope.idempotency_key.clone().expect("catalog-validated mutations have a key")
}

fn create(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.create";
    let key = mutation_key(request);
    let arguments = parse_create(&request.fields)?;
    store.exclusive(|| {
        let target = resolved(mux, store, request, OPERATION)?;
        let fingerprint = fingerprint(request, &target);
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        expect_identity(&request.fields, &target)?;
        let hooks = store.hooks();
        let git = writer(&target, &hooks);
        if let Some(reply) = resume(mux, store, &git, &key, &fingerprint)? {
            return Ok(reply);
        }
        refs::sweep(store, &git, &target.repository_id, &target.worktree_id);
        let stored = capture(store, &git, &target, &arguments)?;
        let pending = Pending { idempotency_key: key.clone(), fingerprint, draft: stored.clone() };
        // Journal the intent first: a retry after a crash finds the ref.
        store.journal(&pending).map_err(|error| io_failed(OPERATION, &error))?;
        refs::publish(&git, &stored, OPERATION)?;
        #[cfg(test)]
        if seams::CRASH_AFTER_PUBLISH.with(|crash| crash.replace(false)) {
            return Err(refused(OPERATION, "store_failed", "simulated crash", Value::Null));
        }
        let reply = finish(mux, store, &pending, false)?;
        refs::prune(store, &git, &target.repository_id);
        Ok(reply)
    })
}

/// A create journaled under this key: finished now when its ref was
/// published for these arguments, else dropped so the key captures again.
fn resume(
    mux: &Arc<Mux>,
    store: &Store,
    git: &WriteGit<'_>,
    key: &str,
    fingerprint: &Value,
) -> Result<Option<Value>, ResourceError> {
    const OPERATION: &str = "git.checkpoint.create";
    let Some(pending) = store.pending(key).map_err(|error| io_failed(OPERATION, &error))? else {
        return Ok(None);
    };
    if &pending.fingerprint == fingerprint && refs::published(git, &pending.draft) {
        return finish(mux, store, &pending, true).map(Some);
    }
    store.finish_pending(key).map_err(|error| io_failed(OPERATION, &error))?;
    Ok(None)
}

/// Saves a published create's record, commits it to the mutation ledger and
/// clears its journal entry.
fn finish(
    mux: &Arc<Mux>,
    store: &Store,
    pending: &Pending,
    replayed: bool,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.create";
    store.save(&pending.draft).map_err(|error| io_failed(OPERATION, &error))?;
    let value = serde_json::to_value(&pending.draft.record).expect("records serialize");
    let key = &pending.idempotency_key;
    let reply = ledger::commit(mux, key, OPERATION, &pending.fingerprint, &value, replayed)?;
    // A leftover entry only costs a lookup: the ledger now answers the key.
    let _ = store.finish_pending(key);
    Ok(reply)
}

/// Captures the target and returns its record, unpublished.
fn capture(
    store: &Store,
    git: &WriteGit<'_>,
    target: &Target,
    arguments: &CreateArguments,
) -> Result<Stored, ResourceError> {
    const OPERATION: &str = "git.checkpoint.create";
    let checkpoint_id = mint("ckpt");
    let created_at_ms = now_ms();
    let created_at = rfc3339(created_at_ms);
    let scratch = store.scratch().map_err(|error| io_failed(OPERATION, &error))?;
    let stamp = Stamp {
        checkpoint_id: &checkpoint_id,
        repository_id: &target.repository_id,
        worktree_id: &target.worktree_id,
        created_at: &created_at,
        reason: &arguments.reason,
    };
    let captured = capture::capture(
        git,
        &target.repository,
        &target.layout,
        &scratch,
        &arguments.request,
        &stamp,
        OPERATION,
    )?;
    drop(scratch);
    let mut stored = Stored {
        record: Checkpoint {
            reference: format!("refs/cmux/checkpoints/{}/{checkpoint_id}", target.worktree_id),
            checkpoint_id,
            repository_id: target.repository_id.clone(),
            worktree_id: target.worktree_id.clone(),
            object_id: captured.object_id,
            revision: String::new(),
            complete: captured.complete,
            skipped: captured.skipped,
            skipped_total: captured.skipped_total,
            created_at,
            expires_at: None,
            base: captured.base,
            coverage: captured.coverage,
            included: captured.included,
            bytes: captured.bytes,
            limits: arguments.request.limits,
            pins: Vec::new(),
        },
        created_at_ms,
        revision: 1,
    };
    stored.settle();
    Ok(stored)
}

fn expect_identity(fields: &Map<String, Value>, target: &Target) -> Result<(), ResourceError> {
    for (field, actual) in [
        ("expected_repository_id", &target.repository_id),
        ("expected_worktree_id", &target.worktree_id),
    ] {
        if let Some(expected) = fields.get(field).and_then(Value::as_str)
            && expected != actual
        {
            let message = format!("the target is now {actual}, not {expected}");
            let extra = json!({"field":field,"actual":actual});
            return Err(refused("git.checkpoint.create", "repository_changed", message, extra));
        }
    }
    Ok(())
}

struct CreateArguments {
    request: Request,
    reason: String,
}

fn parse_create(fields: &Map<String, Value>) -> Result<CreateArguments, ResourceError> {
    let include = match fields.get("include_untracked") {
        None => Include::Paths(Vec::new()),
        Some(Value::String(_)) => Include::Eligible,
        Some(value) => Include::Paths(relative_paths(value, "include_untracked")?),
    };
    let exclude = match fields.get("exclude_paths") {
        Some(value) => relative_paths(value, "exclude_paths")?,
        None => Vec::new(),
    };
    let mut limits = Limits::default();
    if let Some(given) = fields.get("limits") {
        if let Some(max_bytes) = given.get("max_bytes").and_then(Value::as_u64) {
            limits.max_bytes = u32::try_from(max_bytes).unwrap_or(u32::MAX);
        }
        if let Some(max_files) = given.get("max_files").and_then(Value::as_u64) {
            limits.max_files = u32::try_from(max_files).unwrap_or(u32::MAX);
        }
    }
    let reason = fields.get("reason").and_then(Value::as_str).unwrap_or("manual").to_string();
    Ok(CreateArguments { request: Request { include, exclude, limits }, reason })
}

/// Repository-relative paths: no leading `/`, no `.` or `..` and no `.git`
/// component. A trailing `/` is dropped.
fn relative_paths(value: &Value, field: &str) -> Result<Vec<String>, ResourceError> {
    let mut paths = Vec::new();
    for path in value.as_array().into_iter().flatten().filter_map(Value::as_str) {
        let trimmed = path.strip_suffix('/').unwrap_or(path);
        let valid = !trimmed.is_empty()
            && !trimmed.starts_with('/')
            && !trimmed.contains('\0')
            && trimmed.split('/').all(|part| !matches!(part, "" | "." | ".." | ".git"));
        if !valid {
            return Err(ResourceError::validation_invalid(
                Some(field),
                format!("{path:?} is not a path relative to the repository root"),
            ));
        }
        paths.push(trimmed.to_string());
    }
    Ok(paths)
}

fn not_found(id: &str) -> ResourceError {
    ResourceError::new(
        "resource.not_found",
        format!("no git checkpoint {id:?}"),
        json!({"scope":"git_checkpoint","id":id}),
        false,
    )
}

/// `git.checkpoint.pin` and `git.checkpoint.unpin`. Distinct pin ids
/// commute; pinning an id again replaces its reason.
fn pin(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation.wire_name();
    let pinning = request.envelope.operation == ResourceOperation::GitCheckpointPin;
    let key = mutation_key(request);
    let field = |name: &str| {
        request.fields.get(name).and_then(Value::as_str).unwrap_or_default().to_string()
    };
    let (checkpoint_id, pin_id) = (field("checkpoint_id"), field("pin_id"));
    store.exclusive(|| {
        let target = resolved(mux, store, request, operation)?;
        let fingerprint = fingerprint(request, &target);
        if let Some(replayed) = ledger::prior(mux, &key, operation, &fingerprint)? {
            return Ok(replayed);
        }
        if !pinning && MANAGED_PINS.iter().any(|prefix| pin_id.starts_with(prefix)) {
            let message =
                format!("{pin_id} is held by the handoff or restore owner and is released there");
            return Err(refused(operation, "managed_pin", message, json!({"pin_id":pin_id})));
        }
        let mut stored = store
            .load(&target.repository_id, &checkpoint_id)
            .map_err(|error| io_failed(operation, &error))?
            .ok_or_else(|| not_found(&checkpoint_id))?;
        let before = stored.record.pins.clone();
        stored.record.pins.retain(|pin| pin.pin_id != pin_id);
        if pinning {
            stored.record.pins.push(Pin { pin_id: pin_id.clone(), reason: field("reason") });
            stored.record.pins.sort_by(|left, right| left.pin_id.cmp(&right.pin_id));
        }
        if stored.record.pins != before {
            stored.revision += 1;
            stored.settle();
            store.save(&stored).map_err(|error| io_failed(operation, &error))?;
        }
        let value = serde_json::to_value(&stored.record).expect("records serialize");
        ledger::commit(mux, &key, operation, &fingerprint, &value, false)
    })
}

#[cfg(test)]
mod tests;
