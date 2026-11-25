use super::*;
use tokio::io::{AsyncBufReadExt, BufReader, duplex};

/// A daemon that answers the first line with `reply`, then writes `after`.
async fn exchange(vm_kind: Option<VmKind>, reply: &str) -> (Result<(), StampRefused>, String) {
    let (mut host, daemon) = duplex(8192);
    let reply = reply.to_owned();
    let daemon = tokio::spawn(async move {
        let mut daemon = BufReader::new(daemon);
        let mut line = String::new();
        daemon.read_line(&mut line).await.unwrap();
        // A refused stream is closed mid-reply; the rest goes nowhere.
        let _ = daemon.get_mut().write_all(reply.as_bytes()).await;
        let _ = daemon.get_mut().write_all(b"{\"next\":true}\n").await;
        line
    });
    let result = stamp(&mut host, vm_kind).await;
    if result.is_ok() {
        // The pump reads the daemon's next line whole.
        let mut next = String::new();
        BufReader::new(&mut host).read_line(&mut next).await.unwrap();
        assert_eq!(next, "{\"next\":true}\n");
    }
    drop(host);
    (result, daemon.await.unwrap())
}

const TAKEN: &str = "{\"id\":\"carrier-role\",\"ok\":true,\"data\":{}}\n";
const REFUSED: &str = "{\"ok\":false,\"error\":\"bad_request\"}\n";

/// What a daemon from before the stamp answers it: an unknown command,
/// with every command it knows listed (cmux-tui-core's
/// `carrier_role_tests` measures the real one).
fn legacy_reply() -> String {
    let known: Vec<String> = (0..600).map(|n| format!("`command-{n:03}`")).collect();
    let error = format!(
        "bad request: unknown variant `carrier-role`, expected one of {}",
        known.join(", ")
    );
    let reply = serde_json::json!({"id": carrier_role::REQUEST_ID, "ok": false, "error": error});
    format!("{reply}\n")
}

#[tokio::test]
async fn the_grants_role_is_the_first_line_the_daemon_reads() {
    for role in [Some(VmKind::Owner), Some(VmKind::Team), None] {
        let (result, line) = exchange(role, TAKEN).await;
        assert_eq!(result, Ok(()), "{role:?}");
        assert_eq!(line, format!("{}\n", carrier_role::line(role)));
    }
}

#[tokio::test]
async fn a_teammates_stream_never_reaches_a_daemon_that_did_not_take_the_stamp() {
    for role in [Some(VmKind::Team), None] {
        assert_eq!(exchange(role, REFUSED).await.0, Err(StampRefused::NotTaken), "{role:?}");
        // A reply for another request is not the stamp's.
        let other = "{\"id\":\"x\",\"ok\":true}\n";
        assert_eq!(exchange(role, other).await.0, Err(StampRefused::NotTaken), "{role:?}");
    }
    // The owner loses nothing on an older daemon.
    assert_eq!(exchange(Some(VmKind::Owner), REFUSED).await.0, Ok(()));
}

#[tokio::test]
async fn an_older_daemons_long_unknown_command_reply_is_read_whole() {
    let legacy = legacy_reply();
    assert!(legacy.len() > 6 * 1024, "{}", legacy.len());
    // The owner's stream goes on, and the pump sees the daemon's next line whole.
    assert_eq!(exchange(Some(VmKind::Owner), &legacy).await.0, Ok(()));
    for role in [Some(VmKind::Team), None] {
        assert_eq!(exchange(role, &legacy).await.0, Err(StampRefused::NotTaken), "{role:?}");
    }
}

#[tokio::test]
async fn a_reply_past_the_bound_refuses_every_stream() {
    let long = format!("{{\"error\":\"{}\"}}\n", "x".repeat(carrier_role::MAX_REPLY_BYTES));
    for role in [Some(VmKind::Owner), Some(VmKind::Team)] {
        assert_eq!(exchange(role, &long).await.0, Err(StampRefused::Unavailable), "{role:?}");
    }
}

#[tokio::test]
async fn a_daemon_that_closes_or_garbles_refuses_every_stream() {
    for role in [Some(VmKind::Owner), Some(VmKind::Team)] {
        assert_eq!(exchange(role, "not json\n").await.0, Err(StampRefused::Unavailable));
        let (mut host, daemon) = duplex(64);
        drop(daemon);
        assert_eq!(stamp(&mut host, role).await, Err(StampRefused::Unavailable));
    }
}

#[tokio::test(start_paused = true)]
async fn a_daemon_that_never_answers_times_out() {
    let (mut host, _daemon) = duplex(8192);
    assert_eq!(stamp(&mut host, Some(VmKind::Team)).await, Err(StampRefused::Unavailable));
}
