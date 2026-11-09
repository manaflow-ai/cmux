//! The owner's socket while it restores its session (cx-n3bs).
//!
//! An owner binds its session socket before the heavy restore (registry
//! load, terminal host adoption), so the socket names the one live owner for
//! the whole restore. Until the restored `Mux` is attached, the owner answers
//! `identify` and `server-stats` on its own (`lifecycle_ready: false`, and
//! what the restore does now: `crate::restore_progress`), and parks a
//! connection at its first other request; on attach each parked one goes to
//! the normal protocol handler, which reads that request first. A client
//! that connects as soon as the socket file exists is served exactly as
//! before, only later. `server ensure` reads `lifecycle_ready: false` as a
//! live owner that is still starting and waits for it, instead of seeing no
//! owner, killing it, or starting a second one; with the restore's progress
//! a client can also tell a long restore that advances from one that hangs
//! (a 26-minute restore answered nothing, and was taken for hung).

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};

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

/// Connections read at once while the owner restores, each on its own
/// thread, to answer their `identify`. Past it a new connection is parked
/// unread, as every connection was before the owner answered.
const MAX_ANSWERING_CONNECTIONS: usize = MAX_PARKED_CONNECTIONS;

/// How long one read of an answering connection blocks before it checks
/// whether the session was attached (then the connection is handed over).
const ANSWER_READ_SLICE: Duration = Duration::from_millis(100);

/// A first line longer than this is no `identify`: the connection is parked
/// with what was read, and the protocol handler judges it.
const MAX_ANSWERED_LINE: usize = 64 * 1024;

/// Where the accept loop sends a connection: answered and parked until the
/// session is attached, then served.
pub(super) struct SessionSlot {
    state: Mutex<SlotState>,
    /// The session the owner restores, named by `identify`.
    session: String,
    /// Connections on an answering thread now.
    answering: AtomicUsize,
    /// The restore failed and the socket closes: answering threads end.
    closed: AtomicBool,
}

enum SlotState {
    Restoring(VecDeque<Box<dyn transport::Stream>>),
    Served(ServedSession),
}

impl SessionSlot {
    fn restoring(session: String) -> Self {
        Self {
            state: Mutex::new(SlotState::Restoring(VecDeque::new())),
            session,
            answering: AtomicUsize::new(0),
            closed: AtomicBool::new(false),
        }
    }

    fn served(&self) -> Option<ServedSession> {
        match &*self.state.lock().unwrap_or_else(PoisonError::into_inner) {
            SlotState::Served(session) => Some(session.clone()),
            SlotState::Restoring(_) => None,
        }
    }

