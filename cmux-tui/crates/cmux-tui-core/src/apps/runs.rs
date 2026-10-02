//! `apps-run`: a catalog op of the app (palette, CLI `cmux apps run`, MCP),
//! answered asynchronously. A run with an idempotency key runs once: a
//! retry while it runs waits for the same answer, a retry after it answers
//! gets the stored answer.

use cmux_app_host::ToHost;
use serde_json::Value;

use super::mirror::Origin;
use super::supervisor::{ApiError, HostKey, HostState, Inner, Out, Responder, Supervisor};

/// Answered runs kept for replay.
const RUN_KEYS: usize = 256;

pub(super) enum RunKey {
    Pending(Vec<Responder>),
    Done(Result<Value, ApiError>),
}

impl Supervisor {
    pub fn run(
        &self,
        app: &str,
        op: &str,
        args: Value,
        idempotency_key: Option<String>,
        origin: Origin,
        respond: Responder,
    ) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let respond = match idempotency_key {
                None => respond,
                Some(key) => {
                    match self.keyed_locked(&mut inner, format!("{app}\n{op}\n{key}"), respond) {
                        Ok(respond) => respond,
                        Err(answered) => {
                            drop(inner);
                            self.emit(answered.into_iter().collect());
                            return;
                        }
                    }
                }
            };
            match self.prepare_run(&inner, app, op, origin) {
                Err(error) => vec![Out::Respond(respond, Err(error))],
                Ok((key, export)) => self.start_run_locked(&mut inner, &key, export, args, respond),
            }
        };
        self.emit(outs);
    }

    /// Replays or joins a keyed run. `Ok` is the responder to run with (the
    /// first request for the key); `Err` holds the stored answer to send, or
    /// nothing when the request joined a run in flight.
    fn keyed_locked(
        &self,
        inner: &mut Inner,
        key: String,
        respond: Responder,
    ) -> Result<Responder, Option<Out>> {
        match inner.run_keys.get_mut(&key) {
            Some(RunKey::Done(result)) => Err(Some(Out::Respond(respond, result.clone()))),
            Some(RunKey::Pending(waiters)) => {
                waiters.push(respond);
                Err(None)
            }
            None => {
                inner.run_keys.insert(key.clone(), RunKey::Pending(vec![respond]));
                inner.run_key_order.push_back(key.clone());
                while inner.run_key_order.len() > RUN_KEYS {
                    let Some(oldest) = inner.run_key_order.pop_front() else { break };
                    if matches!(inner.run_keys.get(&oldest), Some(RunKey::Pending(_))) {
                        inner.run_key_order.push_back(oldest);
                        break;
                    }
                    inner.run_keys.remove(&oldest);
                }
                let me = self.me.clone();
                Ok(Box::new(move |result: Result<Value, ApiError>| {
                    let Some(me) = me.upgrade() else { return };
                    let waiters = {
                        let mut inner = me.inner.lock().unwrap();
                        // Only an answer is stored; after a failure a retry runs again.
                        let previous = if result.is_ok() {
                            inner.run_keys.insert(key, RunKey::Done(result.clone()))
                        } else {
                            inner.run_keys.remove(&key)
                        };
                        match previous {
                            Some(RunKey::Pending(waiters)) => waiters,
                            _ => Vec::new(),
                        }
                    };
                    for waiter in waiters {
                        waiter(result.clone());
                    }
                }))
            }
        }
    }

    fn prepare_run(
        &self,
        inner: &Inner,
        app: &str,
        op: &str,
        origin: Origin,
    ) -> Result<(HostKey, String), ApiError> {
        let package = inner
            .catalog
            .packages
            .get(app)
            .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
        let export = package
            .export_for_op(op)
            .ok_or_else(|| ApiError::new("apps.op.unknown", format!("{app} has no op {op}")))?;
        let record = inner.mirror.apps.get(app);
        let Some(record) = record.filter(|r| r.installed) else {
            return Err(ApiError::new("apps.notInstalled", "the app is not installed"));
        };
        if !record.enabled {
            return Err(ApiError::new("apps.disabled", "the app is disabled"));
        }
        // A hidden app answers each automation surface only if its hidden
        // access allows it (V9).
        let reachable = !record.hidden
            || match origin {
                Origin::User => true,
                Origin::Cli | Origin::Remote => record.hidden_access.cli,
                Origin::Mcp => record.hidden_access.mcp,
                Origin::Script => record.hidden_access.automations,
            };
        if !reachable {
            return Err(ApiError::new("apps.hidden", "the app is hidden from this surface"));
        }
        if self.config.host_binary.is_none() {
            return Err(ApiError::new("apps.unavailable", "this daemon has no app host"));
        }
        Ok((HostKey { app: app.to_string(), preview: false }, export))
    }

    fn start_run_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        export: String,
        args: Value,
        respond: Responder,
    ) -> Vec<Out> {
        let fresh = !inner.hosts.contains_key(key);
        if fresh {
            inner.hosts.insert(key.clone(), super::hosts::new_host());
        }
        let host = inner.hosts.get_mut(key).expect("host");
        if let Some(timer) = host.idle.take() {
            self.timers.cancel(timer);
        }
        let cb = host.next_cb;
        host.next_cb += 1;
        host.runs.insert(cb, respond);
        let message = ToHost::Run { cb, export, args };
        match (host.state, host.process.clone()) {
            (HostState::Starting | HostState::Running, Some(process)) => process.send(&message),
            (HostState::Stopping, Some(_)) => {
                host.state = HostState::Restarting;
                host.queued_runs.push(message);
            }
            _ => host.queued_runs.push(message),
        }
        if fresh { self.spawn_locked(inner, key) } else { vec![] }
    }
}
