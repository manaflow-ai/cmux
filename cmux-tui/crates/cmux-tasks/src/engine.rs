//! The owner's request handling, shared by the socket server and the CLI's
//! in-process mode. Mutations go through `Store::stage` + `Store::flush`
//! (group commit); replies and events are released only after the flush.

use std::collections::VecDeque;
use std::io;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_tasks_core::catalog::{self, Class};
use cmux_tasks_core::ids::Principal;
use cmux_tasks_core::query::{self, ListFilter};
use cmux_tasks_core::{Actor, Envelope, Event, Op, Origin, Reject, RejectCode, State};
use serde_json::{Value, json};

use crate::identity::Caller;
use crate::protocol::{ErrorBody, ErrorCode, Request, Settled};
use crate::store::{OpenError, Store};

const RING: usize = 10_000;

/// The largest op the owner logs, as serialized JSON. One log record (the op
/// plus its small result) must fit one replica range (the TeamVmDO journal
/// takes 1 MiB per append), so a large op is refused here as `invalid`
/// instead of stopping the writer at the flush.
pub const MAX_OP_BYTES: usize = 256 * 1024;

pub struct Outcome {
    pub reply: Result<Value, ErrorBody>,
    pub settled: Settled,
    pub events: Vec<Event>,
}

pub type Clock = Box<dyn FnMut() -> i64 + Send>;

pub fn system_clock() -> Clock {
    Box::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64))
}

pub struct Engine {
    store: Store,
    ring: VecDeque<Event>,
    /// Events of commits with `seq <= floor` are no longer in the ring.
    floor: u64,
    clock: Clock,
    /// Set when a flush failed: memory is ahead of the durable tier, so the
    /// engine refuses every request until the process restarts from disk.
    /// `state`, `snapshot_value` and `events_after` are not guarded: the
    /// server exits on a failed flush, so only an embedder could read them.
    poisoned: bool,
}

fn reject_body(reject: Reject) -> ErrorBody {
    let code = match reject.code {
        RejectCode::NotFound => ErrorCode::NotFound,
        RejectCode::Invalid => ErrorCode::Invalid,
        RejectCode::Conflict => ErrorCode::Conflict,
        RejectCode::IdempotencyConflict => ErrorCode::IdempotencyConflict,
        RejectCode::Forbidden => ErrorCode::Forbidden,
    };
    ErrorBody::new(code, reject.message)
}

fn stamp(
    seq: u64,
    tx: &str,
    at: i64,
    actor: &Principal,
    by: Option<&Actor>,
    origin: Origin,
    kinds: Vec<cmux_tasks_core::EventKind>,
) -> Vec<Event> {
    kinds
        .into_iter()
        .enumerate()
        .map(|(index, body)| Event {
            seq,
            index: index as u32,
            tx: tx.to_owned(),
            at,
            actor: actor.clone(),
            stamp: by.cloned(),
            origin,
            body,
        })
        .collect()
}

/// Fill omitted generated ids (`task_…`, `cmt_…`, `asess_…`, …) from the
/// accountable person and idempotency key (the ledger's scope): deterministic,
/// so a retry with the same key names the same entity and replays instead of
/// conflicting, under any credential of the same person.
fn derive_ids(op: &str, params: &mut Value, person: &str, key: &str) {
    let Some(entry) = catalog::find(op) else { return };
    let Some(object) = params.as_object_mut() else { return };
    for param in entry.params {
        if let catalog::Ty::Id { prefix, generate: true } = param.ty
            && !object.contains_key(param.name)
        {
            object.insert(
                param.name.to_owned(),
                json!(format!("{prefix}{}", stable_hash(&[person, key, param.name]))),
            );
        }
    }
}

