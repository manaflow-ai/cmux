use crate::agent_host::{self, HostRecord};

/// A host that accepts the connection and never reads it (its event loop wedged, 2026-11-06):
/// the start's pass gives up on it after its budget, so the start, and every new session
/// waiting on it, goes on. Before, the release pass had no budget and waited forever.
#[tokio::test(start_paused = true)]
async fn the_start_pass_gives_up_on_a_host_that_never_answers_hello() {
    // Short, so the socket stays under SUN_LEN (104 bytes on macOS) under a long TMPDIR.
    let dir = cmux_unix_socket::short_test_dir("acpmux-h");
    let socket = dir.path().join("host.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    // Accepts and keeps every connection, never reads one.
    let wedged = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = listener.accept().await {
            held.push(stream);
        }
    });
    let record = HostRecord {
        record_version: 1,
        session_id: "wedged".into(),
        incarnation: "i".into(),
        host_pid: std::process::id(),
        start_nonce: "00".into(),
        harness_pid: None,
        owner_token: "t".into(),
        caller_token: None,
        protocol_min: agent_host::PROTOCOL_MIN,
        protocol_max: agent_host::PROTOCOL_MAX,
        host_build: "test".into(),
        socket,
    };
    let started = tokio::time::Instant::now();
    let result = super::adoption_hello_scope(agent_host::link::connect(record, 0)).await;
    let error = result.err().expect("a host that never answers is not adopted");
    assert!(agent_host::link::missed_hello(&error), "{error:#}");
    let waited = started.elapsed();
    let budget = agent_host::link::START_HELLO_BUDGET;
    assert!(waited >= budget && waited < budget * 2, "waited {waited:?}");
    wedged.abort();
}
