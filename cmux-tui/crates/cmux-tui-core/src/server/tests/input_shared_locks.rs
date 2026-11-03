//! R-DAEMON-STATE stage S1 (handoff/rewrites/R-DAEMON-STATE/DESIGN.md, section 2.6): the person's key takes no lock
//! that another terminal, another connection, a reader or a writer of the session takes.
//!
//! #31940 took the session lock (`Mux::state`) off the key. The key still waits for other shared locks: the client
//! registry (five times per line), the link peers, the host proxy authors, the surface admission budget, the client
//! sizing lock, the creating-input lock and the activity lock. Their other holders are every connect, attach,
//! resize and request of every client, and the sizing and creating-input holders take `Mux::state` and resize PTYs
//! under them. Under the L6 storm the fixed build still showed a daemon key part of p99 20-24 ms and max 74-223 ms
//! (STATUS 7761).
//!
//! The test drives a key line through the real connection path (the line handler, the connection's dispatcher, the
//! `send` handler) while another thread holds one shared lock for 300 ms. A key that waits for the lock reaches its
//! PTY after about 300 ms; a key that does not wait reaches it in well under a millisecond. Two keys go in a row: a
//! lock taken after the PTY write (sizing, activity) delays the second key, which waits on the connection's
//! dispatcher behind the first.

// The test terminal's in-process PTY runtime and the host proxy lock exist on Unix only (as for input_lane.rs).
#![cfg(unix)]

use super::*;
use base64::Engine;
use std::sync::mpsc;
use std::time::Instant;

/// How long the other thread holds each lock.
const HOLD: Duration = Duration::from_millis(300);
/// A key that took longer than this waited for the held lock. Well above scheduling noise on a loaded fleet host,
/// well below `HOLD`.
const BUDGET: Duration = Duration::from_millis(150);

/// Records when each write reached the test terminal's PTY input.
struct TimedInput(mpsc::Sender<(Instant, Vec<u8>)>);

impl Write for TimedInput {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let _ = self.0.send((Instant::now(), bytes.to_vec()));
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// One attached typing connection, as the app's terminal view makes it: its own client, its own dispatcher, a view
/// that joined the terminal's sizing.
struct TypingConnection {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    surface: SurfaceId,
    input: mpsc::Receiver<(Instant, Vec<u8>)>,
}

impl TypingConnection {
    fn open() -> Self {
        let mux = test_mux();
        let terminal = mux.new_workspace(Some("typing".into()), Some((80, 24))).unwrap();
        let (sent, input) = mpsc::channel();
        terminal.replace_input_writer_for_test(Box::new(TimedInput(sent)));
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        attach_test_view(&mux, client, terminal.id, &writer);
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux, client, writer, outbound, scheduler, surface: terminal.id, input }
    }

    /// Hands one `send` line to the connection, as its reader thread does.
    fn submit(&self, id: &str, byte: u8) {
        let line = json!({
            "id": id,
            "cmd": "send",
            "surface": self.surface,
            "bytes": base64::engine::general_purpose::STANDARD.encode([byte]),
        })
        .to_string();
        assert!(
            handle_connection_frame(
                &self.mux,
                self.client,
                ClientTransport::Unix,
                &line,
                &self.writer,
                &self.scheduler,
            ),
            "the connection closed on a key line"
        );
    }

    /// When `byte` reached the PTY, or `None` after 5 s.
    fn arrival(&self, byte: u8) -> Option<Instant> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (at, bytes) = self.input.recv_timeout(remaining).ok()?;
            if bytes.contains(&byte) {
                return Some(at);
            }
        }
    }

    /// Waits for the replies to `ids`, so the connection's dispatcher is idle again.
    fn settle(&self, ids: &[&str]) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut left: Vec<&str> = ids.to_vec();
        while !left.is_empty() && Instant::now() < deadline {
            match self.outbound.try_pop() {
                Some(line) => {
                    let value: Value = serde_json::from_str(&line).unwrap_or_default();
                    if let Some(id) = value["id"].as_str() {
                        if value["type"] == "response" || value.get("ok").is_some() {
                            assert_eq!(value["ok"], true, "key {id} failed: {value}");
                        }
                        left.retain(|pending| *pending != id);
                    }
                }
                None => std::thread::sleep(Duration::from_millis(1)),
            }
        }
        assert!(left.is_empty(), "no reply within 5 s to {left:?}");
    }

    fn close(self) {
        self.scheduler.finish_and_wait();
        disconnect_client(&self.mux, self.client, false);
        self.mux.shutdown();
    }
}

