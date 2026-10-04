//! The supervisor's side of `cmux.terminal.backend/1`: the host ops
//! `cmux.terminal.backend.open`, `.resume` and `cmux.terminal.channel.open`,
//! the tab-less session-host terminal, and its placement.
//!
//! Placement: the session host creates the terminal with no tab and
//! broadcasts `apps-terminal {terminal, id, app, run_key}`. The client that
//! made the gesture knows its run key and places the terminal in its own
//! focused workspace ([`Supervisor::place_backend_terminal`]); others ignore
//! it. A terminal no client placed within 60 s is closed.

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

/// One tab-less terminal's surface and placement state.
pub(crate) struct Placement {
    pub surface: crate::SurfaceId,
    pub deadline: Instant,
    pub placed: bool,
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
        let surface = match self.router.spawn_backend_terminal(side) {
            Ok(surface) => surface,
            Err(error) => {
                let _ = backends.close(&terminal);
                return Err(BackendError::Unavailable {
                    reason: error.to_string(),
                    retryable: false,
                });
            }
        };
        let placement = Placement { surface, deadline: now + PLACEMENT, placed: false };
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

    /// The client that made the gesture placed `terminal` (tab adopt).
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn place_backend_terminal(&self, terminal: &str) -> Option<crate::SurfaceId> {
        let mut placements = self.terminals.backend.placements.lock().unwrap();
        let placement = placements.get_mut(terminal).filter(|p| !p.placed)?;
        placement.placed = true;
        Some(placement.surface)
    }

    /// Closes every tab-less terminal whose placement deadline passed at
    /// `now`; answers their ids.
    pub(crate) fn close_unplaced_terminals_at(&self, now: Instant) -> Vec<String> {
        let expired: Vec<(String, crate::SurfaceId)> = {
            let placements = self.terminals.backend.placements.lock().unwrap();
            let late = placements.iter().filter(|(_, p)| !p.placed && p.deadline <= now);
            late.map(|(t, p)| (t.clone(), p.surface)).collect()
        };
        for (terminal, surface) in &expired {
            self.terminals.backend.placements.lock().unwrap().remove(terminal);
            // The surface's killer closes the channel and tells the app.
            self.router.close_backend_terminal(*surface);
        }
        expired.into_iter().map(|(terminal, _)| terminal).collect()
    }

    /// A backend terminal ended: an unplaced one leaves the session host.
    /// Runs outside the supervisor lock (the mux is called).
    pub(super) fn backend_terminal_ended(&self, ended: &ChannelEnd) -> Out {
        let placement = self.terminals.backend.placements.lock().unwrap().remove(&ended.channel);
        if let Some(placement) = placement.filter(|p| !p.placed) {
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
