//! The supervisor's side of the terminal interfaces: the host op
//! `cmux.terminal.connector.open` and the `data`/`credit`/`end` frames of
//! connector links on a native server's stdin and stdout
//! (crate::terminal_backend has the registry and the wire form).
//!
//! The open token check: the supervisor stamps a token into a user-origin
//! run of one of the app's catalog ops (servers.rs, Cloud C10); the server
//! passes it on in `cmux.terminal.connector.open`; [`LinkRegistry::open`]
//! consumes it through [`OpenTokenGate`] before it checks anything else.
//! Besides the token, the app must implement the interface with its server
//! and hold a grant of the restricted scope `terminal:backend`.
//!
//! Locking: the supervisor lock is never held while the registry consumes a
//! token (the gate takes that lock itself). Lock order is supervisor, then
//! registry; the registry never calls back into the supervisor.

use std::time::Instant;

use serde_json::{Value, json};

use super::supervisor::{HostKey, Inner, Out, Supervisor};
use crate::terminal_backend::{
    BackendError, CONNECTOR_INTERFACE, Declaration, FrameBody, LinkAnswer, LinkEvent, LinkRegistry,
    Lost, OpenTokenGate, TokenUse, wire,
};

/// The restricted scope both terminal interfaces need.
pub(super) const TERMINAL_SCOPE: &str = "terminal:backend";

impl OpenTokenGate for Supervisor {
    fn consume(&self, token: &str, app: &str) -> Option<TokenUse> {
        let used = self.consume_open_token(token, app)?;
        Some(TokenUse { op: used.op, run_key: used.idempotency_key })
    }
}

/// The supervisor's token gate at a fixed time (tests inject the clock).
#[cfg_attr(not(test), allow(dead_code))]
pub(super) struct GateAt<'a> {
    pub supervisor: &'a Supervisor,
    pub now: Instant,
}

impl OpenTokenGate for GateAt<'_> {
    fn consume(&self, token: &str, app: &str) -> Option<TokenUse> {
        let used = self.supervisor.consume_open_token_at(token, app, self.now)?;
        Some(TokenUse { op: used.op, run_key: used.idempotency_key })
    }
}

