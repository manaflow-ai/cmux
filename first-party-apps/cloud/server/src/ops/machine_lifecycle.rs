//! Production lifecycle dispatch through the existing credential relay.
//!
//! An unresolved intent is never evicted. Its only retry sends the original
//! scope, subject, operation, key and revision, without another machine read.
//! Completed entries may be evicted: the backend remains the durable replay
//! authority. This process-local ledger does not survive a server restart.
//! Restart therefore observes the provider again and never invents a live
//! capability for Starting/Pausing/Deleting. Durable replay remains backend-owned.
//!
//! Detector: tests/lifecycle_dispatch.rs exercises public Server dispatch,
//! wrong scope/subject/revision, exact unknown replay and ledger saturation.
//! Cost: one local session exchange per attempt, one HTTP get per new intent,
//! zero additional HTTP reads on a retained retry or completed replay. The
//! extra network latency is one get round trip, independent of fleet size.

use crate::api::models::{Machine, Revision};
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use cmux_cloud_client::lifecycle::{ObservedMachine, observe, relay::Request};
use cmux_cloud_client::machine::Scope;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};

const CAPACITY: usize = 512;

struct Entry {
    scope: Scope,
    op: String,
    machine: String,
    origin: Option<&'static str>,
    pending: Option<Request>,
    result: Option<Value>,
}

#[derive(Default)]
pub(super) struct Ledger {
    entries: HashMap<String, Entry>,
    completed: VecDeque<String>,
}

fn bad(message: impl Into<String>) -> CloudError {
    CloudError::new(codes::BAD_RESPONSE, message)
}

fn conflict(message: impl Into<String>) -> CloudError {
    CloudError::new(codes::CONFLICT, message)
}

