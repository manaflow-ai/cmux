//! A grant-admitted `mux-control` stream through the daemon's service handler:
//! the grant's role is the first line the session daemon's socket reads, and a
//! teammate's stream never reaches a daemon that did not take it. A session this
//! machine's own user opened (`cmux ssh`) carries the owner's role.

use std::time::Duration;

use cmux_link::token::VmKind;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

use super::tests::endpoint_pair;
use super::*;
use crate::acpmux_bridge::tests::{grant, within};
use crate::service::{EndpointRole, ServiceMultiplexer};

/// Open `mux-control` for a session held by `authority` against a fake session daemon that answers
/// its first line with `reply`. Returns the service's answer to the open and
/// every line the fake read.
async fn open(authority: ServiceAuthority, reply: &'static str) -> (Value, Vec<String>) {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let fake = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut socket = BufReader::new(socket);
        // Every line it reads, the first answered with `reply`, until it hears nothing for a
        // while (a stream without a grant sends nothing of its own here).
        let mut lines = Vec::new();
        loop {
            let mut line = String::new();
            match tokio::time::timeout(Duration::from_millis(300), socket.read_line(&mut line))
                .await
            {
                Ok(Ok(n)) if n > 0 => {
                    if lines.is_empty() {
                        socket.get_mut().write_all(reply.as_bytes()).await.unwrap();
                    }
                    lines.push(line.trim_end().to_owned());
                }
                _ => break,
            }
        }
        lines
    });
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let stream = client_mux.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
    let incoming = daemon_mux.accept().await.unwrap().unwrap();
    let serve = DaemonServices::serve_mux_control_with_budget(
        Some(path),
        authority.mux_role(),
        incoming.stream,
        MuxUploadBudget::new(),
        false,
    );
    // An admitted stream's pump runs until the stream ends: the open's answer and the
    // fake's lines are all this reads, then the pump is dropped.
    let serve = async {
        let _ = serve.await;
        std::future::pending::<()>().await;
    };
    let read = async {
        let chunk = stream.receive().await.unwrap().unwrap();
        let answer: Value = serde_json::from_slice(&chunk.payload).unwrap();
        (answer, fake.await.unwrap())
    };
    let result = tokio::select! {
        () = serve => unreachable!(),
        result = within(read) => result,
    };
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
    result
}

fn granted(role: Option<VmKind>) -> ServiceAuthority {
    ServiceAuthority::legacy_full().with_grant(grant(role, Some(&["chat_a"])))
}

const TAKEN: &str = "{\"id\":\"carrier-role\",\"ok\":true,\"data\":{}}\n";
const REFUSED: &str = "{\"ok\":false,\"error\":\"bad_request\"}\n";

#[tokio::test]
async fn the_grants_role_reaches_the_daemon_before_the_person() {
    for role in [Some(VmKind::Owner), Some(VmKind::Team), None] {
        let (answer, lines) = open(granted(role), TAKEN).await;
        assert_eq!(answer["type"], "opened", "{role:?}: {answer}");
        assert_eq!(lines.first(), Some(&cmux_link::carrier_role::line(role)), "{role:?}");
    }
}

#[tokio::test]
async fn a_teammates_stream_never_reaches_a_daemon_that_refused_the_role() {
    for role in [Some(VmKind::Team), None] {
        let (answer, lines) = open(granted(role), REFUSED).await;
        assert_eq!(answer["type"], "rejected", "{role:?}: {answer}");
        assert_eq!(answer["code"], "permission-denied");
        // Only the stamp: the person's line never reached the daemon.
        assert_eq!(lines, vec![cmux_link::carrier_role::line(role)], "{role:?}");
    }
}

#[tokio::test]
async fn a_session_without_a_grant_is_spliced_unchanged() {
    let (answer, lines) = open(ServiceAuthority::legacy_full(), TAKEN).await;
    assert_eq!(answer["type"], "opened", "{answer}");
    assert!(lines.iter().all(|line| !line.contains(cmux_link::carrier_role::COMMAND)), "{lines:?}");
}

/// `cmux ssh`: the session came over this machine's own user (kernel or SSH evidence), so
/// its stream is the owner's, and a personal box's daemon serves it the owner's file ops
/// (a `cmux ssh --repo` seed). An older daemon that does not know the stamp still gets it.
#[tokio::test]
async fn a_same_owner_session_carries_the_owners_role() {
    let owner = cmux_link::carrier_role::line(Some(VmKind::Owner));
    for reply in [TAKEN, REFUSED] {
        let (answer, lines) = open(ServiceAuthority::legacy_full().same_owner(), reply).await;
        assert_eq!(answer["type"], "opened", "{reply}: {answer}");
        assert_eq!(lines.first(), Some(&owner), "{reply}");
    }
}
