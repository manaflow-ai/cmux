//! The daemon's connections under Austin's load (#27698, P-AUSTIN B1): about
//! 80 terminal agents held every one of the daemon's 64 connections, 55,162
//! connections were refused, and the app was refused with them.
//!
//! - The app has a socket of its own (`app_lane_socket_path`): clients on the
//!   session socket cannot take its connections.
//! - On the session socket each client identity (a terminal's process
//!   session) gets a fair share, so one terminal cannot take the pool.
//! - The budget comes from the open-file limit the daemon runs with.
//! - A client that stops reading for a while keeps its connection.

use super::*;
use crate::diagnostics::{ConnectionBudget, ConnectionLane, ConnectionStats};

/// Sends `request` and reads one line back, or `Value::Null` at end of stream.
#[cfg(unix)]
fn ask(stream: &mut Box<dyn transport::Stream>, request: &Value) -> Value {
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
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
    text.lines()
        .find_map(|line| line.strip_prefix("connection-budget="))
        .and_then(|total| total.trim().parse().ok())
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
        println!("connection-budget={}", ConnectionBudget::of_process().total());
        return;
    }
    let hard = limit.rlim_max as u64;
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

/// (4) A client that stops reading for longer than the daemon's old 2 s
/// write deadline keeps its connection: every reply is there when it reads
/// again, and the connection still serves.
#[cfg(unix)]
#[test]
fn a_client_that_stops_reading_for_a_while_keeps_its_connection() {
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    let mux = test_mux();
    let (server, client) = UnixStream::pair().unwrap();
    // A small send buffer: the replies below fill it at once, so the
    // daemon's writer waits on this client the whole time it does not read.
    let small: libc::c_int = 8 * 1024;
    // SAFETY: a valid descriptor and a c_int option value of its size.
    unsafe {
        libc::setsockopt(
            server.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&raw const small).cast(),
            size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, Box::new(server)));

    const REQUESTS: u64 = 200;
    let mut writer = client.try_clone().unwrap();
    for id in 1..=REQUESTS {
        writeln!(writer, "{}", json!({"id": id, "cmd": "identify"})).unwrap();
    }
    writer.flush().unwrap();
    // The client is busy (a stalled main thread, a loaded Mac) and reads
    // nothing for longer than the old deadline.
    std::thread::sleep(Duration::from_secs(3));

    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let mut replies = 0;
    while replies < REQUESTS {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                let reply: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(reply["ok"], true, "{reply}");
                replies += 1;
            }
        }
    }
    assert_eq!(replies, REQUESTS, "the daemon closed a client that only read late");

    writeln!(writer, "{}", json!({"id": REQUESTS + 1, "cmd": "identify"})).unwrap();
    writer.flush().unwrap();
    let mut line = String::new();
    assert!(reader.read_line(&mut line).unwrap() > 0, "the connection no longer serves");
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["id"], REQUESTS + 1);

    client.shutdown(Shutdown::Both).unwrap();
    handler.join().unwrap();
}
