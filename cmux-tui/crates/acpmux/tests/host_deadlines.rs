//! Every wait the daemon makes on an agent host has a deadline and a typed
//! error (`HostTimeout`), and a host's death is watched by at most one
//! thread however often the daemon waits on it. The deadlines are injected
//! (`spawn_within`, `query_within`); production passes `BOOTSTRAP_BUDGET`
//! and `QUERY_BUDGET`.
#![cfg(unix)]

use acpmux::agent_host::link::{self, Connect};
use acpmux::agent_host::{self, ControllerFrame, HostFrame, HostRecord, HostTimeout};
use std::path::PathBuf;
use std::time::Duration;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amd-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A host that never answers a translator query must not hold the caller.
#[tokio::test]
async fn a_query_the_host_never_answers_times_out() {
    let dir = scratch("query");
    let socket = dir.join("h.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let record = HostRecord {
        record_version: agent_host::RECORD_VERSION,
        session_id: "s".into(),
        incarnation: "inc".into(),
        host_pid: std::process::id(),
        start_nonce: "n".into(),
        harness_pid: None,
        owner_token: "00".into(),
        protocol_min: agent_host::PROTOCOL_MIN,
        protocol_max: agent_host::PROTOCOL_MAX,
        host_build: "fake".into(),
        socket: socket.clone(),
    };
    // A fake host: answers hello, then reads every frame and answers none.
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut rd, mut wr) = stream.into_split();
        let _: Option<ControllerFrame> = agent_host::read_frame(&mut rd).await.unwrap();
        let hello = HostFrame::HostHello {
            version: agent_host::PROTOCOL_MAX,
            host_build: "fake".into(),
            incarnation: "inc".into(),
            harness_pid: None,
            last_h: 0,
            acked_h: 0,
            max_out_id: 0,
            exited: None,
        };
        agent_host::write_frame(&mut wr, &hello).await.unwrap();
        while let Ok(Some(_)) = agent_host::read_frame::<_, ControllerFrame>(&mut rd).await {}
    });
    let Connect::Ready(link, _) = link::connect(record, 0).await.expect("connect") else {
        panic!("the fake host is compatible");
    };
    let out = tokio::time::timeout(
        Duration::from_secs(20),
        link.query_within(Duration::from_millis(300)),
    )
    .await
    .expect("query never gave up on a host that does not answer");
    let err = out.expect_err("no answer is no reply");
    assert!(err.downcast_ref::<HostTimeout>().is_some(), "not a typed timeout: {err:#}");
}
