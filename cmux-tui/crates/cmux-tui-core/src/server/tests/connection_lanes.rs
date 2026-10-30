//! The daemon's connections under Austin's load (#27698, P-AUSTIN B1): about
//! 80 terminal agents held every one of the daemon's 64 connections, 55,162
//! connections were refused, and the app was refused with them.
//!
//! - The app has a socket of its own (`app_lane_socket_path`): clients on the
//!   session socket cannot take its connections.
//! - On the session socket each client identity (a terminal's process
//!   session) gets a fair share, so one terminal cannot take the pool.
//! - The budget comes from the open-file limit the daemon runs with.
//! - A client that stops reading for a while keeps its connection (the stall
//!   is a signal, not a sleep: `StalledSocket`).

use super::*;
use crate::diagnostics::{ConnectionBudget, ConnectionLane, ConnectionStats};

/// Sends `request` and reads one line back, or `Value::Null` at end of stream.
#[cfg(unix)]
fn ask(stream: &mut Box<dyn transport::Stream>, request: &Value) -> Value {
    // No read deadline (R5): the daemon answers, or refuses with one line
    // and closes; either ends the read.
    // A refused connection may already be closed: the write fails, and the
    // refusal line still waits to be read.
    let _ = writeln!(stream, "{request}").and_then(|()| stream.flush());
    let mut reader = BufReader::new(stream.try_clone_box().unwrap());
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => Value::Null,
        Ok(_) => serde_json::from_str(&line).unwrap(),
    }
}

/// (1) Terminal clients fill the session socket until it refuses them; the
/// app's own socket still accepts a connection and serves it.
#[cfg(unix)]
#[test]
fn an_app_connection_is_served_while_the_session_socket_is_full() {
    let dir = TestSocketDir::create("app-lane");
    let path = dir.path().join("mux.sock");
    let mux = test_mux();
    mux.connection_stats().set_budget_for_test(ConnectionBudget::for_test(8));
    let _pending = serve_paused(mux, Some(path.clone())).unwrap();
    let identify = json!({"id": 1, "cmd": "identify"});

    let mut held = Vec::new();
    loop {
        let mut client = transport::connect(&path).unwrap();
        let reply = ask(&mut client, &identify);
        if reply["type"] == "refused" {
            assert_eq!(reply["code"], "server.busy");
            break;
        }
        assert_eq!(reply["ok"], true, "{reply}");
        held.push(client);
        assert!(held.len() <= 8, "the session socket admitted more than the whole budget");
    }

    let mut app = transport::connect(&app_lane_socket_path(&path))
        .expect("the app's own socket accepts while the session socket is full");
    let reply = ask(&mut app, &identify);
    assert_eq!(reply["ok"], true, "the app's connection was not served: {reply}");
    assert_eq!(reply["data"]["app"], "cmux-tui");
}

/// (2) A terminal that opens connection after connection gets its share and
/// no more: the next terminal, and the one after it, are still admitted.
#[test]
fn one_terminal_opening_many_connections_cannot_starve_another() {
    let stats = ConnectionStats::with_budget(ConnectionBudget::for_test(16));
    let greedy = 101;
    let first: Vec<_> =
        std::iter::from_fn(|| stats.try_claim_in(ConnectionLane::Shared, Some(greedy)))
            .take(64)
            .collect();
    assert!(!first.is_empty(), "the first terminal got no connection");
    let second: Vec<_> =
        std::iter::from_fn(|| stats.try_claim_in(ConnectionLane::Shared, Some(102)))
            .take(64)
            .collect();
    assert!(
        !second.is_empty(),
        "terminal {greedy} took {} connections and left none for the next terminal",
        first.len()
    );
    assert!(
        stats.try_claim_in(ConnectionLane::Shared, Some(103)).is_some(),
        "two terminals ({} and {} connections) left none for a third",
        first.len(),
        second.len()
    );
    assert!(
        stats.try_claim_in(ConnectionLane::Shared, Some(greedy)).is_none(),
        "the first terminal took more than its share"
    );
    assert!(
        stats.try_claim_in(ConnectionLane::App, None).is_some(),
        "terminals took the app's connections"
    );
}

/// Takes every byte of `service`'s outbound budgets, as session-socket
/// clients that stopped reading hold them until their queues overflow.
#[cfg(unix)]
fn exhaust(service: &RenderService) {
    for budget in [&service.outbound_budget, &service.control_budget] {
        let free = budget.max_bytes - budget.retained_bytes.load(Ordering::Acquire);
        assert!(budget.try_retain(free));
    }
}

/// Sends `identify` on a connection the session serves on `lane`; the reply,
/// or `Value::Null` once the daemon closed it. The read deadline only ends a
/// red run (R5): a served reply comes at once.
#[cfg(unix)]
fn identify_on(session: &listen::ServedSession, lane: ConnectionLane) -> Value {
    let (daemon_side, client) = std::os::unix::net::UnixStream::pair().unwrap();
    session.serve(Box::new(daemon_side), lane);
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut writer = client.try_clone().unwrap();
    writeln!(writer, "{}", json!({"id": 1, "cmd": "identify"})).unwrap();
    let mut line = String::new();
    match BufReader::new(client).read_line(&mut line) {
        Ok(0) | Err(_) => Value::Null,
        Ok(_) => serde_json::from_str(&line).unwrap(),
    }
}

