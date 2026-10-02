//! The reducer: `reduce(state, envelope, ctx) -> Result<Commit, Reject>`.
//!
//! Contract (property-tested in tests/proptest_invariants.rs):
//! - A reject leaves the state unchanged (every handler validates before it
//!   mutates).
//! - A commit leaves every invariant of `invariants::check` true.
//! - Replaying a committed `(actor, key)` with the same op returns the
//!   recorded result and changes nothing; a different op under the same key
//!   is rejected `idempotency_conflict`.
//! - The result depends only on `(state, envelope, ctx)`: time comes from
//!   `ctx`, ids from the envelope, so replaying the op log is deterministic.

mod links;
mod sessions;
mod tasks;
mod workflow;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::event::EventKind;
use crate::ids::Principal;
use crate::model::{LEDGER_RETENTION_MS, LedgerEntry, State, ledger_key};
use crate::op::{Envelope, Op};

/// Inputs from the owner that are not part of the op. Logged with every
/// record so replay sees the same values.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ctx {
    /// Commit time, ms since the epoch.
    pub now: i64,
}

/// What a committed op returns to the caller.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpResult {
    /// The entity the op created or changed.
    pub id: String,
    /// Human key of the task involved (`CMX-12`), when there is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub result: OpResult,
    pub events: Vec<EventKind>,
    /// The commit's sequence (for a replay, the original commit's sequence).
    pub seq: u64,
    /// True when the key was already committed: nothing changed.
    pub replay: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectCode {
    NotFound,
    Invalid,
    /// Stale version, a claim already taken, a name already used.
    Conflict,
    IdempotencyConflict,
    Forbidden,
}