/// Holds one shared lock on another thread until released or `HOLD` passed.
type Holder = fn(&Arc<Mux>, &dyn Fn());

/// Every shared lock the key line may meet, each with a holder. `Mux.state` and the workspace registry are controls:
/// #31940 already took them off the key, so their rows pass on the base too.
fn hold_each() -> Vec<(&'static str, Holder)> {
    let mut locks: Vec<(&'static str, Holder)> = Vec::new();
    locks.push(("client registry (ClientRegistry.state)", |mux, hold| {
        let _held = mux.control_clients.state.lock().unwrap_or_else(|e| e.into_inner());
        hold();
    }));
    locks.push(("link peers (RemoteRelayState.peers)", |mux, hold| {
        let _held = mux.remote_relay().peers.lock().unwrap_or_else(|e| e.into_inner());
        hold();
    }));
    locks.push(("host proxy authors (AgentSessions.proxy_authors)", |mux, hold| {
        mux.control_clients.agent_sessions.hold_proxy_authors_for_test(hold);
    }));
    locks.push(("surface admission (ServerSurfaceOperationAdmission.state)", |mux, hold| {
        let _held = mux.surface_operation_admission.state.lock().unwrap_or_else(|e| e.into_inner());
        hold();
    }));
    locks.push(("creating input (CreatingInputs.terminals)", |mux, hold| {
        mux.hold_creating_input_lock_for_test(hold);
    }));
    locks.push(("client sizing (Mux.client_sizing)", |mux, hold| {
        mux.hold_client_sizing_lock_for_test(hold);
    }));
    locks.push(("activity (ActivityStream)", |mux, hold| mux.activity.hold_lock_for_test(hold)));
    locks.push(("session (Mux.state)", |mux, hold| mux.with_state(|_| hold())));
    locks.push(("workspace registry (Mux.workspace_registry)", |mux, hold| {
        let _held = mux.workspace_registry.lock().unwrap_or_else(|e| e.into_inner());
        hold();
    }));
    locks
}

#[test]
fn a_key_waits_for_no_shared_lock() {
    let connection = TypingConnection::open();
    // The first key of a view may take the long way; every key after it must not wait.
    connection.submit("warm", b'w');
    assert!(connection.arrival(b'w').is_some(), "the first key never reached its terminal");
    connection.settle(&["warm"]);

    let mut waits = Vec::new();
    for (index, (name, holder)) in hold_each().into_iter().enumerate() {
        let first = b'a' + u8::try_from(index * 2).unwrap_or(0);
        let second = first + 1;
        let (held, holding) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let mux = connection.mux.clone();
        let other = std::thread::spawn(move || {
            holder(&mux, &|| {
                let _ = held.send(());
                let _ = released.recv_timeout(HOLD);
            });
        });
        holding.recv().expect("the other thread took its lock");
        let started = Instant::now();
        let (first_id, second_id) = (format!("{index}-first"), format!("{index}-second"));
        connection.submit(&first_id, first);
        connection.submit(&second_id, second);
        let first_at = connection.arrival(first);
        let second_at = connection.arrival(second);
        let _ = release.send(());
        other.join().expect("the lock holder ended");
        connection.settle(&[first_id.as_str(), second_id.as_str()]);
        let waited = match (first_at, second_at) {
            (Some(first_at), Some(second_at)) => first_at.max(second_at) - started,
            _ => Duration::MAX,
        };
        eprintln!("SHARED-LOCKS key wait while {name} is held {HOLD:?}: {waited:?}");
        waits.push((name, waited));
    }
    connection.close();

    let blocked: Vec<String> = waits
        .iter()
        .filter(|(_, waited)| *waited >= BUDGET)
        .map(|(name, waited)| format!("{name}: {waited:?}"))
        .collect();
    assert!(
        blocked.is_empty(),
        "the person's keys waited for {} shared lock(s) held by another thread (budget {BUDGET:?}, held \
         {HOLD:?}): {}",
        blocked.len(),
        blocked.join("; ")
    );
}