    /// The session to serve `stream` now, or None when it was taken while
    /// the owner restores: answered on a thread of its own until its first
    /// other request, or parked.
    pub(super) fn route(
        self: &Arc<Self>,
        stream: Box<dyn transport::Stream>,
    ) -> Option<(ServedSession, Box<dyn transport::Stream>)> {
        if let Some(session) = self.served() {
            return Some((session, stream));
        }
        let claimed = self
            .answering
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < MAX_ANSWERING_CONNECTIONS).then_some(count + 1)
            })
            .is_ok();
        if !claimed {
            return self.park(stream);
        }
        // Shared with the thread, so a thread that does not start leaves the
        // stream to be parked instead of lost.
        let held = Arc::new(Mutex::new(Some(stream)));
        let slot = self.clone();
        let handed = held.clone();
        let started = std::thread::Builder::new().name("mux-restoring".into()).spawn(move || {
            let Some(stream) = handed.lock().unwrap_or_else(PoisonError::into_inner).take() else {
                return;
            };
            let stream = slot.answer_while_restoring(stream);
            slot.answering.fetch_sub(1, Ordering::AcqRel);
            if let Some((session, stream)) = stream.and_then(|stream| slot.park(stream)) {
                session.serve(stream);
            }
        });
        if started.is_err() {
            self.answering.fetch_sub(1, Ordering::AcqRel);
            if let Some(stream) = held.lock().unwrap_or_else(PoisonError::into_inner).take() {
                return self.park(stream);
            }
        }
        None
    }

    /// Answers `identify` and `server-stats` on `stream` until its first
    /// other request or the attach; returns the stream with that request
    /// still unread (replayed first), or None when the client left.
    fn answer_while_restoring(
        &self,
        mut stream: Box<dyn transport::Stream>,
    ) -> Option<Box<dyn transport::Stream>> {
        if stream.set_read_timeout(Some(ANSWER_READ_SLICE)).is_err()
            || stream.set_write_timeout(Some(super::STREAM_WRITE_TIMEOUT)).is_err()
        {
            return Some(stream);
        }
        let mut pending = Vec::new();
        let mut chunk = [0_u8; 4096];
        loop {
            if self.closed.load(Ordering::Acquire) {
                return None;
            }
            // Attached: the session answers whatever is still unread.
            if self.served().is_some() {
                return Some(hand_over(stream, pending));
            }
            if let Some(end) = pending.iter().position(|byte| *byte == b'\n') {
                let answer =
                    pending.get(..end).and_then(|line| restoring_answer(&self.session, line));
                let Some(answer) = answer else {
                    return Some(hand_over(stream, pending));
                };
                let mut line = answer.to_string();
                line.push('\n');
                stream.write_all(line.as_bytes()).and_then(|()| stream.flush()).ok()?;
                pending.drain(..=end);
                continue;
            }
            if pending.len() > MAX_ANSWERED_LINE {
                return Some(hand_over(stream, pending));
            }
            match stream.read(&mut chunk) {
                // A last line without its newline is the handler's to judge.
                Ok(0) if !pending.is_empty() => return Some(hand_over(stream, pending)),
                Ok(0) => return None,
                Ok(read) => pending.extend_from_slice(chunk.get(..read).unwrap_or_default()),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::TimedOut
                            | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(_) => return None,
            }
        }
    }

    /// Parks `stream` until the attach, or the session to serve it now.
    fn park(
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

    /// Attach the session and serve every parked connection (an answering
    /// thread hands its connection over within `ANSWER_READ_SLICE`).
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
        // The restore's clock starts at the bind (`identify` reports it).
        let _ = crate::restore_progress::RestoreProgress::global();
        let (path, listener, session) = self.into_parts();
        let slot = Arc::new(SessionSlot::restoring(session));
        let shutdown = Arc::new(AtomicBool::new(false));
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
        self.slot.closed.store(true, Ordering::Release);
        // Wake the blocked accept so the loop sees the shutdown flag.
        let _ = transport::connect(&self.path);
        cleanup(&self.path);
    }
}

/// The reply to one request line while the owner restores, or None when it
/// waits for the session: `identify` and `server-stats` only.
fn restoring_answer(session: &str, line: &[u8]) -> Option<Value> {
    let request: Value = serde_json::from_slice(line).ok()?;
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    match request.get("cmd")?.as_str()? {
        "identify" => {
            let revisions = request.get("revisions").and_then(Value::as_bool).unwrap_or(false);
            let identity = super::cmd_server::restoring_identify(session, revisions);
            Some(json!({"id": id, "ok": true, "data": identity}))
        }
        // Its counters need the session; a refusal that says why, with the
        // restore's progress, instead of no answer.
        "server-stats" => Some(json!({
            "id": id,
            "ok": false,
            "error": "the session is still restoring; ask again once it serves",
            "error_code": "server.restoring",
            "error_details": {
                "lifecycle_ready": false,
                "restore": crate::restore_progress::RestoreProgress::global().to_json(),
            },
        })),
        _ => None,
    }
}

/// `stream` for the protocol handler: the bytes read from it so far are
/// replayed before the socket, and its reads block again.
fn hand_over(stream: Box<dyn transport::Stream>, read: Vec<u8>) -> Box<dyn transport::Stream> {
    let _ = stream.set_read_timeout(None);
    if read.is_empty() {
        return stream;
    }
    Box::new(Replayed { read, at: 0, inner: stream })
}

/// A connection whose first bytes were read while the owner restored. Its
/// clones (the line connection's write half) never read.
struct Replayed {
    read: Vec<u8>,
    at: usize,
    inner: Box<dyn transport::Stream>,
}

