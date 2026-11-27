//! The standby hold ([`HOLD_REQUEST`]) old against new, both ways, on loopback Iroh endpoints.

use std::time::Duration;

use ::iroh::endpoint::Connection;

use super::{
    Endpoint, IrohListener, IrohListenerLimits, IrohPathMode, IrohProviderConfig, NodeAddr,
    bind_endpoint, connect_iroh_connection, request_hold,
};
use crate::daemon::RemoteDaemon;
use crate::identity::AuthDatabase;
use crate::session::SessionLimits;

const FIRST_STREAM: Duration = Duration::from_millis(600);

fn config() -> IrohProviderConfig {
    IrohProviderConfig::default().with_path_mode(IrohPathMode::DirectOnly)
}

/// A listener with this build's code and a short first-stream timeout.
async fn new_listener() -> (IrohListener, tempfile::TempDir) {
    let state = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "hold", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let limits =
        IrohListenerLimits { first_stream_timeout: FIRST_STREAM, ..IrohListenerLimits::default() };
    let listener = IrohListener::bind_with_limits(daemon, config(), limits).await.unwrap();
    (listener, state)
}

/// A listener from before the hold: it accepts bidirectional streams only, and closes a
/// connection that opens none within the first-stream timeout.
async fn old_listener() -> (Endpoint, tokio::task::JoinHandle<()>) {
    let endpoint = bind_endpoint(&config()).await.unwrap();
    let serving = endpoint.clone();
    let task = tokio::spawn(async move {
        while let Some(incoming) = serving.accept().await {
            let Ok(connection) = incoming.await else { continue };
            tokio::spawn(async move {
                tokio::select! {
                    _ = tokio::time::sleep(FIRST_STREAM) => {
                        connection.close(4_u8.into(), b"first cmux stream timed out");
                    }
                    _ = connection.accept_bi() => {}
                }
                connection.closed().await;
            });
        }
    });
    (endpoint, task)
}

async fn dial(addr: NodeAddr) -> (Endpoint, Connection) {
    let client = bind_endpoint(&config()).await.unwrap();
    let connection = connect_iroh_connection(&client, &addr, super::CMUX_IROH_ALPN).await.unwrap();
    (client, connection)
}

#[tokio::test]
async fn a_new_client_holds_a_standby_on_a_new_listener_past_the_first_stream_timeout() {
    let (listener, _state) = new_listener().await;
    let (_client, connection) = dial(listener.node_addr().await.unwrap()).await;
    let lease = request_hold(&connection).await.expect("the new listener grants the hold");
    assert!(lease > Duration::from_secs(60), "the lease is the unauthenticated timeout: {lease:?}");
    tokio::time::sleep(FIRST_STREAM * 3).await;
    assert!(
        connection.close_reason().is_none(),
        "a held standby outlives the first-stream timeout"
    );
}

#[tokio::test]
async fn an_old_client_is_still_closed_at_the_first_stream_timeout_by_a_new_listener() {
    let (listener, _state) = new_listener().await;
    let (_client, connection) = dial(listener.node_addr().await.unwrap()).await;
    tokio::time::timeout(FIRST_STREAM * 5, connection.closed())
        .await
        .expect("a connection that never asks for a hold keeps the first-stream timeout");
}

#[tokio::test]
async fn a_new_client_hears_no_hold_from_an_old_listener_and_its_standby_still_closes() {
    let (listener, task) = old_listener().await;
    let (_client, connection) = dial(listener.addr()).await;
    assert_eq!(request_hold(&connection).await, None, "an old listener never answers");
    tokio::time::timeout(FIRST_STREAM * 5, connection.closed())
        .await
        .expect("so the client redials its standby as before the hold");
    task.abort();
}

#[tokio::test]
async fn a_new_listener_closes_a_connection_that_sends_anything_but_a_hold() {
    let (listener, _state) = new_listener().await;
    let (_client, connection) = dial(listener.node_addr().await.unwrap()).await;
    let mut sender = connection.open_uni().await.unwrap();
    sender.write_all(b"not a hold").await.unwrap();
    sender.finish().unwrap();
    tokio::time::timeout(Duration::from_secs(5), connection.closed()).await.unwrap();
}

/// A warm standby goes on the socket that does not carry the peer's live link: iroh keeps one
/// selected path per peer per endpoint, so a standby on the link's endpoint rides the link's
/// path and dies with it. The carrier follows the last link opened, so after a failover onto
/// the standby the next standby goes back on the first socket.
#[tokio::test]
async fn a_standby_dials_on_the_socket_apart_from_the_live_link() {
    use crate::provider::{ConnectRequest, LinkRequest, ROUTING_STANDBY, TransportProvider};

    let (listener, _state) = new_listener().await;
    let route = listener.route().await.unwrap();
    let node = route.node_id();
    let provider = super::IrohProvider::new(config()).unwrap();
    let request = |standby: bool| {
        let mut routing = route.routing_hints();
        if standby {
            routing.insert(ROUTING_STANDBY.into(), "1".into());
        }
        ConnectRequest {
            endpoint: format!("iroh://{node}").parse().unwrap(),
            session: cmux_remote_protocol::SessionId([7; 16]),
            lane_policy: cmux_remote_protocol::LanePolicy::Single,
            routing,
        }
    };
    let link = || LinkRequest { lane: cmux_remote_protocol::Lane::Interactive, generation: 1 };

    let active = provider.connect(request(false)).await.unwrap();
    let _link = active.open(link()).await.unwrap();
    assert!(provider.spare.get().is_none(), "a link dial binds no second socket");
    assert_eq!(provider.carriers.of(node), super::Socket::Main);

    let standby = provider.connect(request(true)).await.unwrap();
    let main = provider.endpoint.get().unwrap().id();
    let spare = provider.spare.get().expect("the standby bound the second socket").id();
    assert_ne!(main, spare, "the standby is a different iroh endpoint, with its own paths");
    assert_eq!(provider.carriers.of(node), super::Socket::Main, "a standby carries nothing yet");

    // The link fails over onto the standby: its socket carries the peer now, and the next
    // standby goes on the first socket.
    let _failover = standby.open(link()).await.unwrap();
    assert_eq!(provider.carriers.of(node), super::Socket::Spare);
    assert_eq!(provider.carriers.for_dial(node, true), super::Socket::Main);
    assert_eq!(provider.carriers.for_dial(node, false), super::Socket::Spare);
    provider.close().await;
}

/// After a dead link is abandoned, the redial goes on the socket that held it: closing its
/// last connection cleared iroh's path for the peer there, while the other socket may still
/// hold a standby riding the dead path. The next standby goes apart from the new link.
#[test]
fn a_redial_goes_on_the_socket_the_dead_link_was_abandoned_from() {
    let carriers = super::Carriers::default();
    let node = iroh::SecretKey::from_bytes(&[9; 32]).public();
    assert_eq!(carriers.for_dial(node, false), super::Socket::Main);
    assert_eq!(carriers.for_dial(node, true), super::Socket::Spare);

    // The link failed over onto the standby on Spare; then that link died too.
    carriers.opened(node, super::Socket::Spare);
    carriers.abandoned(node, super::Socket::Spare);
    assert_eq!(carriers.for_dial(node, false), super::Socket::Spare);

    // The redial opened there: the next standby goes on Main.
    carriers.opened(node, super::Socket::Spare);
    assert_eq!(carriers.for_dial(node, true), super::Socket::Main);
}
