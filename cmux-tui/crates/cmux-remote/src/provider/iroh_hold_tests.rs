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
