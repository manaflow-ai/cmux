//! `external` app servers (servers.rs, app-platform.md "Server kinds"): a
//! process the person starts, in any language, serves the app's catalog ops
//! over the daemon's control socket with an app credential the person
//! approved.
//!
//! Wire (local connections only):
//! - `apps-server-credential {app}`, origin user (the verified cmux app, A2)
//!   -> `{app, credential}`: a new credential for an installed, enabled app
//!   whose manifest declares an `external` server and whose
//!   `server:execute` the person granted. The daemon keeps only its
//!   SHA-256 (`<state>/apps-credentials/<namespace>`, mode 0600); a new one
//!   replaces the old one and ends a server attached with it. Uninstall
//!   removes it.
//! - `apps-server-attach {app, credential}` -> `{app}`: this connection is
//!   now the app's server, until it closes. Refused: an agent-bound
//!   connection (`apps.origin_forbidden`), no or another credential
//!   (`apps.server_credential`), approval revoked (`apps.server_unapproved`),
//!   an app that is off (`apps.disabled`), safe mode, or a server already
//!   attached (`apps.server_taken`).
//! - event `apps-server-line {app, line}` to that connection only: the
//!   native server wire's lines (`{"type":"op",...}`, `op.cancel`, and
//!   `{"type":"stop"}` before the daemon lets it go).
//! - `apps-server-line {app, line}` from that connection -> `{}`: a
//!   `{"type":"result",...}` or `{"type":"event",...}` line, nothing else.
//!
//! A call with no server attached answers `apps.server_unavailable` at once
//! (servers.rs `spec`); calls in flight when the connection closes answer
//! `apps.server_exited`.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::mirror::Origin;
use super::servers::{APPROVAL_SCOPE, Server, ServerProcess, ServerSpec};
use super::supervisor::{ApiError, Inner, Out, Supervisor};
use crate::panic_free::RecoverPoison;

/// The prefix of every credential, so a leaked one is recognizable.
const PREFIX: &str = "cmuxsrv1_";

