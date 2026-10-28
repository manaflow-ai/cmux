//! Host-only ops of app servers: the `host.request` frames (`servers.rs`
//! has the rest of the wire).
//!
//! Host-only ops (one shape for every op the host answers), server ->
//! supervisor `{"t":"host.request","id":1,"op":"cmux.host.…","params":{}}`;
//! supervisor -> server `{"t":"host.result","id":1,"value":{}}` or
//! `{"t":"host.error","id":1,"code","message","retryable"}`. Host events,
//! supervisor -> server: `{"t":"host.event","op":"cmux.host.…","data":{}}`.
//! The id is the server's own (any JSON value), echoed back.
//! - `cmux.host.link.get {}` -> `{binary, hub_socket, state_dir,
//!   socket_dir, device_name}` from the daemon's own values (see
//!   [`Supervisor::host_link`]; `hub_socket` is the live link
//!   registration's socket, `null` only when no live registration exists;
//!   a probe that does not finish answers `host.error`
//!   `apps.link_probe_timeout`, retryable); event `cmux.host.link.changed`
//!   with the same value, sent on `apps-link-changed` (verified app only). `socket_dir` is checked on every answer
//!   (server_tmp.rs): a folder that is no longer the user's private folder
//!   answers `host.error` `apps.socket_dir_unsafe`. Needs server scope `op:cmux.host.link.get` and a
//!   first-party app, else `host.error` `apps.scope_missing`.
//! - `cmux.credential.relay` as a `host.request` answers `host.error`
//!   `unavailable`: the relay is served for the server's `relay.op` and
//!   `relay.session` lines (`relay.rs`), which the scope
//!   `op:cmux.credential.relay` allows; no user credential enters the daemon.
//! - Any other `cmux.host.*` op answers `host.error` `apps.op.unknown`.

use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::fs as files;
use cmux_threads::checked::sync as waits;
use serde_json::{Value, json};

use super::mirror::Tier;
use super::servers::line;
use super::supervisor::{Inner, Supervisor};
use crate::panic_free::RecoverPoison;

/// Why the link details could not be given.
pub(super) enum HostLinkError {
    /// The server's socket folder failed its check (cx-wmd8x): stop it.
    UnsafeFolder(String),
    /// The link registration exists but its liveness probe did not finish
    /// in time: nothing is known, so no `null` hub is reported.
    ProbeTimeout,
}

impl Supervisor {
    /// `cmux.host.link.get` for `app`: the daemon executable, the WireGuard
    /// hub socket, a link state directory in the app's data directory, the
    /// app's temporary directory for link sockets, and this machine's name.
    ///
    /// `hub_socket` comes from the link agent's registration (lane 12,
    /// `<daemon state dir>/link.json`, `cmux_link::registration`) and is set
    /// only while that link runs (its pid is alive and its socket accepts);
    /// otherwise `null`, and the Cloud server answers `link_unavailable`.
    /// The daemon never spawns the link and never reads it from its launch
    /// environment.
    /// The socket folder is checked on every answer (cx-wmd8x, server_tmp.rs):
    /// one that is no longer this user's private folder refuses.
    pub(super) fn host_link(&self, app: &str) -> Result<Value, HostLinkError> {
        let (data, tmp) = self.server_dirs(app).map_err(HostLinkError::UnsafeFolder)?;
        super::server_tmp::check_server_tmp(&tmp).map_err(HostLinkError::UnsafeFolder)?;
        let state_dir = data.join("link");
        let _ = files::create_dir_all(&state_dir);
        let hub = hub_socket().ok_or(HostLinkError::ProbeTimeout)?;
        Ok(json!({
            "binary": std::env::current_exe().ok(),
            "hub_socket": hub,
            "state_dir": state_dir,
            "socket_dir": tmp,
            "device_name": device_name(),
        }))
    }

    /// Whether `app` may call the host op `op`: a first-party app whose
    /// manifest declares the server scope `op:<op>`.
    pub(super) fn host_op_allowed(inner: &Inner, app: &str, op: &str) -> bool {
        inner.catalog.packages.get(app).is_some_and(|package| {
            package.tier == Tier::FirstParty
                && package
                    .manifest
                    .pointer("/server/scopes")
                    .and_then(Value::as_object)
                    .is_some_and(|scopes| scopes.contains_key(&format!("op:{op}")))
        })
    }

