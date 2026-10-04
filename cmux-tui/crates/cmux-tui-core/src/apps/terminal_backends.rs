//! The supervisor's side of `cmux.terminal.backend/1`: the host ops
//! `cmux.terminal.backend.open`, `.resume` and `cmux.terminal.channel.open`,
//! the tab-less session-host terminal, and its placement.
//!
//! Placement: the session host creates a catalog-owned terminal with zero
//! views and broadcasts `apps-terminal {terminal, terminal_id, id, app,
//! target, run_key}`. The client that made the gesture knows its run key and
//! gives the terminal its first view with `terminal.project` in its own
//! focused workspace; others ignore it. A terminal that never had a view
//! 60 s after its open is closed; one that had a view stays.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::supervisor::{Out, Supervisor};
use crate::terminal_backend::channel::ChannelEnd;
use crate::terminal_backend::pty::{BackendSide, SendLine};
use crate::terminal_backend::terminals::{ChannelRequest, SshTransport};
use crate::terminal_backend::{BACKEND_INTERFACE, BackendError, OpenTokenGate, PtyRequest, wire};

/// How long a tab-less terminal waits for its client to place it.
pub(super) const PLACEMENT: Duration = Duration::from_secs(60);

/// One backend terminal's surface and placement deadline.
pub(crate) struct Placement {
    pub surface: crate::SurfaceId,
    pub deadline: Instant,
}

/// Backend terminal state beside the channel table.
pub(crate) struct Backends {
    pub placements: Mutex<HashMap<String, Placement>>,
    pub ssh: Mutex<Box<dyn SshTransport>>,
}

impl Default for Backends {
    fn default() -> Self {
        Self {
            placements: Mutex::new(HashMap::new()),
            ssh: Mutex::new(Box::new(crate::terminal_backend::terminals::NoSshTransport)),
        }
    }
}

impl Supervisor {
    /// A backend host op of `app`; `None` when `op` is not one.
    pub(super) fn backend_host_request(
        &self,
        app: &str,
        op: &str,
        params: &Value,
        gate: &dyn OpenTokenGate,
    ) -> Option<Result<Value, BackendError>> {
        Some(match op {
            wire::BACKEND_OPEN => self.backend_open(app, params, gate, Instant::now()),
            wire::BACKEND_RESUME => self.backend_resume(app, params, gate),
            wire::CHANNEL_OPEN => self.channel_open(app, params),
            _ => return None,
        })
    }

    /// `cmux.terminal.backend.open`: the checks, then the tab-less session
    /// host terminal; answers `{terminal, window_bytes}`.
    pub(super) fn backend_open(
        &self,
        app: &str,
        params: &Value,
        gate: &dyn OpenTokenGate,
        now: Instant,
    ) -> Result<Value, BackendError> {
        let request = wire::terminal_open_from_params(params);
        let declaration = self.terminal_declaration(app, BACKEND_INTERFACE);
        let backends = &self.terminals.backends;
        let (terminal, window_bytes) = backends.open(app, declaration, request, gate)?;
        let side = BackendSide {
            channels: backends.channels().clone(),
            terminal: terminal.clone(),
            send: self.server_sender(app),
        };
        let created = match self.router.spawn_backend_terminal(side) {
            Ok(created) => created,
            Err(error) => {
                let _ = backends.close(&terminal);
                return Err(BackendError::Unavailable {
                    reason: error.to_string(),
                    retryable: false,
                });
            }
        };
        let placement = Placement { surface: created.surface, deadline: now + PLACEMENT };
        self.terminals.backend.placements.lock().unwrap().insert(terminal.clone(), placement);
        let me = self.me.clone();
        self.timers.schedule(PLACEMENT, move || {
            if let Some(me) = me.upgrade() {
                me.close_unplaced_terminals_at(Instant::now());
            }
        });
        let (_, meta) = backends.get(&terminal).ok_or_else(BackendError::not_open)?;
        self.emit(vec![Out::Broadcast(json!({
            "event": "apps-terminal", "terminal": terminal, "app": app,
            "terminal_id": created.terminal_id.as_str(),
            "id": meta.id.as_str(), "target": meta.target, "run_key": meta.run_key,
        }))]);
        Ok(json!({ "terminal": terminal, "window_bytes": window_bytes }))
    }

