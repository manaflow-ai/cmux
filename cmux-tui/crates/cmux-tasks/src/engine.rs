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
use cmux_tasks_core::{Envelope, Event, Op, Origin, Reject, RejectCode, State};
use serde_json::{Value, json};

use crate::protocol::{ErrorBody, ErrorCode, Request, Settled};
use crate::store::{OpenError, Store};

const RING: usize = 10_000;

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
            origin,
            body,
        })
        .collect()
}

/// Fill omitted generated ids (`task_…`, `cmt_…`, `asess_…`, …) from the
/// actor and idempotency key: deterministic, so a retry with the same key
/// names the same entity and replays instead of conflicting.
fn derive_ids(op: &str, params: &mut Value, actor: &Principal, key: &str) {
    let Some(entry) = catalog::find(op) else { return };
    let Some(object) = params.as_object_mut() else { return };
    for param in entry.params {
        if let catalog::Ty::Id { prefix, generate: true } = param.ty
            && !object.contains_key(param.name)
        {
            object.insert(
                param.name.to_owned(),
                json!(format!("{prefix}{}", stable_hash(&[actor.id(), key, param.name]))),
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
        let (store, recovered) = Store::open_with(dir, team, key_prefix, limits)?;
        let floor = recovered.first().map_or(store.state().seq, |(record, _)| record.seq - 1);
        let mut engine = Self { store, ring: VecDeque::new(), floor, clock };
        for (record, kinds) in recovered {
            let env = &record.envelope;
            let events = stamp(record.seq, &env.key, record.at, &env.actor, env.origin, kinds);
            engine.push_events(events);
        }
        Ok(engine)
    }

    pub fn state(&self) -> &State {
        self.store.state()
    }

    /// Handle requests as one group commit: one fsync for all mutations.
    /// An `Err` means the log write failed; the caller must exit.
    pub fn handle_batch(
        &mut self,
        requests: Vec<(Principal, Request)>,
    ) -> io::Result<Vec<Outcome>> {
        let mut outcomes = Vec::with_capacity(requests.len());
        for (actor, request) in requests {
            let (reply, events) = self.handle_one(&actor, &request);
            let settled =
                Settled { id: request.id, tx: request.key.clone(), seq: self.store.state().seq };
            outcomes.push(Outcome { reply, settled, events });
        }
        self.store.flush()?;
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

    pub fn handle(&mut self, actor: &Principal, request: Request) -> io::Result<Outcome> {
        let mut outcomes = self.handle_batch(vec![(actor.clone(), request)])?;
        Ok(outcomes.remove(0))
    }

    fn handle_one(
        &mut self,
        actor: &Principal,
        request: &Request,
    ) -> (Result<Value, ErrorBody>, Vec<Event>) {
        let Some(entry) = catalog::find(&request.op) else {
            return (
                Err(ErrorBody::new(ErrorCode::Usage, format!("unknown op {}", request.op))),
                Vec::new(),
            );
        };
        match entry.class {
            Class::Read => (self.read(actor, &request.op, &request.params), Vec::new()),
            Class::Stream => (
                Err(ErrorBody::new(ErrorCode::Usage, "streams need the socket server")),
                Vec::new(),
            ),
            Class::Mutation => self.mutate(actor, request),
        }
    }

    fn mutate(
        &mut self,
        actor: &Principal,
        request: &Request,
    ) -> (Result<Value, ErrorBody>, Vec<Event>) {
        let Some(key) = request.key.clone() else {
            return (
                Err(ErrorBody::new(ErrorCode::Usage, "mutations need an idempotency key")),
                Vec::new(),
            );
        };
        let mut params = if request.params.is_null() { json!({}) } else { request.params.clone() };
        derive_ids(&request.op, &mut params, actor, &key);
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
        let envelope = Envelope { actor: actor.clone(), origin, key: key.clone(), grants, op };
        let now = (self.clock)();
        match self.store.stage(&envelope, now) {
            Ok(commit) => {
                let events = stamp(commit.seq, &key, now, actor, origin, commit.events);
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
