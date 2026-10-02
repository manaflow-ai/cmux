//! `git.checkpoint.create|get|list|pin|unpin`: immutable repository
//! checkpoints the session host captures without changing HEAD, the index or
//! the worktree, published as `refs/cmux/checkpoints/<worktree>/<id>`.
//! Mutations go through one per-session lock and a durable ledger that binds
//! each idempotency key to its operation, arguments and first result.

mod capture;
mod record;
mod scan;
mod store;
#[cfg(test)]
mod tests;

use std::sync::Arc;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::Repository;
use super::write_run::{Bound, WriteGit};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, mutation_result};
use capture::{Include, Request, Stamp};
use record::{Checkpoint, Limits, Pin, Stored, now_ms, rfc3339};
use scan::{Layout, failed};
use store::{LedgerEntry, LedgerState, Store, io_failed, mint};

/// Pin ids with these prefixes belong to the handoff and restore owners.
const MANAGED_PINS: [&str; 2] = ["handoff:", "restore:"];
const MAX_CANDIDATES_SCANNED: usize = 100_000;

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
    match request.envelope.operation {
        ResourceOperation::GitCheckpointCreate => create(mux, &store, &request),
        ResourceOperation::GitCheckpointGet => get(mux, &store, &request),
        ResourceOperation::GitCheckpointList => list(mux, &store, &request),
        ResourceOperation::GitCheckpointPin | ResourceOperation::GitCheckpointUnpin => {
            pin(mux, &store, &request)
        }
        other => unreachable!("checkpoint does not handle {other:?}"),
    }
}

/// The repository a request names, with its git directories and ids.
struct Target {
    repository: Repository,
    layout: Layout,
    repository_id: String,
    worktree_id: String,
}

/// Resolves the request's target. Call under the store's lock: the first
/// sight of a repository or worktree mints its id.
fn target(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
    operation: &'static str,
) -> Result<Target, ResourceError> {
    let directory = super::target::directory(mux, request, operation)?;
    let repository = Repository::open(&directory, operation)?;
    let layout = Layout::locate(&repository, operation)?;
    let (repository_id, worktree_id) = store
        .identify(&layout.common_dir, &layout.git_dir)
        .map_err(|error| io_failed(operation, &error))?;
    Ok(Target { repository, layout, repository_id, worktree_id })
}

fn writer<'a>(target: &'a Target, hooks: &'a std::path::Path) -> WriteGit<'a> {
    WriteGit { root: &target.repository.root, overrides: &target.repository.overrides, hooks }
}

/// The operation and its normalized arguments, which a reused key must
/// match.
fn fingerprint(request: &ParsedResourceRequest) -> String {
    let value = json!({
        "operation": request.envelope.operation.wire_name(),
        "selectors": request.selectors,
        "fields": request.fields,
    });
    store::hex(&Sha256::digest(value.to_string().as_bytes()))
}

/// The ledger's answer for a key already used: its first result, a
/// conflict, or `None` to (re)apply the mutation.
fn replay(
    mux: &Mux,
    store: &Store,
    key: &str,
    operation: &'static str,
    fingerprint: &str,
) -> Result<(Option<LedgerEntry>, Option<Value>), ResourceError> {
    let Some(entry) = store.ledger(key).map_err(|error| io_failed(operation, &error))? else {
        return Ok((None, None));
    };
    if entry.operation != operation || entry.fingerprint != fingerprint {
        return Err(ResourceError::idempotency_conflict(key, &entry.operation));
    }
    if entry.state == LedgerState::Done
        && let Some(result) = entry.result.clone()
    {
        return Ok((
            Some(entry.clone()),
            Some(mutation_result(mux, result, entry.revision, true)?),
        ));
    }
    Ok((Some(entry), None))
}

