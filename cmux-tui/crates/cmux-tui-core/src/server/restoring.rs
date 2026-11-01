//! The owner's socket while it restores its session (cx-n3bs).
//!
//! An owner binds its session socket before the heavy restore (registry
//! load, terminal host adoption), so the socket names the one live owner for
//! the whole restore. Until the restored `Mux` is attached, accepted
//! connections are parked unread; on attach each one goes to the normal
//! protocol handler, which then reads the client's first request. A client
//! that connects as soon as the socket file exists is served exactly as
//! before, only later. `server ensure` reads an unanswered identify as a
//! live owner that is still starting and waits for it, instead of seeing no
//! owner, killing it, or starting a second one.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use super::listen::{BoundSocket, ServedSession, spawn_accept_loop};
use super::{PendingServer, RenderService, cleanup};
use crate::mux::Mux;
use crate::platform::transport;

/// Connections parked while the owner restores. At the cap the oldest one is
/// refused with the busy line (`listen::refuse_busy`), so a client that
/// already wrote a request knows to retry it: it is almost always a
/// `server ensure` probe that already gave up
/// (each probe parks one connection per ~2 s identify timeout), and the
/// newest probe must stay parked to read as a live owner. Half the server's
/// connection permits, so attach can serve every parked one.
const MAX_PARKED_CONNECTIONS: usize = super::MAX_SERVER_CONNECTIONS / 2;

/// Where the accept loop sends a connection: parked until the session is
/// attached, then served.
pub(super) struct SessionSlot {
    state: Mutex<SlotState>,
}

enum SlotState {
    Restoring(VecDeque<Box<dyn transport::Stream>>),
    Served(ServedSession),
}

impl SessionSlot {
    fn restoring() -> Self {
        Self { state: Mutex::new(SlotState::Restoring(VecDeque::new())) }
    }

    /// The session to serve `stream` now, or None when it was parked.
    pub(super) fn route(
        &self,
        stream: Box<dyn transport::Stream>,
    ) -> Option<(ServedSession, Box<dyn transport::Stream>)> {
        let evicted = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            match &mut *state {
                SlotState::Served(session) => return Some((session.clone(), stream)),
                SlotState::Restoring(parked) => {
                    let evicted = (parked.len() >= MAX_PARKED_CONNECTIONS)
                        .then(|| parked.pop_front())
                        .flatten();
                    parked.push_back(stream);
                    evicted
                }
            }
        };
        // Outside the slot lock: the busy line's write is bounded, but the
        // accept loop must not hold the lock while it waits on a client.
        if let Some(evicted) = evicted {
            super::listen::refuse_busy(evicted);
        }
        None
    }

    /// Attach the session and serve every parked connection.
    fn attach(&self, session: ServedSession) {
        let parked = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            match std::mem::replace(&mut *state, SlotState::Served(session.clone())) {
                SlotState::Restoring(parked) => parked,
                SlotState::Served(_) => VecDeque::new(),
            }
        };
        for stream in parked {
            session.serve(stream);
        }
    }
}

/// A bound session socket served before the session exists. Dropping it
/// without `attach` stops the accept loop and removes the socket file.
pub struct RestoringServer {
    path: PathBuf,
    attached: bool,
    slot: Arc<SessionSlot>,
    shutdown: Arc<AtomicBool>,
}

impl BoundSocket {
    /// Accept clients on this socket while the owner restores its session;
    /// they are served once the session is attached.
    pub fn serve_restoring(self) -> anyhow::Result<RestoringServer> {
        // Key-press flow marks start here, before the first request (`CMUX_TRACE_FLOWS`): every
        // server, the headless daemon's own bind (cmux-tui main) included, accepts through this.
        cmux_flow_trace::init();
        let slot = Arc::new(SessionSlot::restoring());
        let shutdown = Arc::new(AtomicBool::new(false));
        let (path, listener) = self.into_parts();
        if let Err(error) = spawn_accept_loop(listener, slot.clone(), shutdown.clone()) {
            cleanup(&path);
            return Err(error.into());
        }
        Ok(RestoringServer { path, attached: false, slot, shutdown })
    }
}

impl RestoringServer {
    /// Hand the socket to the restored session: parked and later connections
    /// are served by `mux`; the lifecycle endpoint stays not ready until the
    /// caller marks the returned server ready.
    pub fn attach(mut self, mux: Arc<Mux>) -> PendingServer {
        // The settings owner (settings-v1) reads the settings file and starts
        // its watcher before the session serves its first client.
        mux.start_default_settings_owner();
        mux.start_default_keybindings_owner();
        mux.connection_stats().note_socket(&self.path);
        // Publish the actual endpoint before any parked request is served.
        // A Cloud daemon may have been started with a custom --socket.
        let _ = mux.bound_socket_path.set(self.path.clone());
        self.slot.attach(ServedSession {
            mux: mux.clone(),
            render_service: Arc::new(RenderService::new()),
            terminal_sessions: Default::default(),
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

#[cfg(all(test, unix))]
mod tests {
    use std::io::{BufRead as _, BufReader};
    use std::os::unix::net::UnixStream;

    use super::{MAX_PARKED_CONNECTIONS, SessionSlot};
    use crate::server::listen::REFUSED_BUSY_LINE;

    /// A connection closed because the park is full gets the busy line, so a
    /// client that already wrote its request knows the daemon refused it and
    /// retries it, instead of taking the close for a request the daemon took
    /// and never answered (the hook counts those as undeliverable).
    #[test]
    fn a_connection_evicted_from_a_full_park_reads_the_busy_line() {
        let slot = SessionSlot::restoring();
        let mut clients = Vec::new();
        for _ in 0..=MAX_PARKED_CONNECTIONS {
            let (server, client) = UnixStream::pair().unwrap();
            assert!(slot.route(Box::new(server)).is_none(), "restoring parks every connection");
            clients.push(client);
        }
        let mut oldest = BufReader::new(clients.remove(0));
        let mut line = String::new();
        oldest.read_line(&mut line).unwrap();
        assert_eq!(line, REFUSED_BUSY_LINE, "the evicted connection was closed with no answer");
    }
}
