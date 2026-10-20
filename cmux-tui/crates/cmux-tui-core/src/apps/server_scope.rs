//! An old server must confirm scope support before receiving an operation, not after a side effect.
use super::servers::line;
use super::supervisor::{ApiError, Inner, Out, Supervisor};
use serde_json::{Value, json};
use std::time::Duration;

impl Supervisor {
    pub(super) fn queue_scoped_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        id: String,
        message: Vec<u8>,
    ) {
        let server = inner.servers.get_mut(app).expect("started");
        if server.scope_ready {
            server.process.send(message);
            return;
        }
        server.scoped_queued.push((id, message));
        if server.scope_probe.is_some() {
            return;
        }
        let generation = server.generation;
        let (me, owner) = (self.me.clone(), app.to_owned());
        server.scope_probe = Some(self.timers.schedule(Duration::from_secs(10), move || {
            let Some(me) = me.upgrade() else { return };
            let outs = {
                let mut inner = me.inner.lock().unwrap();
                let Some(server) = inner.servers.get_mut(&owner).filter(|s| {
                    s.generation == generation && !s.scope_ready && s.scope_probe.is_some()
                }) else {
                    return;
                };
                server.scope_probe = None;
                let mut outs = Vec::new();
                for (id, _) in std::mem::take(&mut server.scoped_queued) {
                    server.expected_scopes.remove(&id);
                    server.user_ops.remove(&id);
                    if let Some(respond) = server.pending.remove(&id) {
                        outs.push(Out::Respond(
                            respond,
                            Err(ApiError::new(
                                "apps.scope_unsupported",
                                "the app server did not confirm request-scope support",
                            )),
                        ));
                    }
                }
                outs.extend(me.stop_server_locked(
                    &mut inner,
                    &owner,
                    "request-scope support was not confirmed",
                ));
                outs
            };
            me.emit(outs);
        }));
        server
            .process
            .send(line(&json!({"type": "scope.probe", "id": format!("scope-{generation}")})));
    }

    pub(super) fn scope_ready_locked(&self, inner: &mut Inner, app: &str, frame: &Value) {
        let server = inner.servers.get_mut(app).expect("current");
        if server.stopping || frame["id"] != format!("scope-{}", server.generation) {
            return;
        }
        let Some(timer) = server.scope_probe.take() else { return };
        self.timers.cancel(timer);
        server.scope_ready = true;
        for (_, message) in std::mem::take(&mut server.scoped_queued) {
            server.process.send(message);
        }
    }
}