impl Read for Replayed {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if let Some(rest) = self.read.get(self.at..).filter(|rest| !rest.is_empty()) {
            let count = buffer.len().min(rest.len());
            for (slot, byte) in buffer.iter_mut().zip(rest) {
                *slot = *byte;
            }
            self.at += count;
            return Ok(count);
        }
        self.inner.read(buffer)
    }
}

impl Write for Replayed {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.inner.write(bytes)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

impl transport::Stream for Replayed {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
        self.inner.try_clone_box()
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_read_timeout(timeout)
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_write_timeout(timeout)
    }

    fn shutdown(&self, how: std::net::Shutdown) -> std::io::Result<()> {
        self.inner.shutdown(how)
    }

    fn peer_process_key(&self) -> Option<String> {
        self.inner.peer_process_key()
    }

    fn peer_token(&self) -> Option<cmux_link::app_caller::PeerToken> {
        self.inner.peer_token()
    }

    fn peer_closed(&self) -> bool {
        self.inner.peer_closed()
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::io::{BufRead as _, BufReader, Read as _, Write as _};
    use std::os::unix::net::UnixStream;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use super::{MAX_PARKED_CONNECTIONS, SessionSlot, SlotState};
    use crate::server::listen::REFUSED_BUSY_LINE;

    /// A connection closed because the park is full gets the busy line, so a
    /// client that already wrote its request knows the daemon refused it and
    /// retries it, instead of taking the close for a request the daemon took
    /// and never answered (the hook counts those as undeliverable).
    #[test]
    fn a_connection_evicted_from_a_full_park_reads_the_busy_line() {
        let slot = SessionSlot::restoring("evict".into());
        let mut clients = Vec::new();
        for _ in 0..=MAX_PARKED_CONNECTIONS {
            let (server, client) = UnixStream::pair().unwrap();
            assert!(slot.park(Box::new(server)).is_none(), "restoring parks every connection");
            clients.push(client);
        }
        let mut oldest = BufReader::new(clients.remove(0));
        let mut line = String::new();
        oldest.read_line(&mut line).unwrap();
        assert_eq!(line, REFUSED_BUSY_LINE, "the evicted connection was closed with no answer");
    }

    fn parked(slot: &SessionSlot) -> Option<Box<dyn crate::platform::transport::Stream>> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let SlotState::Restoring(parked) = &mut *slot.state.lock().unwrap() {
                if let Some(stream) = parked.pop_front() {
                    return Some(stream);
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        None
    }

    /// While the owner restores, `identify` is answered at once (not ready,
    /// with the restore's progress), and the first other request parks the
    /// connection with that request still to be read by the session.
    #[test]
    fn identify_is_answered_while_restoring_and_the_next_request_waits_for_the_session() {
        let slot = Arc::new(SessionSlot::restoring("answering".into()));
        let (server, client) = UnixStream::pair().unwrap();
        assert!(slot.route(Box::new(server)).is_none());
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut writer = client.try_clone().unwrap();
        let mut reader = BufReader::new(client);
        writeln!(writer, r#"{{"id":"a","cmd":"identify","revisions":true}}"#).unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["id"], "a", "{reply}");
        assert_eq!(reply["ok"], true, "{reply}");
        let identity = &reply["data"];
        assert_eq!(identity["session"], "answering", "{reply}");
        assert_eq!(identity["lifecycle_ready"], false, "{reply}");
        assert!(identity["restore"]["phase"].is_string(), "{reply}");
        assert!(identity["restore"]["last_advance_ms"].is_u64(), "{reply}");

        // `server-stats` says why it has no counters yet.
        writeln!(writer, r#"{{"id":"s","cmd":"server-stats"}}"#).unwrap();
        line.clear();
        reader.read_line(&mut line).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["error_code"], "server.restoring", "{reply}");
        assert!(reply["error_details"]["restore"]["phase"].is_string(), "{reply}");

        let ping = r#"{"id":"p","cmd":"ping"}"#;
        writeln!(writer, "{ping}").unwrap();
        let mut stream = parked(&slot).expect("the ping parked the connection");
        let mut replayed = vec![0_u8; ping.len() + 1];
        stream.read_exact(&mut replayed).unwrap();
        assert_eq!(replayed, format!("{ping}\n").into_bytes(), "the parked request was lost");
    }
}