    /// `cmux.terminal.backend.resume {terminal, resume_token, open_token}`.
    /// The token is consumed first. Reviving an ended session-host terminal
    /// is not built yet, so a valid resume answers `unsupported`.
    fn backend_resume(
        &self,
        app: &str,
        params: &Value,
        gate: &dyn OpenTokenGate,
    ) -> Result<Value, BackendError> {
        let token = crate::terminal_backend::OpenToken(
            params.get("open_token").and_then(Value::as_str).unwrap_or("").to_owned(),
        );
        token.check()?;
        let used = gate.consume(token.as_str(), app).ok_or_else(|| {
            BackendError::denied(
                "open_token is not valid: unknown, expired, used, or another app's",
            )
        })?;
        let declaration = self.terminal_declaration(app, BACKEND_INTERFACE)?;
        if !declaration.open_ops.contains(&used.op) {
            return Err(BackendError::denied(format!("{} is not in options.openOps", used.op)));
        }
        Err(BackendError::Unsupported)
    }

    /// `cmux.terminal.channel.open {terminal, connection, pty, command?}`:
    /// only for an open terminal this app holds (its open consumed the
    /// token); the transport does the rest.
    fn channel_open(&self, app: &str, params: &Value) -> Result<Value, BackendError> {
        let terminal = params.get("terminal").and_then(Value::as_str).unwrap_or_default();
        match self.terminals.backends.get(terminal) {
            Some((owner, _)) if owner == app => {}
            _ => {
                return Err(BackendError::denied(format!(
                    "{app} holds no open terminal {terminal:?}"
                )));
            }
        }
        let pty = &params["pty"];
        let size =
            |key: &str| pty.get(key).and_then(Value::as_u64).and_then(|v| u16::try_from(v).ok());
        let request = ChannelRequest {
            connection: params.get("connection").and_then(Value::as_str).unwrap_or_default().into(),
            pty: PtyRequest {
                term: pty.get("term").and_then(Value::as_str).unwrap_or("xterm-256color").into(),
                cols: size("cols").ok_or_else(|| BackendError::invalid("pty.cols is missing"))?,
                rows: size("rows").ok_or_else(|| BackendError::invalid("pty.rows is missing"))?,
            },
            command: params
                .get("command")
                .and_then(Value::as_array)
                .map(|argv| argv.iter().filter_map(Value::as_str).map(str::to_owned).collect()),
        };
        let open = self.terminals.backend.ssh.lock().unwrap().open(app, terminal, request)?;
        Ok(json!({ "channel": open.channel, "window_bytes": open.window_bytes }))
    }

    /// At `now`, every backend terminal whose deadline passed leaves the
    /// deadline list; the ones that never had a view are closed. Answers the
    /// closed ids.
    pub(crate) fn close_unplaced_terminals_at(&self, now: Instant) -> Vec<String> {
        let due: Vec<(String, crate::SurfaceId)> = {
            let mut placements = self.terminals.backend.placements.lock().unwrap();
            let due: Vec<String> = placements
                .iter()
                .filter(|(_, p)| p.deadline <= now)
                .map(|(t, _)| t.clone())
                .collect();
            due.into_iter().filter_map(|t| placements.remove(&t).map(|p| (t, p.surface))).collect()
        };
        let mut closed = Vec::new();
        for (terminal, surface) in due {
            if !self.router.backend_terminal_viewed(surface) {
                // The surface's killer closes the channel and tells the app.
                self.router.close_backend_terminal(surface);
                closed.push(terminal);
            }
        }
        closed.sort();
        closed
    }

    /// A backend terminal ended: an unplaced one leaves the session host.
    /// Runs outside the supervisor lock (the mux is called).
    pub(super) fn backend_terminal_ended(&self, ended: &ChannelEnd) -> Out {
        let placement = self.terminals.backend.placements.lock().unwrap().remove(&ended.channel);
        if let Some(placement) = placement {
            // Only a never-viewed terminal goes; a viewed one keeps its views.
            self.router.close_backend_terminal(placement.surface);
        }
        Out::Broadcast(json!({
            "event": "apps-terminal-ended", "terminal": ended.channel, "app": ended.app,
        }))
    }

    /// Sends lines to `app`'s current server.
    pub(super) fn server_sender(&self, app: &str) -> SendLine {
        let (me, app) = (self.me.clone(), app.to_owned());
        std::sync::Arc::new(move |line: Value| {
            if let Some(me) = me.upgrade() {
                me.send_to_server(&app, &line);
            }
        })
    }
}