impl RejectCode {
    /// CLI exit code (plans/cmux-next/tasks.md).
    pub fn exit_code(self) -> u8 {
        match self {
            Self::NotFound => 3,
            Self::Invalid | Self::Conflict | Self::Forbidden => 4,
            Self::IdempotencyConflict => 6,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reject {
    pub code: RejectCode,
    pub message: String,
}

impl Reject {
    pub fn new(code: RejectCode, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

pub(crate) fn not_found(what: &str, reference: &str) -> Reject {
    Reject::new(RejectCode::NotFound, format!("{what} not found: {reference}"))
}

pub(crate) fn invalid(message: impl Into<String>) -> Reject {
    Reject::new(RejectCode::Invalid, message)
}

pub(crate) fn conflict(message: impl Into<String>) -> Reject {
    Reject::new(RejectCode::Conflict, message)
}

pub(crate) fn forbidden(message: impl Into<String>) -> Reject {
    Reject::new(RejectCode::Forbidden, message)
}

/// Fingerprint of an op for idempotency conflict detection.
pub fn fingerprint(op: &Op) -> String {
    let bytes = serde_json::to_vec(op).unwrap_or_default();
    let digest = Sha256::digest(&bytes);
    digest.iter().take(16).map(|b| format!("{b:02x}")).collect()
}

/// Ops an ordinary agent may run only with a grant naming the op (D20).
fn needs_grant_for_ordinary_agent(op: &Op) -> bool {
    matches!(
        op,
        Op::TaskDelete(_)
            | Op::TaskDelegate(_)
            | Op::LabelDelete(_)
            | Op::StatusCreate(_)
            | Op::StatusUpdate(_)
            | Op::StatusDelete(_)
            | Op::ProjectArchive(_)
            | Op::SettingsUpdate(_)
    )
}

/// Apply one envelope. On `Ok` the state holds the commit (or is unchanged
/// for a replay); on `Err` the state is unchanged.
pub fn reduce(state: &mut State, envelope: &Envelope, ctx: Ctx) -> Result<Commit, Reject> {
    if envelope.key.is_empty() || envelope.key.len() > 200 {
        return Err(invalid("idempotency key must be 1..=200 bytes"));
    }
    let print = fingerprint(&envelope.op);
    let ledger_id = ledger_key(envelope.actor.id(), &envelope.key);
    if let Some(entry) = state.ledger.get(&ledger_id) {
        if entry.fingerprint != print {
            return Err(Reject::new(
                RejectCode::IdempotencyConflict,
                format!("key {} was used for a different op", envelope.key),
            ));
        }
        return Ok(Commit { result: entry.result.clone(), events: Vec::new(), seq: entry.seq, replay: true });
    }
    if envelope.actor.is_ordinary_agent()
        && needs_grant_for_ordinary_agent(&envelope.op)
        && !envelope.grants.contains(envelope.op.name())
    {
        return Err(forbidden(format!("{} needs a grant for ordinary agents", envelope.op.name())));
    }
    let mut tx = Tx { state, actor: &envelope.actor, now: ctx.now, events: Vec::new() };
    let result = tx.apply(&envelope.op)?;
    let Tx { state, events, .. } = tx;
    state.seq += 1;
    let seq = state.seq;
    prune_ledger(state, ctx.now);
    state.ledger.insert(
        ledger_id.clone(),
        LedgerEntry { fingerprint: print, result: result.clone(), seq, at: ctx.now },
    );
    state.ledger_order.push_back(ledger_id);
    Ok(Commit { result, events, seq, replay: false })
}

fn prune_ledger(state: &mut State, now: i64) {
    while let Some(oldest) = state.ledger_order.front() {
        let expired = state
            .ledger
            .get(oldest)
            .is_none_or(|entry| now - entry.at > LEDGER_RETENTION_MS);
        if !expired {
            break;
        }
        if let Some(key) = state.ledger_order.pop_front() {
            state.ledger.remove(&key);
        }
    }
}

/// One op being applied: handlers validate first, then mutate `state` and
/// push events.
pub(crate) struct Tx<'a> {
    pub state: &'a mut State,
    pub actor: &'a Principal,
    pub now: i64,
    pub events: Vec<EventKind>,
}

impl Tx<'_> {
    fn apply(&mut self, op: &Op) -> Result<OpResult, Reject> {
        match op {
            Op::TaskCreate(p) => self.task_create(p),
            Op::TaskUpdate(p) => self.task_update(p),
            Op::TaskMove(p) => self.task_move(p),
            Op::TaskArchive(p) => self.task_set_archived(&p.task, true),
            Op::TaskUnarchive(p) => self.task_set_archived(&p.task, false),
            Op::TaskDelete(p) => self.task_delete(&p.task),
            Op::TaskDelegate(p) => self.task_delegate(p),
            Op::SessionClaim(p) => self.session_claim(p),
            Op::SessionAttach(p) => self.session_attach(p),
            Op::SessionUpdate(p) => self.session_update(p),
            Op::SessionCancel(p) => self.session_cancel(&p.session),
            Op::CommentAdd(p) => self.comment_add(p),
            Op::CommentUpdate(p) => self.comment_update(p),
            Op::CommentDelete(p) => self.comment_delete(&p.comment),
            Op::RelationAdd(p) => self.relation_add(p),
            Op::RelationRemove(p) => self.relation_remove(&p.relation),
            Op::LabelCreate(p) => self.label_create(p),
            Op::LabelUpdate(p) => self.label_update(p),
            Op::LabelDelete(p) => self.label_delete(&p.label),
            Op::StatusCreate(p) => self.status_create(p),
            Op::StatusUpdate(p) => self.status_update(p),
            Op::StatusDelete(p) => self.status_delete(p),
            Op::ProjectCreate(p) => self.project_create(p),
            Op::ProjectUpdate(p) => self.project_update(p),
            Op::ProjectArchive(p) => self.project_archive(&p.project),
            Op::SettingsUpdate(p) => self.settings_update(p),
        }
    }

    /// Resolve a live task reference or reject `not_found`.
    pub(crate) fn task_id(&self, reference: &str) -> Result<String, Reject> {
        self.state.resolve_task(reference).ok_or_else(|| not_found("task", reference))
    }

    pub(crate) fn result_for_task(&self, id: &str) -> OpResult {
        let key = self.state.tasks.get(id).map(|t| self.state.task_key(t));
        OpResult { id: id.to_owned(), key }
    }
}
