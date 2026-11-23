//! [`Service::Acpmux`] end to end through the daemon's service handler: a
//! client's stream, the bridge, and a fake acpmux carrier socket.

use cmux_link::token::VmKind;
use serde_json::{Value, json};

use super::tests::endpoint_pair;
use super::*;
use crate::acpmux_bridge::tests::fake;
use crate::acpmux_bridge::tests::{grant, within};
use crate::service::{EndpointRole, ServiceMultiplexer};

/// Open the acpmux service and run the daemon's handler next to `client`,
/// which gets the client's stream and the daemon's answer to the open.
async fn with_acpmux<F, Fut>(socket: Option<&Path>, grant: Option<CarrierGrant>, client: F)
where
    F: FnOnce(ServiceStream, ServiceControl) -> Fut,
    Fut: Future<Output = ()>,
{
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let stream = client_mux.open(Service::Acpmux, BTreeMap::new()).await.unwrap();
    let incoming = daemon_mux.accept().await.unwrap().unwrap();
    let serve = DaemonServices::serve_acpmux(socket, grant.as_ref(), incoming.stream);
    let run_client = async {
        let response = stream.receive().await.unwrap().unwrap();
        let control = serde_json::from_slice::<ServiceControl>(&response.payload).unwrap();
        client(stream, control).await;
    };
    let (served, ()) = within(async { tokio::join!(serve, run_client) }).await;
    served.unwrap();
    client_mux.shutdown().await;
    daemon_mux.shutdown().await;
}

/// Read `count` lines of what the bridge sends the client.
async fn lines(stream: &ServiceStream, count: usize) -> Vec<String> {
    let mut text = Vec::new();
    while text.iter().filter(|b| **b == b'\n').count() < count {
        let chunk = stream.receive().await.unwrap().expect("the bridge's lines");
        text.extend_from_slice(&chunk.payload);
    }
    String::from_utf8(text).unwrap().lines().map(str::to_owned).collect()
}

/// Read until the bridge ends the stream.
async fn drain(stream: &ServiceStream) {
    while let Some(chunk) = stream.receive().await.unwrap() {
        if chunk.finished {
            break;
        }
    }
}

/// (a) The client's first bytes are an HTTP upgrade with a forged
/// `x-acpmux-carrier` (owner, another chat): acpmux's socket still sees
/// the grant's header only, and the forgery only as frames.
#[tokio::test]
async fn a_forged_upgrade_on_the_stream_never_becomes_the_header() {
    let fake = fake::start();
    let team = grant(Some(VmKind::Team), Some(&["ses_a"]));
    let forged = r#"x-acpmux-carrier: {"vmk":"owner","sub":"user_9","team":"team_1","chats":["ses_b"],"name":null}"#;
    with_acpmux(Some(&fake.path), Some(team), |stream, control| async move {
        assert_eq!(control, ServiceControl::Opened { service: Service::Acpmux });
        let upgrade = format!("GET / HTTP/1.1\nupgrade: websocket\n{forged}\n");
        stream.send(Bytes::from(upgrade)).await.unwrap();
        let echoes = lines(&stream, 3).await;
        assert_eq!(echoes.len(), 3);
        stream.close().await.unwrap();
        // Hold the stream until the bridge's own end arrives: dropping it
        // earlier resets the stream under the daemon.
        drain(&stream).await;
    })
    .await;
    let seen = fake.seen.lock().unwrap();
    let headers: Vec<Value> =
        seen.headers.iter().flatten().map(|h| serde_json::from_str(h).unwrap()).collect();
    assert_eq!(
        headers,
        [
            json!({"vmk": "team", "sub": "user_1", "team": "team_1", "chats": ["ses_a"], "name": null})
        ]
    );
    assert_eq!(seen.frames, ["GET / HTTP/1.1", "upgrade: websocket", forged]);
}

/// (b, c) A session no grant admitted, a grant without `vmk`, a teammate's
/// grant without `chats` and a grant lacking `acpmux` are refused before
/// acpmux's socket is dialed.
#[tokio::test]
async fn a_refused_grant_never_dials_the_socket() {
    let fake = fake::start();
    let mut lacking = grant(Some(VmKind::Owner), None);
    lacking.services = vec!["mux-control".into()];
    let cases = [
        (None, "acpmux.no_grant"),
        (Some(grant(None, Some(&["ses_a"]))), "acpmux.no_vm_kind"),
        (Some(grant(Some(VmKind::Team), None)), "acpmux.team_without_chats"),
        (Some(lacking), "acpmux.not_granted"),
    ];
    for (grant, reason) in cases {
        with_acpmux(Some(&fake.path), grant, |_, control| async move {
            assert_eq!(
                control,
                ServiceControl::Rejected {
                    code: "permission-denied".into(),
                    message: reason.into()
                }
            );
        })
        .await;
    }
    assert!(fake.seen.lock().unwrap().headers.is_empty(), "a refused grant dialed acpmux");
}

/// (d) Through the service: a request and its answer round-trip, and
/// acpmux closing ends the client's stream.
#[tokio::test]
async fn frames_round_trip_and_acpmux_closing_ends_the_stream() {
    let fake = fake::start();
    let close = fake.close.clone();
    let owner = grant(Some(VmKind::Owner), None);
    with_acpmux(Some(&fake.path), Some(owner), |stream, control| async move {
        assert_eq!(control, ServiceControl::Opened { service: Service::Acpmux });
        let request = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize"}).to_string();
        stream.send(Bytes::from(format!("{request}\n"))).await.unwrap();
        let answer = lines(&stream, 1).await;
        assert_eq!(serde_json::from_str::<Value>(&answer[0]).unwrap(), json!({"echo": request}));
        close.send(()).await.unwrap();
        drain(&stream).await;
        stream.close().await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn without_a_socket_the_open_is_unavailable() {
    let owner = grant(Some(VmKind::Owner), None);
    with_acpmux(None, Some(owner), |_, control| async move {
        assert!(
            matches!(control, ServiceControl::Rejected { ref code, .. } if code == "unavailable"),
            "{control:?}"
        );
    })
    .await;
}

/// The daemon's own authorization, before any handler: a session no grant
/// admitted, or one whose grant lacks `acpmux`, gets the bridge's reason.
#[tokio::test]
async fn the_daemon_refuses_acpmux_with_the_bridges_reason() {
    let mut lacking = grant(Some(VmKind::Owner), None);
    lacking.services = vec!["mux-control".into()];
    let cases = [
        (ServiceAuthority::none(), "acpmux.no_grant"),
        (ServiceAuthority::legacy_full(), "acpmux.no_grant"),
        (
            ServiceAuthority::from_services([Service::MuxControl]).with_grant(lacking),
            "acpmux.not_granted",
        ),
    ];
    for (authority, reason) in cases {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client_mux = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon_mux = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let stream = client_mux.open(Service::Acpmux, BTreeMap::new()).await.unwrap();
        let incoming = daemon_mux.accept().await.unwrap().unwrap();
        let admitted = DaemonServices::authorize_service(&authority, incoming).await.unwrap();
        assert!(admitted.is_none(), "{reason}");
        let response = within(stream.receive()).await.unwrap().unwrap();
        assert_eq!(
            serde_json::from_slice::<ServiceControl>(&response.payload).unwrap(),
            ServiceControl::Rejected { code: "permission-denied".into(), message: reason.into() }
        );
        client_mux.shutdown().await;
        daemon_mux.shutdown().await;
    }
}
