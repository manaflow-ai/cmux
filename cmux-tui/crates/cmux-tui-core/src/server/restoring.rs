//! The owner's socket while it restores its session (cx-n3bs).
//!
//! An owner binds its session socket before the heavy restore (registry
//! load, terminal host adoption) and serves it from the start. Until the
//! restored `Mux` is attached, every connection gets the restoring answer:
//! `identify` reports `lifecycle_ready: false` with `restoring: true`, and
//! any other request fails with `server.restoring`. `server ensure` reads
//! that as a live owner that is still starting and waits for it, instead of
//! seeing no owner, killing it, or starting a second one.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use serde_json::{Value, json};

use super::listen::{BoundSocket, ServedSession, spawn_accept_loop};
use super::{PROTOCOL_VERSION, PendingServer, RenderService, cleanup};
use crate::mux::Mux;
use crate::platform::transport;

/// Restoring connections answered at once; more are closed at accept. Each
/// one is a short identify probe, so the bound only limits a flood.
const MAX_RESTORING_CONNECTIONS: usize = 64;
/// A restoring connection that sends nothing for this long is closed.
const RESTORING_IDLE: Duration = Duration::from_secs(30);
/// Longest request line a restoring connection reads.
const RESTORING_LINE_LIMIT: u64 = 64 * 1024;

/// A bound session socket served before the session exists. Dropping it
/// without `attach` stops the accept loop and removes the socket file.
pub struct RestoringServer {
    path: PathBuf,
    attached: bool,
    served: Arc<OnceLock<ServedSession>>,
    shutdown: Arc<AtomicBool>,
}

impl BoundSocket {
    /// Serve this socket while the owner of `session` restores it: clients
    /// that connect now learn that the owner is alive and still restoring.
    pub fn serve_restoring(self, session: &str) -> anyhow::Result<RestoringServer> {
        let served = Arc::new(OnceLock::new());
        let shutdown = Arc::new(AtomicBool::new(false));
        let (path, listener) = self.into_parts();
        if let Err(error) =
            spawn_accept_loop(listener, served.clone(), shutdown.clone(), session.to_string())
        {
            cleanup(&path);
            return Err(error.into());
        }
        Ok(RestoringServer { path, attached: false, served, shutdown })
    }
}

impl RestoringServer {
    /// Hand the socket to the restored session. Connections accepted from
    /// now on are served by `mux`; the lifecycle endpoint stays not ready
    /// until the caller marks the returned server ready.
    pub fn attach(mut self, mux: Arc<Mux>) -> PendingServer {
        // The settings owner (settings-v1) reads the settings file and starts
        // its watcher before the session serves its first client.
        mux.start_default_settings_owner();
        let _ = self.served.set(ServedSession {
            mux: mux.clone(),
            render_service: Arc::new(RenderService::new()),
        });
        self.attached = true;
        PendingServer::from_parts(std::mem::take(&mut self.path), mux, self.shutdown.clone())
    }
}

impl Drop for RestoringServer {
    fn drop(&mut self) {
        if self.attached {
            return;
        }
        self.shutdown.store(true, Ordering::Release);
        // Wake the blocked accept so the loop sees the shutdown flag.
        let _ = transport::connect(&self.path);
        cleanup(&self.path);
    }
}

/// Answers connections accepted before the session is attached.
pub(super) struct RestoringAnswers {
    session: String,
    active: Arc<AtomicUsize>,
}

impl RestoringAnswers {
    pub(super) fn new(session: String) -> Self {
        Self { session, active: Arc::new(AtomicUsize::new(0)) }
    }

    pub(super) fn answer(
        &self,
        stream: Box<dyn transport::Stream>,
        served: &Arc<OnceLock<ServedSession>>,
    ) {
        if self.active.fetch_add(1, Ordering::AcqRel) >= MAX_RESTORING_CONNECTIONS {
            self.active.fetch_sub(1, Ordering::AcqRel);
            return;
        }
        let active = self.active.clone();
        let session = self.session.clone();
        let served = served.clone();
        let spawned = std::thread::Builder::new().name("mux-restoring".into()).spawn(move || {
            answer_restoring(stream, &session, &served);
            active.fetch_sub(1, Ordering::AcqRel);
        });
        if spawned.is_err() {
            self.active.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

/// The identity a restoring owner reports: enough for a client to know the
/// owner is alive, which session it owns, and that it is not ready yet.
fn restoring_identity(session: &str) -> Value {
    json!({
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": PROTOCOL_VERSION,
        "session": session,
        "pid": std::process::id(),
        "lifecycle_ready": false,
        "restoring": true,
    })
}

/// Serve one restoring connection: one answer per request line, until the
/// client closes or goes idle. Once the session is attached the connection
/// ends after its current answer (a later request belongs on a fresh
/// connection to the restored session); a line already read is always
/// answered, so a probe never reads a silent close as a dying owner.
fn answer_restoring(
    stream: Box<dyn transport::Stream>,
    session: &str,
    served: &OnceLock<ServedSession>,
) {
    if stream.set_read_timeout(Some(RESTORING_IDLE)).is_err()
        || stream.set_write_timeout(Some(RESTORING_IDLE)).is_err()
    {
        return;
    }
    let mut connection = BufReader::new(stream);
    loop {
        let mut line = Vec::new();
        match connection.by_ref().take(RESTORING_LINE_LIMIT).read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) if !line.ends_with(b"\n") => return,
            Ok(_) => {}
        }
        let Ok(request) = serde_json::from_slice::<Value>(&line) else { return };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let response = if request.get("cmd").and_then(Value::as_str) == Some("identify") {
            json!({"id": id, "ok": true, "data": restoring_identity(session)})
        } else {
            json!({
                "id": id,
                "ok": false,
                "error": "the session owner is restoring its terminals; retry when it is ready",
                "error_code": "server.restoring",
            })
        };
        let writer = connection.get_mut();
        if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err() {
            return;
        }
        if served.get().is_some() {
            return;
        }
    }
}
