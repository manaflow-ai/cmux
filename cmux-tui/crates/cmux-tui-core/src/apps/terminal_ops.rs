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
    Lost, OpenTokenGate, wire,
};

/// The restricted scope both terminal interfaces need.
pub(super) const TERMINAL_SCOPE: &str = "terminal:backend";

impl OpenTokenGate for Supervisor {
    fn consume(&self, token: &str, app: &str) -> Option<String> {
        self.consume_open_token(token, app).map(|used| used.op)
    }
}

/// The supervisor's token gate at a fixed time (tests inject the clock).
#[cfg_attr(not(test), allow(dead_code))]
pub(super) struct GateAt<'a> {
    pub supervisor: &'a Supervisor,
    pub now: Instant,
}

impl OpenTokenGate for GateAt<'_> {
    fn consume(&self, token: &str, app: &str) -> Option<String> {
        self.supervisor.consume_open_token_at(token, app, self.now).map(|used| used.op)
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
            let reply = match value["op"].as_str().unwrap_or_default() {
                wire::CONNECTOR_OPEN => match self.connector_open(app, &value["params"], gate) {
                    Ok(answer) => wire::link_answer_reply(&id, &answer),
                    Err(error) => wire::error_reply(&id, &error),
                },
                op => json!({
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
        match self.terminals.links.receive_from_app(app, frame) {
            Ok(outcome) => {
                if let Some(ended) = &outcome.ended {
                    self.log_terminal(app, "info", link_end_message(ended));
                    self.emit(vec![self.link_ended(ended)]);
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
    fn terminal_declaration(
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
        let ended = self.terminals.links.end_app(app, &Lost::new("the app server stopped", true));
        self.links_ended_locked(inner, app, &ended)
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
        let ended = self.terminals.links.end_app(app, &Lost::new("access to the app ended", false));
        self.links_ended_locked(inner, app, &ended)
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
