//! Unit tests of the driver internals in `net.rs`.

use super::*;

#[tokio::test]
async fn cancelled_hub_dial_releases_the_pending_tcp_socket() {
    let pair = crate::testing::loopback_pair().await.unwrap();
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay =
        SocketPath::new(pair.client_socket, Some(pair.server_socket.local_addr().unwrap()));
    let mut driver =
        Driver::new(pair.client, Box::new(underlay), receiver, Arc::new(Notify::new())).unwrap();
    let (reply, pending) = oneshot::channel();
    driver.begin_connect(SocketAddr::new(pair.server_v6, 1337), reply);
    assert_eq!(driver.stack.conns.len(), 1);
    assert_eq!(driver.stack.sockets.iter().count(), 1);

    drop(pending);
    driver.stack.process_conns();

    assert!(driver.stack.conns.is_empty(), "a cancelled dial must not wait for TCP_TIMEOUT");
    assert_eq!(driver.stack.sockets.iter().count(), 0);
}