/// Review of 6aaecf6a9207: with no write deadline, a session-socket client
/// that stops reading keeps its queued reply bytes until its queue
/// overflows. Those bytes come from its socket's outbound budgets; the app's
/// replies come from budgets of their own, so they are still answered when
/// the session socket's are spent.
#[cfg(unix)]
#[test]
fn the_apps_replies_never_wait_for_the_session_sockets_outbound_bytes() {
    let session = listen::ServedSession::new(test_mux());
    exhaust(&session.render_service);
    assert_ne!(
        identify_on(&session, ConnectionLane::Shared)["ok"],
        true,
        "the session socket's budgets are not spent: this test proves nothing"
    );
    let reply = identify_on(&session, ConnectionLane::App);
    assert_eq!(reply["ok"], true, "the app's reply waited for the session socket's bytes: {reply}");
}

/// Set in the child run: the soft open-file limit to run with.
#[cfg(unix)]
const SOFT_LIMIT_CHILD: &str = "CMUX_TEST_CONNECTION_BUDGET_SOFT_LIMIT";

/// This test's own name, for the child runs.
#[cfg(unix)]
const BUDGET_TEST: &str =
    "server::tests::connection_lanes::the_connection_budget_follows_the_open_file_limit";

/// The budget a fresh process reads with soft RLIMIT_NOFILE `soft`.
#[cfg(unix)]
fn budget_with_soft_limit(soft: u64) -> u64 {
    let exe = std::env::current_exe().unwrap();
    let output = std::process::Command::new(exe)
        .args(["--exact", BUDGET_TEST, "--nocapture", "--test-threads", "1"])
        .env(SOFT_LIMIT_CHILD, soft.to_string())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&output.stdout) + String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "the child run with soft limit {soft} failed:\n{text}");
    // libtest prints its own "test <name> ... " before the child's output on
    // the same line, so the marker is found anywhere in a line.
    text.lines()
        .find_map(|line| line.split_once("connection-budget=").map(|(_, rest)| rest))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|total| total.parse().ok())
        .unwrap_or_else(|| panic!("the child run printed no budget:\n{text}"))
}

/// (3) The connection budget is derived from the open-file limit: a higher
/// limit admits more connections, and the connections never take more than
/// half the descriptors (the rest stay for terminals, files and listeners).
#[cfg(unix)]
#[test]
fn the_connection_budget_follows_the_open_file_limit() {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is valid storage for one rlimit.
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) }, 0);
    if let Some(soft) = std::env::var_os(SOFT_LIMIT_CHILD) {
        let soft: u64 = soft.to_str().unwrap().parse().unwrap();
        let lowered = libc::rlimit { rlim_cur: soft as libc::rlim_t, rlim_max: limit.rlim_max };
        // SAFETY: only the soft limit changes, within the hard limit.
        assert_eq!(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raw const lowered) }, 0);
        println!("\nconnection-budget={}", ConnectionBudget::of_process().total());
        return;
    }
    let hard = limit.rlim_max;
    let (low, high) = (512, 4096.min(hard));
    assert!(high > low, "hard open-file limit {hard} is too low for this test");
    let (small, large) = (budget_with_soft_limit(low), budget_with_soft_limit(high));
    assert!(small >= 2, "a 512-descriptor daemon admits {small} connections");
    assert!(large > small, "budget {large} at {high} descriptors, {small} at {low}");
    // Each admitted connection may hold its descriptors twice over (an
    // active one plus one in the hung-up pool), four each.
    for (soft, budget) in [(low, small), (high, large)] {
        assert!(
            budget * 8 <= soft / 2,
            "{budget} connections can take more than half of {soft} descriptors"
        );
    }
}

/// A socket in memory whose client side the test drives, so a test can say
/// "the client stopped reading, for longer than any write deadline" as a
/// signal instead of a sleep (R5). It models the kernel: a daemon write waits
/// while the client's receive buffer (`capacity` bytes) is full, and a write
/// that waits when the stall is declared fails as `SO_SNDTIMEO` makes it fail
/// (`EAGAIN`) when a write deadline is set on the socket; with none it keeps
/// waiting.
struct StalledSocket {
    state: Mutex<StalledState>,
    changed: std::sync::Condvar,
    capacity: usize,
}

#[derive(Default)]
struct StalledState {
    /// Request bytes the client wrote, for the daemon's reader.
    inbound: VecDeque<u8>,
    /// Reply bytes the daemon wrote, for the client.
    outbound: VecDeque<u8>,
    write_timeout: Option<Duration>,
    /// A daemon write waits for room in `outbound`.
    writer_waiting: bool,
    /// The stall was declared while a write waited with a deadline set: that
    /// write fails.
    deadline_passed: bool,
    /// The daemon shut the socket down.
    closed_by_daemon: bool,
    /// The client hung up.
    closed_by_client: bool,
}