/// FNV-1a 64 over the parts, as 16 lowercase hex digits.
fn stable_hash(parts: &[&str]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for part in parts {
        for byte in part.bytes().chain(std::iter::once(0x1f)) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
    format!("{hash:016x}")
}

impl Engine {
    pub fn open(dir: &Path, team: &str, key_prefix: &str, clock: Clock) -> Result<Self, OpenError> {
        Self::open_with(dir, team, key_prefix, clock, crate::store::Limits::default())
    }

    pub fn open_with(
        dir: &Path,
        team: &str,
        key_prefix: &str,
        clock: Clock,
        limits: crate::store::Limits,
    ) -> Result<Self, OpenError> {
        Self::open_durable(dir, team, key_prefix, clock, limits, crate::store::Durability::local())
    }

    /// Open under the supervisor's durability settings (lease epoch, replica).
    pub fn open_durable(
        dir: &Path,
        team: &str,
        key_prefix: &str,
        clock: Clock,
        limits: crate::store::Limits,
        durability: crate::store::Durability,
    ) -> Result<Self, OpenError> {
        let (store, recovered) = Store::open_durable(dir, team, key_prefix, limits, durability)?;
        let floor = recovered.first().map_or(store.state().seq, |(record, _)| record.seq - 1);
        let mut engine = Self { store, ring: VecDeque::new(), floor, clock, poisoned: false };
        for (record, kinds) in recovered {
            let env = &record.envelope;
            let events = stamp(
                record.seq,
                &env.key,
                record.at,
                &env.actor,
                env.stamp.as_ref(),
                env.origin,
                kinds,
            );
            engine.push_events(events);
        }
        Ok(engine)
    }

    pub fn state(&self) -> &State {
        self.store.state()
    }

    /// Handle requests as one group commit: one fsync for all mutations.
    /// An `Err` means the log write failed; the caller must exit.
    pub fn handle_batch(&mut self, requests: Vec<(Caller, Request)>) -> io::Result<Vec<Outcome>> {
        if self.poisoned {
            return Err(io::Error::other("an earlier log write failed; restart the owner"));
        }
        let mut outcomes = Vec::with_capacity(requests.len());
        for (caller, request) in requests {
            let (reply, events) = self.handle_one(&caller, &request);
            let settled =
                Settled { id: request.id, tx: request.key.clone(), seq: self.store.state().seq };
            outcomes.push(Outcome { reply, settled, events });
        }
        if let Err(e) = self.store.flush() {
            self.poisoned = true;
            return Err(e);
        }
        let events: Vec<Event> = outcomes.iter().flat_map(|o| o.events.iter().cloned()).collect();
        self.push_events(events);
        Ok(outcomes)
    }

    fn push_events(&mut self, events: Vec<Event>) {
        self.ring.extend(events);
        while self.ring.len() > RING {
            if let Some(dropped) = self.ring.pop_front() {
                self.floor = self.floor.max(dropped.seq);
            }
        }
    }

    pub fn handle(&mut self, caller: &Caller, request: Request) -> io::Result<Outcome> {
        let mut outcomes = self.handle_batch(vec![(caller.clone(), request)])?;
        Ok(outcomes.remove(0))
    }

    fn handle_one(
        &mut self,
        caller: &Caller,
        request: &Request,
    ) -> (Result<Value, ErrorBody>, Vec<Event>) {
        // A request routed under another lease epoch reached a stale or a
        // newer owner: refuse it (server.md 7.2). Unrouted local requests
        // carry no epoch.
        if let (Some(theirs), Some(ours)) = (request.epoch, self.store.epoch())
            && theirs != ours
        {
            return (
                Err(ErrorBody::new(
                    ErrorCode::OwnerMoved,
                    format!("owner_moved: request epoch {theirs}, owner epoch {ours}"),
                )),
                Vec::new(),
            );
        }
        let Some(entry) = catalog::find(&request.op) else {
            return (
                Err(ErrorBody::new(ErrorCode::Usage, format!("unknown op {}", request.op))),
                Vec::new(),
            );
        };
        match entry.class {
            Class::Read => (self.read(&caller.principal, &request.op, &request.params), Vec::new()),
            Class::Stream => (
                Err(ErrorBody::new(ErrorCode::Usage, "streams need the socket server")),
                Vec::new(),
            ),
            Class::Mutation => self.mutate(caller, request),
        }
    }

    fn mutate(
        &mut self,
        caller: &Caller,
        request: &Request,
    ) -> (Result<Value, ErrorBody>, Vec<Event>) {
        let Some(key) = request.key.clone() else {
            return (
                Err(ErrorBody::new(ErrorCode::Usage, "mutations need an idempotency key")),
                Vec::new(),
            );
        };
        let mut params = if request.params.is_null() { json!({}) } else { request.params.clone() };
        derive_ids(&request.op, &mut params, caller.principal.human(), &key);
        let wire = json!({"op": request.op, "params": params});
        let op: Op = match serde_json::from_value(wire) {
            Ok(op) => op,
            Err(e) => {
                return (
                    Err(ErrorBody::new(ErrorCode::Usage, format!("{}: {e}", request.op))),
                    Vec::new(),
                );
            }
        };
        let origin = request.origin.unwrap_or_default();
        let grants = Default::default();
        let envelope = Envelope {
            actor: caller.principal.clone(),
            stamp: Some(caller.stamp.clone()),
            origin,
            key: key.clone(),
            grants,
            op,
        };
        let size = serde_json::to_vec(&envelope).map_or(usize::MAX, |bytes| bytes.len());
        if size > MAX_OP_BYTES {
            return (
                Err(ErrorBody::new(
                    ErrorCode::Invalid,
                    format!("{} is {size} bytes; the limit is {MAX_OP_BYTES}", request.op),
                )),
                Vec::new(),
            );
        }
        let now = (self.clock)();
        match self.store.stage(&envelope, now) {
            Ok(commit) => {
                let events = stamp(
                    commit.seq,
                    &key,
                    now,
                    &caller.principal,
                    Some(&caller.stamp),
                    origin,
                    commit.events,
                );
                let value = serde_json::to_value(&commit.result).unwrap_or(Value::Null);
                (Ok(json!({"result": value, "seq": commit.seq, "replay": commit.replay})), events)
            }
            Err(reject) => (Err(reject_body(reject)), Vec::new()),
        }
    }

    fn read(&self, actor: &Principal, op: &str, params: &Value) -> Result<Value, ErrorBody> {
        let state = self.store.state();
        let params = if params.is_null() { json!({}) } else { params.clone() };
        let task_param = |state: &State| -> Result<String, ErrorBody> {
            let reference = params
                .get("task")
                .and_then(Value::as_str)
                .ok_or_else(|| ErrorBody::new(ErrorCode::Usage, "task is required"))?;
            state.resolve_task(reference).ok_or_else(|| {
                ErrorBody::new(ErrorCode::NotFound, format!("task not found: {reference}"))
            })
        };
        let value = match op {
            "task.list" => {
                let filter: ListFilter = serde_json::from_value(params.clone())
                    .map_err(|e| ErrorBody::new(ErrorCode::Usage, e.to_string()))?;
                json!(query::list(state, actor, &filter))
            }
            "task.get" => {
                let id = task_param(state)?;
                json!(query::detail(state, &id))
            }
            "task.comment.list" => {
                let id = task_param(state)?;
                json!(query::detail(state, &id).map(|d| d.comments).unwrap_or_default())
            }
            "task.session.list" => {
                let task = match params.get("task").and_then(Value::as_str) {
                    Some(_) => Some(task_param(state)?),
                    None => None,
                };
                let active = params.get("active").and_then(Value::as_bool).unwrap_or(false);
                let sessions: Vec<_> = state
                    .sessions
                    .values()
                    .filter(|s| task.as_ref().is_none_or(|t| &s.task == t))
                    .filter(|s| !active || !s.status.is_terminal())
                    .collect();
                json!(sessions)
            }
            "task.label.list" => {
                json!(state.labels.values().filter(|l| !l.archived).collect::<Vec<_>>())
            }
            "task.status.list" => {
                let mut statuses: Vec<_> = state.statuses.values().collect();
                statuses.sort_by_key(|s| (s.category.rank(), s.position));
                json!(statuses)
            }
            "task.project.list" => {
                json!(state.projects.values().filter(|p| !p.archived).collect::<Vec<_>>())
            }
            "task.settings.get" => json!(state.settings),
            other => {
                return Err(ErrorBody::new(
                    ErrorCode::Usage,
                    format!("no read handler for {other}"),
                ));
            }
        };
        Ok(value)
    }

    /// The mirror bootstrap a subscriber receives before live events.
    pub fn snapshot_value(&self, actor: &Principal) -> Value {
        let state = self.store.state();
        let mut statuses: Vec<_> = state.statuses.values().collect();
        statuses.sort_by_key(|s| (s.category.rank(), s.position));
        let filter = ListFilter::default();
        let archived = ListFilter { archived: true, ..ListFilter::default() };
        let mut tasks = query::list(state, actor, &filter);
        tasks.extend(query::list(state, actor, &archived));
        json!({
            "seq": state.seq,
            "me": actor,
            "settings": state.settings,
            "statuses": statuses,
            "labels": state.labels.values().filter(|l| !l.archived).collect::<Vec<_>>(),
            "projects": state.projects.values().filter(|p| !p.archived).collect::<Vec<_>>(),
            "tasks": tasks,
            "sessions": state.sessions.values().filter(|s| !s.status.is_terminal()).collect::<Vec<_>>(),
        })
    }

    /// Events with `seq > after`, or `resync` when the ring no longer holds them.
    pub fn events_after(&self, after: u64) -> Result<Vec<Event>, ErrorBody> {
        if after >= self.store.state().seq {
            return Ok(Vec::new());
        }
        if after < self.floor {
            return Err(ErrorBody::new(
                ErrorCode::Resync,
                "events no longer held; subscribe without after_seq",
            ));
        }
        Ok(self.ring.iter().filter(|e| e.seq > after).cloned().collect())
    }
}