fn create(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.create";
    let key =
        request.envelope.idempotency_key.clone().expect("catalog-validated mutations have a key");
    let arguments = parse_create(&request.fields)?;
    let fingerprint = fingerprint(request);
    store.exclusive(|| {
        let (pending, replayed) = replay(mux, store, &key, OPERATION, &fingerprint)?;
        if let Some(replayed) = replayed {
            return Ok(replayed);
        }
        let target = target(mux, store, request, OPERATION)?;
        expect_identity(&request.fields, &target)?;
        let hooks = store.hooks();
        let git = writer(&target, &hooks);
        if let Some(pending) = pending {
            if pending.repository_id != target.repository_id
                || pending.worktree_id != target.worktree_id
            {
                return Err(failed(
                    OPERATION,
                    "repository_changed",
                    "the key was first used for another repository or worktree",
                ));
            }
            if let Some(value) = reconcile(mux, store, &git, &pending)? {
                return Ok(value);
            }
        }
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
            &git,
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
                checkpoint_id: checkpoint_id.clone(),
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
        // Journal the intent first: a retry after a crash finds the ref.
        let mut entry = LedgerEntry {
            idempotency_key: key.clone(),
            operation: OPERATION.to_string(),
            fingerprint: fingerprint.clone(),
            repository_id: target.repository_id.clone(),
            worktree_id: target.worktree_id.clone(),
            checkpoint_id,
            state: LedgerState::Pending,
            draft: Some(stored.clone()),
            result: None,
            revision: stored.revision,
        };
        store.record_ledger(&entry).map_err(|error| io_failed(OPERATION, &error))?;
        publish(&git, &stored)?;
        let value = finish(store, &mut entry, &stored)?;
        prune(store, &git, &target.repository_id);
        mutation_result(mux, value, stored.revision, false)
    })
}

/// A pending create whose ref is published is finished now and replayed;
/// one whose ref never appeared is captured again under the same key.
fn reconcile(
    mux: &Mux,
    store: &Store,
    git: &WriteGit<'_>,
    pending: &LedgerEntry,
) -> Result<Option<Value>, ResourceError> {
    let Some(draft) = &pending.draft else { return Ok(None) };
    let published = git
        .run(
            None,
            &[
                std::ffi::OsStr::new("rev-parse"),
                std::ffi::OsStr::new("--verify"),
                std::ffi::OsStr::new("--quiet"),
                std::ffi::OsStr::new(&draft.record.reference),
            ],
            &[],
            Bound::Deadline(std::time::Duration::from_secs(20)),
            4096,
        )
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string());
    if published.as_deref() != Some(draft.record.object_id.as_str()) {
        return Ok(None);
    }
    let mut entry = pending.clone();
    let value = finish(store, &mut entry, draft)?;
    Ok(Some(mutation_result(mux, value, draft.revision, true)?))
}

/// Publishes a checkpoint's ref, which must not exist yet.
fn publish(git: &WriteGit<'_>, stored: &Stored) -> Result<(), ResourceError> {
    let zero = "0".repeat(stored.record.object_id.len());
    let arguments = [
        "update-ref",
        "-m",
        "cmux checkpoint",
        stored.record.reference.as_str(),
        stored.record.object_id.as_str(),
        zero.as_str(),
    ];
    let arguments = arguments.iter().map(std::ffi::OsStr::new).collect::<Vec<_>>();
    git.run(None, &arguments, &[], Bound::Unbounded, 4096)
        .map(|_| ())
        .map_err(|failure| scan::git("git.checkpoint.create", &failure))
}

/// Saves the record and marks its key done with the record as the result.
fn finish(store: &Store, entry: &mut LedgerEntry, stored: &Stored) -> Result<Value, ResourceError> {
    let operation = "git.checkpoint.create";
    store.save(stored).map_err(|error| io_failed(operation, &error))?;
    let value = serde_json::to_value(&stored.record).expect("records serialize");
    entry.state = LedgerState::Done;
    entry.draft = None;
    entry.result = Some(value.clone());
    entry.revision = stored.revision;
    store.record_ledger(entry).map_err(|error| io_failed(operation, &error))?;
    Ok(value)
}