fn digest(credential: &str) -> String {
    Sha256::digest(credential.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

impl Supervisor {
    /// Where `app`'s credential digest lives; `None` without a state
    /// directory (no server runs there, servers.rs `server_dirs`).
    fn credential_path(&self, app: &str) -> Option<PathBuf> {
        let base = self.config.state_dir.as_ref()?;
        Some(base.join("apps-credentials").join(cmux_app_manifest::app_namespace(app)))
    }

    /// Uninstall: the credential goes with the app.
    pub(super) fn remove_server_credential(&self, app: &str) {
        if let Some(path) = self.credential_path(app) {
            let _ = std::fs::remove_file(path);
        }
    }

    /// Why `app` cannot have an external server now, or `Ok`.
    fn external_admitted_locked(inner: &Inner, app: &str) -> Result<(), ApiError> {
        let package = inner
            .catalog
            .packages
            .get(app)
            .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
        if super::servers::kind(package) != Some("external") {
            return Err(ApiError::new(
                "apps.server_unsupported",
                format!("{app} declares no external server"),
            ));
        }
        let Some(record) = inner.mirror.apps.get(app).filter(|r| r.installed) else {
            return Err(ApiError::new("apps.notInstalled", "the app is not installed"));
        };
        if !record.enabled {
            return Err(ApiError::new("apps.disabled", "the app is disabled"));
        }
        if super::safe_mode_bisect::held_off(inner, app) {
            return Err(ApiError::new("apps.safe_mode", super::safe_mode::OFF));
        }
        Self::server_approved_locked(inner, app)
    }

    /// `apps-server-credential`: the person approves a credential for the
    /// app's external server (module docs).
    pub fn server_credential(&self, app: &str, origin: Origin) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new(
                "apps.gesture_required",
                "only you approve an external server's credential, in the cmux app",
            ));
        }
        Self::external_admitted_locked(&self.inner.lock().recover_poison(), app)?;
        let path = self.credential_path(app).ok_or_else(|| {
            ApiError::new(
                "apps.server_failed",
                "this daemon has no state directory, so app servers do not run here",
            )
        })?;
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes)
            .map_err(|e| ApiError::new("apps.server_failed", format!("no randomness: {e}")))?;
        let credential =
            format!("{PREFIX}{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
        write_private(&path, &digest(&credential))
            .map_err(|e| ApiError::new("apps.server_failed", format!("credential: {e}")))?;
        // The old credential is void: a server attached with it goes.
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            self.stop_server_locked(&mut inner, app, "a new credential replaced its credential")
        };
        self.emit(outs);
        Ok(json!({ "app": app, "credential": credential }))
    }

    /// `apps-server-attach`: `client` becomes `app`'s external server.
    pub fn server_attach(
        &self,
        client: u64,
        agent: bool,
        app: &str,
        credential: &str,
    ) -> Result<Value, ApiError> {
        if agent {
            return Err(ApiError::new(
                "apps.origin_forbidden",
                "an agent connection cannot serve an app",
            ));
        }
        // Read before the lock: a file read never runs under it.
        let stored = self.credential_path(app).and_then(|p| std::fs::read_to_string(p).ok());
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            Self::external_admitted_locked(&inner, app)?;
            let Some(stored) = stored else {
                return Err(ApiError::new(
                    "apps.server_credential",
                    format!("no credential for {app} was approved: approve one in the cmux app"),
                ));
            };
            if credential.is_empty() || digest(credential) != stored.trim() {
                return Err(ApiError::new(
                    "apps.server_credential",
                    format!("this is not the credential approved for {app}"),
                ));
            }
            if inner.servers.contains_key(app) {
                return Err(ApiError::new(
                    "apps.server_taken",
                    format!("another connection serves {app}"),
                ));
            }
            let sink = inner.sinks.get(&client).cloned().ok_or_else(|| {
                ApiError::new("apps.server_failed", "this connection receives no events")
            })?;
            let generation = inner.next_generation;
            inner.next_generation += 1;
            let (me, app_id) = (self.me.clone(), app.to_string());
            let process = ServerProcess::external(
                app,
                move |frame| sink(frame),
                move |exit| {
                    if let Some(me) = me.upgrade() {
                        me.server_exit(&app_id, generation, exit);
                    }
                },
            )
            .map_err(|e| ApiError::new("apps.server_failed", format!("could not attach: {e}")))?;
            inner.servers.insert(
                app.to_string(),
                Server {
                    generation,
                    process: Arc::new(process),
                    spec: ServerSpec {
                        binary: PathBuf::new(),
                        args: Vec::new(),
                        always: false,
                        idle: None,
                    },
                    pending: Default::default(),
                    user_ops: Default::default(),
                    queued: Vec::new(),
                    next_id: 0,
                    idle: None,
                    stopping: false,
                    kill: None,
                    client: Some(client),
                },
            );
            let mut outs =
                self.log_locked(&mut inner, app, "info", "external server connected".into());
            outs.push(Out::Broadcast(
                json!({ "event": "apps-server", "app": app, "state": "running" }),
            ));
            outs
        };
        self.emit(outs);
        Ok(json!({ "app": app, "scope": APPROVAL_SCOPE }))
    }

    /// `apps-server-line` from the connection serving `app`.
    pub fn server_line_from(&self, client: u64, app: &str, line: Value) -> Result<Value, ApiError> {
        let generation = {
            let inner = self.inner.lock().recover_poison();
            let Some(server) = inner.servers.get(app).filter(|s| s.client == Some(client)) else {
                return Err(ApiError::new(
                    "apps.server_not_attached",
                    format!("this connection does not serve {app}"),
                ));
            };
            server.generation
        };
        if !matches!(line.get("type").and_then(Value::as_str), Some("result" | "event")) {
            return Err(ApiError::new(
                "bad-request",
                "an external server sends result and event lines only",
            ));
        }
        self.server_line(app, generation, line);
        Ok(json!({}))
    }

    /// A control connection closed: the servers it attached end, and their
    /// calls in flight fail when the writer has stopped (`server_exit`).
    pub(super) fn external_disconnect_locked(&self, inner: &mut Inner, client: u64) -> Vec<Out> {
        let apps: Vec<String> = inner
            .servers
            .iter()
            .filter(|(_, s)| s.client == Some(client))
            .map(|(app, _)| app.clone())
            .collect();
        let mut outs = Vec::new();
        for app in apps {
            if let Some(server) = inner.servers.get(&app) {
                server.process.kill();
            }
            outs.extend(self.log_locked(
                inner,
                &app,
                "info",
                "external server disconnected".into(),
            ));
        }
        outs
    }
}

/// Writes `text` to `path` readable by this user only (directory 0700, file
/// 0600), through a temporary file and a rename.
fn write_private(path: &std::path::Path, text: &str) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent"))?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let tmp = path.with_extension("tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    std::fs::rename(&tmp, path)
}