impl Supervisor {
    /// The registry of connector links on this machine.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn terminal_links(&self) -> &LinkRegistry {
        &self.terminals.links
    }

    /// True for a server line of the terminal interfaces: a frame, or a
    /// `host.request` for a `cmux.terminal.*` op.
    pub(super) fn is_terminal_line(value: &Value) -> bool {
        let t = value["t"].as_str().unwrap_or_default();
        wire::FRAME_TYPES.contains(&t)
            || (t == "host.request"
                && value["op"].as_str().is_some_and(|op| op.starts_with("cmux.terminal.")))
    }

    /// Handles one terminal line of `app`'s server. Runs without the
    /// supervisor lock held; answers the lines to write back to the server.
    pub(super) fn terminal_line(&self, app: &str, value: &Value) -> Vec<Value> {
        self.terminal_line_with(app, value, self)
    }

    pub(super) fn terminal_line_with(
        &self,
        app: &str,
        value: &Value,
        gate: &dyn OpenTokenGate,
    ) -> Vec<Value> {
        if value["t"] == "host.request" {
            let id = value.get("id").cloned().unwrap_or(Value::Null);
            let op = value["op"].as_str().unwrap_or_default();
            let params = &value["params"];
            let result = if op == wire::CONNECTOR_OPEN {
                Some(self.connector_open(app, params, gate).map(|a| wire::link_answer_value(&a)))
            } else {
                self.backend_host_request(app, op, params, gate)
            };
            let reply = match result {
                Some(Ok(value)) => wire::result_reply(&id, value),
                Some(Err(error)) => wire::error_reply(&id, &error),
                None => json!({
                    "t": "host.error", "id": id, "code": "apps.op.unknown",
                    "message": format!("the host has no op {op}"), "retryable": false,
                }),
            };
            return vec![reply];
        }
        let frame = match wire::frame_from_json(value) {
            Ok(frame) => frame,
            Err(error) => {
                self.log_terminal(app, "warn", format!("terminal frame ignored: {error}"));
                return vec![];
            }
        };
        let is_end = matches!(frame.body, FrameBody::End(_));
        let terminal = frame.channel.starts_with("term-");
        let outcome = if terminal {
            self.terminals.backends.receive_from_app(app, frame)
        } else {
            self.terminals.links.receive_from_app(app, frame)
        };
        match outcome {
            Ok(outcome) => {
                if let Some(ended) = &outcome.ended {
                    self.log_terminal(app, "info", link_end_message(ended));
                    let out = if terminal {
                        self.backend_terminal_ended(ended)
                    } else {
                        self.link_ended(ended)
                    };
                    self.emit(vec![out]);
                }
                outcome.to_app.iter().map(wire::frame_to_json).collect()
            }
            // The `end` an app owes after a host close finds no link: expected.
            Err(BackendError::Invalid { .. }) if is_end => vec![],
            Err(error) => {
                self.log_terminal(app, "warn", format!("terminal frame ignored: {error}"));
                vec![]
            }
        }
    }

    fn connector_open(
        &self,
        app: &str,
        params: &Value,
        gate: &dyn OpenTokenGate,
    ) -> Result<LinkAnswer, BackendError> {
        let request = wire::link_open_from_params(params);
        let declaration = self.terminal_declaration(app, CONNECTOR_INTERFACE);
        let answer = self.terminals.links.open(app, declaration, request, gate)?;
        self.start_link_relay(app, &answer);
        Ok(answer)
    }

    /// What `app` declares for `interface`, when it may serve it at all: an
    /// installed app whose grant holds `terminal:backend`.
    pub(super) fn terminal_declaration(
        &self,
        app: &str,
        interface: &str,
    ) -> Result<Declaration, BackendError> {
        let inner = self.inner.lock().unwrap();
        let package = inner
            .catalog
            .packages
            .get(app)
            .ok_or_else(|| BackendError::denied(format!("{app} is not installed")))?;
        let declaration = Declaration::from_manifest(&package.manifest, interface)?;
        let key = HostKey { app: app.to_owned(), preview: false };
        if !Self::grant_for(&inner, &key).scopes.contains(TERMINAL_SCOPE) {
            return Err(BackendError::denied(format!("{app} is not granted {TERMINAL_SCOPE}")));
        }
        Ok(declaration)
    }

    /// The host closes a link: the registry ends it now and the app's server
    /// gets `cmux.terminal.connector.close {channel}`; its later `end` frame
    /// finds no link and is dropped. The relay's client leaving calls this.
    pub(crate) fn close_terminal_link(&self, channel: &str) -> Result<LinkEvent, BackendError> {
        let event = self.terminals.links.close(channel)?;
        let ended = self.link_ended(&event);
        {
            let inner = self.inner.lock().unwrap();
            if let Some(server) = inner.servers.get(&event.app) {
                let mut line = wire::close_event(channel).to_string().into_bytes();
                line.push(b'\n');
                server.process.send(line);
            }
        }
        self.emit(vec![ended]);
        Ok(event)
    }

    /// `app`'s server stopped or exited: every link it held ends, and the
    /// far ends see `lost` (a new user run reconnects).
    pub(super) fn terminal_server_gone_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let lost = Lost::new("the app server stopped", true);
        let ended = self.terminals.links.end_app(app, &lost);
        let mut outs = self.links_ended_locked(inner, app, &ended);
        outs.extend(self.terminals_ended_locked(inner, app, &lost));
        outs
    }

    /// After a disable, uninstall or grant change: when `app` may no longer
    /// serve terminals (not installed and enabled, or no `terminal:backend`
    /// grant), every link it holds ends with a lost that is not retryable.
    pub(super) fn terminal_access_changed_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let enabled = inner.mirror.apps.get(app).is_some_and(|r| r.installed && r.enabled);
        let key = HostKey { app: app.to_owned(), preview: false };
        if enabled && Self::grant_for(inner, &key).scopes.contains(TERMINAL_SCOPE) {
            return vec![];
        }
        let lost = Lost::new("access to the app ended", false);
        let ended = self.terminals.links.end_app(app, &lost);
        let mut outs = self.links_ended_locked(inner, app, &ended);
        outs.extend(self.terminals_ended_locked(inner, app, &lost));
        outs
    }

    /// Ends `app`'s backend terminals under the supervisor lock; the session
    /// host side (the mux) runs on the timer thread, outside the lock.
    fn terminals_ended_locked(&self, inner: &mut Inner, app: &str, lost: &Lost) -> Vec<Out> {
        let ended = self.terminals.backends.end_app(app, lost);
        let mut outs = Vec::new();
        for event in &ended {
            outs.extend(self.log_locked(inner, app, "info", link_end_message(event)));
        }
        if !ended.is_empty() {
            let me = self.me.clone();
            self.timers.schedule(std::time::Duration::ZERO, move || {
                if let Some(me) = me.upgrade() {
                    let outs = ended.iter().map(|e| me.backend_terminal_ended(e)).collect();
                    me.emit(outs);
                }
            });
        }
        outs
    }

    fn links_ended_locked(&self, inner: &mut Inner, app: &str, ended: &[LinkEvent]) -> Vec<Out> {
        let mut outs = Vec::new();
        for event in ended {
            outs.extend(self.log_locked(inner, app, "info", link_end_message(event)));
            outs.push(self.link_ended(event));
        }
        outs
    }

    pub(super) fn log_terminal(&self, app: &str, level: &str, message: String) {
        let outs = self.log_locked(&mut self.inner.lock().unwrap(), app, level, message);
        self.emit(outs);
    }
}

fn link_end_message(event: &LinkEvent) -> String {
    format!("terminal link {} ended: {:?}", event.channel, event.end)
}