/// Removes the repository's expired and excess unpinned checkpoints: their
/// refs (compare-and-delete) and records. Best effort; git objects stay
/// until the repository's own maintenance collects them.
fn prune(store: &Store, git: &WriteGit<'_>, repository_id: &str) {
    let Ok(records) = store.all(repository_id) else { return };
    for checkpoint_id in record::prunable(&records, now_ms()) {
        let Some(stored) =
            records.iter().find(|stored| stored.record.checkpoint_id == checkpoint_id)
        else {
            continue;
        };
        if !stored.record.reference.starts_with("refs/cmux/checkpoints/") {
            continue;
        }
        let arguments = [
            "update-ref",
            "-d",
            stored.record.reference.as_str(),
            stored.record.object_id.as_str(),
        ];
        let arguments = arguments.iter().map(std::ffi::OsStr::new).collect::<Vec<_>>();
        if git.run(None, &arguments, &[], Bound::Unbounded, 4096).is_ok() {
            let _ = store.remove(repository_id, &checkpoint_id);
        }
    }
}

fn expect_identity(fields: &Map<String, Value>, target: &Target) -> Result<(), ResourceError> {
    for (field, actual) in [
        ("expected_repository_id", &target.repository_id),
        ("expected_worktree_id", &target.worktree_id),
    ] {
        if let Some(expected) = fields.get(field).and_then(Value::as_str)
            && expected != actual
        {
            return Err(ResourceError::operation_failed(
                "git.checkpoint.create",
                format!("the target is now {actual}, not {expected}"),
                json!({"code":"repository_changed","field":field,"actual":actual}),
            ));
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

fn get(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.get";
    let target = store.exclusive(|| target(mux, store, request, OPERATION))?;
    let (checkpoint_id, asked) = if let Some(id) =
        request.fields.get("checkpoint_id").and_then(Value::as_str)
    {
        (id.to_string(), id.to_string())
    } else {
        let key = request.fields.get("idempotency_key").and_then(Value::as_str).unwrap_or_default();
        let entry = store.ledger(key).map_err(|error| io_failed(OPERATION, &error))?;
        match entry {
            Some(entry)
                if entry.state == LedgerState::Done
                    && entry.repository_id == target.repository_id =>
            {
                (entry.checkpoint_id, key.to_string())
            }
            _ => return Err(not_found(key)),
        }
    };
    let stored = store
        .load(&target.repository_id, &checkpoint_id)
        .map_err(|error| io_failed(OPERATION, &error))?
        .ok_or_else(|| not_found(&asked))?;
    Ok(serde_json::to_value(&stored.record).expect("records serialize"))
}

fn list(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.list";
    let target = store.exclusive(|| target(mux, store, request, OPERATION))?;
    let limit = request.fields.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
    let after = match request.fields.get("cursor").and_then(Value::as_str) {
        Some(cursor) => Some(parse_cursor(cursor)?),
        None => None,
    };
    let mut records = store
        .all(&target.repository_id)
        .map_err(|error| io_failed(OPERATION, &error))?
        .into_iter()
        .filter(|stored| stored.record.worktree_id == target.worktree_id)
        .collect::<Vec<_>>();
    records.sort_by_key(|stored| std::cmp::Reverse(stored.order_key()));
    let mut page = records
        .into_iter()
        .filter(|stored| after.as_ref().is_none_or(|after| stored.order_key() < *after))
        .take(limit + 1)
        .collect::<Vec<_>>();
    let next_cursor = (page.len() > limit).then(|| {
        page.truncate(limit);
        let (created_at_ms, checkpoint_id) = page.last().expect("a full page").order_key();
        format!("{created_at_ms}.{checkpoint_id}")
    });
    let limits = Limits::default();
    let mut value = json!({
        "repository_id": target.repository_id,
        "worktree_id": target.worktree_id,
        "checkpoints": page.iter().map(|stored| &stored.record).collect::<Vec<_>>(),
        "next_cursor": next_cursor,
        "limits": limits,
    });
    if request.fields.get("include_candidates").and_then(Value::as_bool) == Some(true) {
        value["candidates"] = candidates(&target, limits)?;
    }
    Ok(value)
}

fn parse_cursor(cursor: &str) -> Result<(u64, String), ResourceError> {
    cursor
        .split_once('.')
        .and_then(|(created, id)| Some((created.parse().ok()?, id.to_string())))
        .ok_or_else(|| {
            ResourceError::validation_invalid(Some("cursor"), "the cursor is not one list returned")
        })
}

/// The untracked paths a create could select, with their eligibility, and
/// ignored ones as ineligible.
fn candidates(target: &Target, limits: Limits) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.list";
    let untracked = scan::untracked(&target.repository, OPERATION)?;
    let ignored = scan::ignored(&target.repository, OPERATION)?;
    let total = untracked.len() + ignored.len();
    if total > limits.max_files as usize || total > MAX_CANDIDATES_SCANNED {
        return Err(ResourceError::operation_failed(
            OPERATION,
            format!("{total} untracked paths are more than one list shows ({})", limits.max_files),
            json!({"code":"budget_exceeded","candidate_total":total}),
        ));
    }
    let mut candidates = untracked
        .iter()
        .map(|candidate| {
            let mut value = json!({
                "path": String::from_utf8_lossy(&candidate.path),
                "bytes": record::saturate(candidate.size()),
                "eligible": true,
            });
            if let Some(code) = candidate.ineligible(limits.max_untracked_file_bytes) {
                value["eligible"] = json!(false);
                value["reason"] = json!(code);
            }
            (candidate.path.clone(), value)
        })
        .collect::<Vec<_>>();
    candidates.extend(ignored.into_iter().map(|path| {
        let value = json!({
            "path": String::from_utf8_lossy(&path),
            "bytes": 0,
            "eligible": false,
            "reason": "ignored",
        });
        (path, value)
    }));
    candidates.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(Value::Array(candidates.into_iter().map(|(_, value)| value).collect()))
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
    let key =
        request.envelope.idempotency_key.clone().expect("catalog-validated mutations have a key");
    let fingerprint = fingerprint(request);
    let field = |name: &str| {
        request.fields.get(name).and_then(Value::as_str).unwrap_or_default().to_string()
    };
    let (checkpoint_id, pin_id) = (field("checkpoint_id"), field("pin_id"));
    if !pinning && MANAGED_PINS.iter().any(|prefix| pin_id.starts_with(prefix)) {
        return Err(ResourceError::operation_failed(
            operation,
            format!("{pin_id} is held by the handoff or restore owner and is released there"),
            json!({"code":"managed_pin","pin_id":pin_id}),
        ));
    }
    store.exclusive(|| {
        if let (_, Some(replayed)) = replay(mux, store, &key, operation, &fingerprint)? {
            return Ok(replayed);
        }
        let target = target(mux, store, request, operation)?;
        let mut stored = store
            .load(&target.repository_id, &checkpoint_id)
            .map_err(|error| io_failed(operation, &error))?
            .ok_or_else(|| not_found(&checkpoint_id))?;
        let pins = &mut stored.record.pins;
        let before = pins.clone();
        pins.retain(|pin| pin.pin_id != pin_id);
        if pinning {
            pins.push(Pin { pin_id: pin_id.clone(), reason: field("reason") });
            pins.sort_by(|left, right| left.pin_id.cmp(&right.pin_id));
        }
        if stored.record.pins != before {
            stored.revision += 1;
            stored.settle();
            store.save(&stored).map_err(|error| io_failed(operation, &error))?;
        }
        let value = serde_json::to_value(&stored.record).expect("records serialize");
        let entry = LedgerEntry {
            idempotency_key: key.clone(),
            operation: operation.to_string(),
            fingerprint: fingerprint.clone(),
            repository_id: target.repository_id.clone(),
            worktree_id: target.worktree_id.clone(),
            checkpoint_id: checkpoint_id.clone(),
            state: LedgerState::Done,
            draft: None,
            result: Some(value.clone()),
            revision: stored.revision,
        };
        store.record_ledger(&entry).map_err(|error| io_failed(operation, &error))?;
        mutation_result(mux, value, stored.revision, false)
    })
}