    /// Answers one `host.request` frame of `app`'s server, outside the supervisor lock
    /// (`allowed`: the server holds `op:cmux.host.link.get`, read under the lock). The
    /// second value is set when the socket folder failed its check (cx-wmd8x): the caller
    /// stops that server, so it never keeps binding in a folder that is no longer private.
    pub(super) fn host_request(
        &self,
        app: &str,
        allowed: bool,
        request: &Value,
    ) -> (Value, Option<String>) {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let error = |code: &str, message: &str, retryable: bool| json!({ "t": "host.error", "id": id, "code": code, "message": message, "retryable": retryable });
        match request["op"].as_str().unwrap_or_default() {
            "cmux.host.link.get" => {
                if !allowed {
                    return (
                        error(
                            "apps.scope_missing",
                            "the server does not declare op:cmux.host.link.get",
                            false,
                        ),
                        None,
                    );
                }
                match self.host_link(app) {
                    Ok(value) => (json!({ "t": "host.result", "id": id, "value": value }), None),
                    Err(HostLinkError::UnsafeFolder(message)) => {
                        (error("apps.socket_dir_unsafe", &message, false), Some(message))
                    }
                    Err(HostLinkError::ProbeTimeout) => (
                        error("apps.link_probe_timeout", "the link did not answer its probe", true),
                        None,
                    ),
                }
            }
            "cmux.credential.relay" => {
                (error("unavailable", "the cmux credential relay is not available yet", true), None)
            }
            op => (error("apps.op.unknown", &format!("the host has no op {op}"), false), None),
        }
    }

    /// Stops `app`'s server after its socket folder failed a check (cx-wmd8x).
    pub(super) fn stop_for_unsafe_folder(&self, app: &str, reason: &str) {
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            let mut outs = self.log_locked(&mut inner, app, "error", reason.to_string());
            outs.extend(self.stop_server_locked(
                &mut inner,
                app,
                "its socket folder failed its check",
            ));
            outs
        };
        self.emit(outs);
    }

    /// Sends `cmux.host.link.changed` to every running server that may read
    /// the link. The app calls it (`apps-link-changed`) after `cmux link
    /// ensure` or `stop` changed the link registration; no file watch calls
    /// it (that needs a file-notify dependency in this crate), and a server
    /// that saw no hub asks `cmux.host.link.get` again on its next connect.
    /// The servers are read under the lock; the folder checks run after it is
    /// released, and a server whose folder fails is stopped (cx-wmd8x).
    /// Returns how many servers it told.
    ///
    /// Calls coalesce: while one runs, another call only marks that a new
    /// round is due and returns 0; the running call then runs one more round,
    /// so the last registration change always reaches the servers.
    pub(crate) fn host_link_changed(&self) -> usize {
        {
            let mut state =
                self.link_changed.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.0 {
                state.1 = true;
                return 0;
            }
            *state = (true, false);
        }
        // Clears the running flag however this call ends (a panic too), so
        // a later call always runs.
        struct Running<'a>(&'a std::sync::Mutex<(bool, bool)>);
        impl Drop for Running<'_> {
            fn drop(&mut self) {
                *self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = (false, false);
            }
        }
        let _running = Running(&self.link_changed);
        loop {
            let told = self.host_link_changed_round();
            let mut state =
                self.link_changed.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if !state.1 {
                return told;
            }
            state.1 = false;
        }
    }

    fn host_link_changed_round(&self) -> usize {
        let servers: Vec<(String, std::sync::Arc<super::servers::ServerProcess>)> = {
            let inner = self.inner.lock().recover_poison();
            inner
                .servers
                .iter()
                .filter(|(app, server)| {
                    !server.stopping && Self::host_op_allowed(&inner, app, "cmux.host.link.get")
                })
                .map(|(app, server)| (app.clone(), server.process.clone()))
                .collect()
        };
        let mut told = 0;
        for (app, process) in servers {
            match self.host_link(&app) {
                Ok(data) => {
                    process.send(line(&json!({
                        "t": "host.event", "op": "cmux.host.link.changed", "data": data,
                    })));
                    told += 1;
                }
                Err(HostLinkError::UnsafeFolder(reason)) => {
                    self.stop_for_unsafe_folder(&app, &reason);
                }
                // Nothing known: no event (a server keeps its last details).
                Err(HostLinkError::ProbeTimeout) => {}
            }
        }
        told
    }
}

/// How long the liveness probe of the link registration may take: the
/// caller holds the supervisor lock, and a link with a full accept backlog
/// would block a plain connect.
const LINK_PROBE: std::time::Duration = std::time::Duration::from_millis(500);

/// The live link registration's socket: `Some(Some(socket))` while a link
/// runs, `Some(None)` when no live registration exists (no file, or its
/// process is gone), `None` when the probe did not finish within
/// [`LINK_PROBE`] (unknown: never reported as "no link"). `link.json` is in
/// the daemon state directory, the parent of the link's own `link` folder.
fn hub_socket() -> Option<Option<std::path::PathBuf>> {
    let Some(dir) = crate::platform::workspace_state_dir() else { return Some(None) };
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    supervised::spawn_at(
        "cmux-apps-link-probe",
        cmux_threads::ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let live = cmux_link::registration::read_live(&dir).map(|r| r.socket);
            let _ = sender.send(live);
        },
    )
    .ok()?;
    waits::recv_timeout(&receiver, LINK_PROBE).ok()
}

/// This machine's name, or `cmux`.
fn device_name() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into our buffer.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let used = buf.split(|b| *b == 0).next().unwrap_or_default();
    let name = if ok { String::from_utf8_lossy(used).into_owned() } else { String::new() };
    if name.is_empty() || name.chars().any(char::is_control) { "cmux".into() } else { name }
}