impl StalledSocket {
    fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(StalledState::default()),
            changed: std::sync::Condvar::new(),
            capacity,
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, StalledState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn wait<'a>(
        &self,
        state: std::sync::MutexGuard<'a, StalledState>,
    ) -> std::sync::MutexGuard<'a, StalledState> {
        self.changed.wait(state).unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The client writes one request line.
    fn client_send(&self, request: &Value) {
        self.lock().inbound.extend(format!("{request}\n").into_bytes());
        self.changed.notify_all();
    }

    /// Waits until a daemon write waits for room: the client's buffer is full.
    fn wait_until_the_daemon_waits(&self) {
        let mut state = self.lock();
        while !state.writer_waiting {
            state = self.wait(state);
        }
    }

    /// The client has not read for longer than any write deadline.
    fn declare_the_stall_longer_than_any_deadline(&self) {
        let mut state = self.lock();
        if state.writer_waiting && state.write_timeout.is_some() {
            state.deadline_passed = true;
        }
        drop(state);
        self.changed.notify_all();
    }

    /// The client reads one reply line; `None` once the daemon closed.
    fn client_read_line(&self) -> Option<Value> {
        let mut state = self.lock();
        loop {
            if let Some(end) = state.outbound.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = state.outbound.drain(..=end).collect();
                drop(state);
                self.changed.notify_all();
                return Some(serde_json::from_slice(&line).unwrap());
            }
            if state.closed_by_daemon {
                return None;
            }
            state = self.wait(state);
        }
    }

    fn client_hang_up(&self) {
        self.lock().closed_by_client = true;
        self.changed.notify_all();
    }
}

/// The daemon's end of a [`StalledSocket`].
struct StalledEnd(Arc<StalledSocket>);

impl Read for StalledEnd {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let mut state = self.0.lock();
        loop {
            if state.closed_by_daemon {
                return Ok(0);
            }
            if !state.inbound.is_empty() {
                let count = buf.len().min(state.inbound.len());
                for (slot, byte) in buf.iter_mut().zip(state.inbound.drain(..count)) {
                    *slot = byte;
                }
                return Ok(count);
            }
            if state.closed_by_client {
                return Ok(0);
            }
            state = self.0.wait(state);
        }
    }
}

impl Write for StalledEnd {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut state = self.0.lock();
        loop {
            if state.closed_by_daemon || state.closed_by_client {
                return Err(std::io::ErrorKind::BrokenPipe.into());
            }
            let room = self.0.capacity.saturating_sub(state.outbound.len());
            if room > 0 {
                let count = room.min(buf.len());
                state.outbound.extend(&buf[..count]);
                state.writer_waiting = false;
                drop(state);
                self.0.changed.notify_all();
                return Ok(count);
            }
            if state.deadline_passed {
                // SO_SNDTIMEO expired: this write fails, as the kernel's does.
                state.deadline_passed = false;
                state.writer_waiting = false;
                return Err(std::io::ErrorKind::WouldBlock.into());
            }
            state.writer_waiting = true;
            self.0.changed.notify_all();
            state = self.0.wait(state);
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl transport::Stream for StalledEnd {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self(self.0.clone())))
    }

    fn set_read_timeout(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }

    /// One option for every descriptor of the socket, as SO_SNDTIMEO.
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.0.lock().write_timeout = timeout;
        Ok(())
    }

    fn shutdown(&self, _how: Shutdown) -> std::io::Result<()> {
        self.0.lock().closed_by_daemon = true;
        self.0.changed.notify_all();
        Ok(())
    }
}

/// (4) A client that stops reading for longer than the daemon's old 2 s
/// write deadline keeps its connection: every reply is there when it reads
/// again, and the connection still serves. No timer decides it: the stall is
/// a signal ([`StalledSocket`]).
#[test]
fn a_client_that_stops_reading_for_a_while_keeps_its_connection() {
    let mux = test_mux();
    // Smaller than the replies below: the daemon's writer waits on the client.
    let socket = StalledSocket::new(8 * 1024);
    let server = StalledEnd(socket.clone());
    let handler = std::thread::spawn(move || handle_connection(mux, Box::new(server)));

    const REQUESTS: u64 = 64;
    for id in 1..=REQUESTS {
        socket.client_send(&json!({"id": id, "cmd": "identify"}));
    }
    socket.wait_until_the_daemon_waits();
    // The client is busy (a stalled main thread, a loaded Mac) for longer
    // than any write deadline.
    socket.declare_the_stall_longer_than_any_deadline();

    let mut replies = 0;
    while replies < REQUESTS {
        let Some(reply) = socket.client_read_line() else { break };
        assert_eq!(reply["ok"], true, "{reply}");
        replies += 1;
    }
    assert_eq!(replies, REQUESTS, "the daemon closed a client that only read late");

    socket.client_send(&json!({"id": REQUESTS + 1, "cmd": "identify"}));
    let reply = socket.client_read_line().expect("the connection no longer serves");
    assert_eq!(reply["id"], REQUESTS + 1);

    socket.client_hang_up();
    handler.join().unwrap();
}