impl Ledger {
    pub(super) fn run<C: ControlPlane>(
        &mut self,
        ctx: &mut Ctx<'_, C>,
        op: &str,
        id: &str,
    ) -> Result<Value, CloudError> {
        let key = ctx
            .key()
            .ok_or_else(|| CloudError::invalid("a lifecycle mutation needs a key"))?
            .to_owned();
        // This is a local credential metadata exchange, not an HTTP read.
        // It is advisory only: every subsequent POST is fenced at the host.
        let session = ctx.control_plane().session().map_err(|e| ctx.relay_error(e))?;
        if !session.signed_in {
            return Err(ctx.relay_error(crate::api::RelayError::NotSignedIn));
        }
        let backend = session
            .backend
            .as_deref()
            .ok_or_else(|| bad("credential relay omitted backend identity"))?;
        let team =
            session.team.as_deref().ok_or_else(|| bad("credential relay omitted team identity"))?;
        let scope = Scope::new(backend, Some(team)).map_err(|e| bad(e.to_string()))?;
        if let Some(entry) = self.entries.get(&key) {
            if entry.scope != scope
                || entry.op != op
                || entry.machine != id
                || entry.origin != ctx.origin()
            {
                return Err(CloudError::new(
                    codes::IDEMPOTENCY_CONFLICT,
                    "lifecycle key belongs to another backend, team, operation, machine or origin",
                ));
            }
            if let Some(result) = &entry.result {
                return Ok(result.clone());
            }
        } else {
            if self.entries.len() == CAPACITY {
                if let Some(oldest) = self.completed.pop_front() {
                    self.entries.remove(&oldest);
                } else {
                    return Err(CloudError::new(
                        codes::RELAY_BUSY,
                        "lifecycle ledger is full of unresolved intents; retry an existing key",
                    ));
                }
            }
            // Always observe authoritatively for a new intent. A cached
            // projection may predate a backend switch or an accepted mutation.
            let answer =
                match ctx.fenced_wire("cloud.machine.get", json!({"machine": id}), &scope, None) {
                    Ok(answer) => answer,
                    Err(error)
                        if op == "cloud.machine.delete"
                            && error.code == codes::NOT_FOUND
                            && error.upstream_code.as_deref()
                                == Some("cloud.machine.not_found") =>
                    {
                        // Scoped authoritative absence satisfies idempotent cleanup.
                        // No VM capability or new mutation is fabricated.
                        ctx.projection.remove(id);
                        let result = json!({"deleted": true});
                        self.entries.insert(
                            key.clone(),
                            Entry {
                                scope,
                                op: op.to_owned(),
                                machine: id.to_owned(),
                                origin: ctx.origin(),
                                pending: None,
                                result: Some(result.clone()),
                            },
                        );
                        self.completed.push_back(key);
                        return Ok(result);
                    }
                    Err(error) => return Err(error),
                };
            let machine: Machine = decode_answer("cloud.machine.get", answer.value)?;
            if machine.id() != id {
                return Err(bad("lifecycle observation named another machine"));
            }
            let observed =
                observe(&scope, machine.record.clone()).map_err(|e| bad(e.to_string()))?;
            let pending = prepare(observed, op, &key)?;
            ctx.projection.upsert(machine);
            self.entries.insert(
                key.clone(),
                Entry {
                    scope,
                    op: op.to_owned(),
                    machine: id.to_owned(),
                    origin: ctx.origin(),
                    pending: Some(pending),
                    result: None,
                },
            );
        }
        let entry = self.entries.get_mut(&key).expect("inserted lifecycle intent");
        let pending = entry.pending.as_ref().expect("unresolved lifecycle intent");
        let answer = ctx.fenced_wire(
            pending.op(),
            pending.params(),
            pending.scope(),
            Some((pending.key(), pending.revision())),
        )?;
        let revision = answer.revision.ok_or_else(|| bad("lifecycle mutation omitted revision"))?;
        pending.validate(&answer.value, &revision).map_err(|e| bad(e.to_string()))?;
        // Validate extra fields before consuming the owned request as well.
        let machine: Option<Machine> = if op == "cloud.machine.delete" {
            None
        } else {
            Some(decode_answer(op, answer.value["machine"].clone())?)
        };
        let pending = entry.pending.take().expect("validated lifecycle intent");
        if let Err((pending, error)) = pending.complete(answer.value, revision.clone()) {
            entry.pending = Some(pending);
            return Err(bad(error.to_string()));
        }
        let result = match machine {
            Some(machine) => {
                ctx.projection.upsert(machine.clone());
                json!({"machine": machine, "revision": ctx.projection.revision()})
            }
            None => {
                ctx.projection.remove_at(id, Revision::try_from(revision).map_err(bad)?);
                json!({"deleted": true})
            }
        };
        entry.result = Some(result.clone());
        self.completed.push_back(key);
        Ok(result)
    }
}

fn prepare(observed: ObservedMachine, op: &str, key: &str) -> Result<Request, CloudError> {
    use ObservedMachine::*;
    match (op, observed) {
        ("cloud.machine.pause", Running(vm)) => Ok(vm.prepare_pause(key)),
        ("cloud.machine.start", Paused(vm)) => Ok(vm.prepare_resume(key)),
        ("cloud.machine.delete", Provisioning(vm)) => Ok(vm.prepare_delete(key)),
        ("cloud.machine.delete", Running(vm)) => Ok(vm.prepare_delete(key)),
        ("cloud.machine.delete", Pausing(vm)) => Ok(vm.prepare_delete(key)),
        ("cloud.machine.delete", Paused(vm)) => Ok(vm.prepare_delete(key)),
        ("cloud.machine.delete", Starting(vm)) => Ok(vm.prepare_delete(key)),
        ("cloud.machine.delete", Failed(vm)) => Ok(vm.prepare_delete(key)),
        ("cloud.machine.start", _) => Err(CloudError::new(
            codes::NOT_PAUSED,
            "only a paused machine can be started; reconcile its original key",
        )),
        ("cloud.machine.pause", _) => Err(CloudError::new(
            codes::NOT_RUNNING,
            "only a running machine can be paused; reconcile its original key",
        )),
        _ => Err(conflict(
            "machine state does not permit this lifecycle intent; reconcile its original key",
        )),
    }
}
