//! Unit tests of the stack's peer tags: an accepted connection carries the
//! key of the session that delivered its SYN, never one guessed from its
//! address, and removing a peer fails its streams.

use std::net::{IpAddr, SocketAddr};

use tokio::io::AsyncReadExt;

use super::*;

const SERVER: &str = "fd7c:6d78::1";
const CLIENT: &str = "fd7c:6d78::2";
const KEY: PeerKey = [7; 32];

fn address(text: &str) -> IpAddr {
    text.parse().unwrap()
}

fn stack(own: &str, tagged: bool) -> TcpStack {
    let addresses = [InterfaceAddress { address: address(own), prefix: 128 }];
    TcpStack::new(&addresses, 1380, Arc::new(Notify::new()), tagged).unwrap()
}

/// Run both stacks and carry packets between them until both are quiet.
/// `tag` is the key the server's engine reports for each packet it receives.
fn exchange(client: &mut TcpStack, server: &mut TcpStack, mut tag: impl FnMut() -> Option<PeerKey>) {
    for _ in 0..64 {
        client.step();
        server.step();
        let mut moved = false;
        while let Some(packet) = client.pop_tx() {
            server.push_rx(packet, tag());
            moved = true;
        }
        while let Some(packet) = server.pop_tx() {
            client.push_rx(packet, None);
            moved = true;
        }
        if !moved {
            return;
        }
    }
    panic!("the stacks never settled");
}

fn dial(client: &mut TcpStack) -> oneshot::Receiver<Result<WgStream, WgError>> {
    let (reply, answer) = oneshot::channel();
    client.begin_connect(address(CLIENT), SocketAddr::new(address(SERVER), 4100), None, reply);
    answer
}

#[tokio::test]
async fn an_accepted_connection_carries_the_key_that_delivered_its_syn() {
    let mut server = stack(SERVER, true);
    let mut client = stack(CLIENT, false);
    let mut incoming = server.begin_listen(4100).unwrap();
    let mut answer = dial(&mut client);
    exchange(&mut client, &mut server, || Some(KEY));

    let (stream, tag) = incoming.try_recv().expect("accepted");
    assert_eq!(tag, Some(KEY));
    assert_eq!(stream.peer_addr().ip(), address(CLIENT));
    assert!(answer.try_recv().unwrap().is_ok());
    assert!(server.syn_origins.as_ref().unwrap().is_empty(), "the origin is consumed");
}

#[tokio::test]
async fn a_syn_without_a_session_key_is_never_accepted() {
    let mut server = stack(SERVER, true);
    let mut client = stack(CLIENT, false);
    let mut incoming = server.begin_listen(4100).unwrap();
    let _answer = dial(&mut client);
    exchange(&mut client, &mut server, || None);
    assert!(incoming.try_recv().is_err(), "an untagged SYN must not open a connection");
}

#[tokio::test]
async fn a_connection_whose_syn_origin_is_gone_is_reset_not_matched_by_address() {
    let mut server = stack(SERVER, true);
    let mut client = stack(CLIENT, false);
    let mut incoming = server.begin_listen(4100).unwrap();
    let _answer = dial(&mut client);
    // Deliver the SYN only, with a key, so the server is half-open.
    client.step();
    while let Some(packet) = client.pop_tx() {
        server.push_rx(packet, Some(KEY));
    }
    server.step();
    assert_eq!(server.syn_origins.as_ref().unwrap().len(), 1);
    // The origin disappears (as if its peer had gone); the handshake still
    // completes from the same address.
    server.syn_origins.as_mut().unwrap().clear();
    exchange(&mut client, &mut server, || Some(KEY));
    assert!(incoming.try_recv().is_err(), "no key may be derived from the address");
}

#[tokio::test]
async fn aborting_a_peer_fails_its_streams_with_an_error() {
    let mut server = stack(SERVER, true);
    let mut client = stack(CLIENT, false);
    let mut incoming = server.begin_listen(4100).unwrap();
    let _answer = dial(&mut client);
    exchange(&mut client, &mut server, || Some(KEY));
    let (mut stream, _) = incoming.try_recv().expect("accepted");
    server.step();

    server.abort_peer([9; 32]);
    assert_eq!(server.conns.len(), 1, "another key's removal leaves the connection");
    server.abort_peer(KEY);
    assert!(server.conns.is_empty());
    let mut byte = [0u8; 1];
    let error = stream.read(&mut byte).await.unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::ConnectionReset);
}

#[test]
fn syn_origins_stay_bounded() {
    let mut server = stack(SERVER, true);
    let _incoming = server.begin_listen(4100).unwrap();
    for port in 0..(MAX_SYN_ORIGINS as u16 + 500) {
        let mut client = stack(CLIENT, false);
        let (reply, _answer) = oneshot::channel();
        client.next_port = 10_000 + port;
        client.begin_connect(address(CLIENT), SocketAddr::new(address(SERVER), 4100), None, reply);
        client.step();
        while let Some(packet) = client.pop_tx() {
            server.push_rx(packet, Some(KEY));
        }
        // The SYNs are never processed: the device keeps them, the map may not.
        assert!(server.syn_origins.as_ref().unwrap().len() <= MAX_SYN_ORIGINS);
    }
}
