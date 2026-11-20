//! The sans-IO TURN client against scripted server answers and an injected
//! clock: the long-term credential exchange, integrity checks, refresh
//! before expiry, channels, and hostile input that must not panic or loop.

#[path = "support/stun.rs"]
mod stun;

use cmux_rd_link::turn::{TurnClient, TurnError, TurnEvent, TurnReceive};
use std::net::SocketAddr;
use stun::*;

const USER: &str = "alice";
const PASS: &str = "secret";
const REALM_NAME: &str = "example.org";

fn relayed() -> SocketAddr {
    "203.0.113.7:49152".parse().unwrap()
}

fn peer() -> SocketAddr {
    "198.51.100.9:6000".parse().unwrap()
}

fn only(packets: Vec<Vec<u8>>) -> Msg {
    assert_eq!(packets.len(), 1, "one packet expected");
    parse(&packets[0]).expect("a STUN message")
}

fn unauthorized(tx: Tx) -> Vec<u8> {
    build(
        ALLOCATE | ERROR,
        tx,
        &[
            (ERROR_CODE, error_code(401, "Unauthorized")),
            (REALM, REALM_NAME.as_bytes().to_vec()),
            (NONCE, b"abc".to_vec()),
        ],
        None,
    )
}

fn allocate_success(tx: Tx, lifetime: u32, key: &[u8; 16]) -> Vec<u8> {
    build(
        ALLOCATE | SUCCESS,
        tx,
        &[
            (XOR_RELAYED_ADDRESS, xor_addr(relayed(), &tx)),
            (XOR_MAPPED_ADDRESS, xor_addr("192.0.2.1:1234".parse().unwrap(), &tx)),
            (LIFETIME, lifetime.to_be_bytes().to_vec()),
        ],
        Some(key),
    )
}

/// Runs the exchange up to an allocation; returns the client and its clock.
fn allocated(lifetime: u32) -> TurnClient {
    let key = key(USER, REALM_NAME, PASS);
    let mut client = TurnClient::new(USER, PASS, [7; 32]);
    let first = only(client.poll_transmit(0));
    assert_eq!(first.kind, ALLOCATE);
    assert!(first.integrity.is_none(), "the first Allocate carries no credentials");
    assert_eq!(client.on_packet(&unauthorized(first.tx), 1_000), TurnReceive::Handled);
    let packets = client.poll_transmit(1_000);
    let second = only(packets.clone());
    assert_eq!(second.kind, ALLOCATE);
    assert_eq!(second.get(USERNAME), Some(USER.as_bytes()));
    assert_eq!(second.get(NONCE), Some(&b"abc"[..]));
    assert!(integrity_ok(&packets[0], second.integrity.unwrap(), &key), "HMAC-SHA1 with MD5 key");
    assert_eq!(
        client.on_packet(&allocate_success(second.tx, lifetime, &key), 2_000),
        TurnReceive::Handled
    );
    assert_eq!(
        client.take_events(),
        vec![TurnEvent::Allocated {
            relayed: relayed(),
            mapped: Some("192.0.2.1:1234".parse().unwrap())
        }]
    );
    assert_eq!(client.relayed(), Some(relayed()));
    client
}

#[test]
fn allocate_answers_the_401_with_long_term_credentials() {
    allocated(600);
}

#[test]
fn a_success_without_valid_integrity_is_not_believed() {
    let mut client = TurnClient::new(USER, PASS, [1; 32]);
    let first = only(client.poll_transmit(0));
    client.on_packet(&unauthorized(first.tx), 0);
    let second = only(client.poll_transmit(0));
    let forged = allocate_success(second.tx, 600, &key(USER, REALM_NAME, "not the password"));
    assert_eq!(client.on_packet(&forged, 0), TurnReceive::Handled);
    assert_eq!(client.relayed(), None);
    assert!(client.take_events().is_empty());
    // The request is still pending and retransmitted.
    assert_eq!(only(client.poll_transmit(300_000)).tx, second.tx);
}

/// The pending request is found by transaction id, then its method is checked,
/// then (for an authenticated request) the integrity: a stranger, a truncated
/// header and another method's answer leave the request pending, and the
/// genuine answer still allocates.
#[test]
fn a_response_matches_its_request_by_transaction_and_method() {
    let key = key(USER, REALM_NAME, PASS);
    let mut client = TurnClient::new(USER, PASS, [4; 32]);
    let first = only(client.poll_transmit(0));
    client.on_packet(&unauthorized(first.tx), 0);
    let second = only(client.poll_transmit(0));

    let mut stranger = second.tx;
    stranger[0] ^= 0xFF;
    assert_eq!(client.on_packet(&allocate_success(stranger, 600, &key), 0), TurnReceive::Ignored);
    let genuine = allocate_success(second.tx, 600, &key);
    for cut in [1, 4, 19, 20, genuine.len() - 1] {
        assert_eq!(client.on_packet(&genuine[..cut], 0), TurnReceive::Ignored, "cut at {cut}");
    }
    let wrong_method = build(
        REFRESH | SUCCESS,
        second.tx,
        &[(LIFETIME, 600u32.to_be_bytes().to_vec())],
        Some(&key),
    );
    assert_eq!(client.on_packet(&wrong_method, 0), TurnReceive::Handled);
    assert_eq!(client.relayed(), None);
    assert!(client.take_events().is_empty());

    assert_eq!(only(client.poll_transmit(300_000)).tx, second.tx, "still pending");
    assert_eq!(client.on_packet(&genuine, 300_000), TurnReceive::Handled);
    assert_eq!(client.relayed(), Some(relayed()));
}

#[test]
fn a_401_after_credentials_fails_and_a_438_retries_with_the_new_nonce() {
    let mut client = TurnClient::new(USER, PASS, [2; 32]);
    let first = only(client.poll_transmit(0));
    client.on_packet(&unauthorized(first.tx), 0);
    let second = only(client.poll_transmit(0));
    let stale = build(
        ALLOCATE | ERROR,
        second.tx,
        &[(ERROR_CODE, error_code(438, "Stale Nonce")), (NONCE, b"fresh".to_vec())],
        None,
    );
    client.on_packet(&stale, 0);
    let third = only(client.poll_transmit(0));
    assert_eq!(third.get(NONCE), Some(&b"fresh"[..]));
    assert_ne!(third.tx, second.tx);
    client.on_packet(&unauthorized(third.tx), 0);
    assert_eq!(client.take_events(), vec![TurnEvent::Failed(TurnError::Unauthorized)]);
    assert!(client.is_failed());
    assert!(client.poll_transmit(10_000_000).is_empty(), "a refused key is not retried");
    assert_eq!(client.next_deadline_us(), None);
}

#[test]
fn an_unanswered_allocate_times_out() {
    let mut client = TurnClient::new(USER, PASS, [3; 32]);
    let mut sent = 0;
    let mut now = 0;
    while let Some(at) = client.next_deadline_us() {
        now = at.max(now);
        sent += client.poll_transmit(now).len();
        assert!(sent < 20, "retransmissions are bounded");
    }
    assert_eq!(client.take_events(), vec![TurnEvent::Failed(TurnError::Timeout)]);
    assert!(now < 20_000_000);
}

#[test]
fn the_allocation_is_refreshed_before_it_expires_and_expires_without_an_answer() {
    let key = key(USER, REALM_NAME, PASS);
    let mut client = allocated(10);
    let start = 2_000;
    assert!(client.poll_transmit(start + 4_000_000).is_empty());
    let refresh = only(client.poll_transmit(start + 5_000_000));
    assert_eq!(refresh.kind, REFRESH);
    let answer = build(
        REFRESH | SUCCESS,
        refresh.tx,
        &[(LIFETIME, 10u32.to_be_bytes().to_vec())],
        Some(&key),
    );
    client.on_packet(&answer, start + 5_000_000);
    // The new lifetime counts from the answer: no expiry at the old deadline.
    let _ = client.poll_transmit(start + 10_000_000);
    assert!(client.take_events().is_empty());
    assert_eq!(client.relayed(), Some(relayed()));
    // The next refresh goes unanswered: the allocation expires.
    let mut now = start + 10_000_000;
    while client.relayed().is_some() && now < start + 30_000_000 {
        now += 100_000;
        let _ = client.poll_transmit(now);
    }
    assert_eq!(client.take_events(), vec![TurnEvent::Failed(TurnError::Expired)]);
    assert!(now <= start + 15_200_000, "expired at the lifetime, at {now}");
}

#[test]
fn data_moves_in_send_indications_then_channel_data() {
    let key = key(USER, REALM_NAME, PASS);
    let mut client = allocated(600);
    assert!(client.add_peer(peer(), 3_000));
    let requests: Vec<Msg> =
        client.poll_transmit(3_000).iter().map(|p| parse(p).unwrap()).collect();
    let permission = requests.iter().find(|m| m.kind == CREATE_PERMISSION).unwrap();
    let bind = requests.iter().find(|m| m.kind == CHANNEL_BIND).unwrap();
    let number = u16::from_be_bytes([
        bind.get(CHANNEL_NUMBER).unwrap()[0],
        bind.get(CHANNEL_NUMBER).unwrap()[1],
    ]);
    assert!((0x4000..=0x4FFF).contains(&number));
    assert_eq!(unxor_addr(bind.get(XOR_PEER_ADDRESS).unwrap(), &bind.tx), Some(peer()));
    assert_eq!(
        unxor_addr(permission.get(XOR_PEER_ADDRESS).unwrap(), &permission.tx).map(|a| a.ip()),
        Some(peer().ip())
    );

    // Before the channel is bound: a Send indication.
    let send = parse(&client.send(peer(), b"\xD3sealed", 3_000).unwrap()).unwrap();
    assert_eq!(send.kind, SEND_INDICATION);
    assert_eq!(send.get(DATA), Some(&b"\xD3sealed"[..]));

    client.on_packet(&build(CREATE_PERMISSION | SUCCESS, permission.tx, &[], Some(&key)), 4_000);
    client.on_packet(&build(CHANNEL_BIND | SUCCESS, bind.tx, &[], Some(&key)), 4_000);
    assert_eq!(
        client.send(peer(), b"\xD3sealed", 4_000),
        Some(channel_data(number, b"\xD3sealed"))
    );

    // Inbound: ChannelData and Data indications name the peer.
    let inbound = channel_data(number, b"\xD3from-peer");
    assert_eq!(
        client.on_packet(&inbound, 5_000),
        TurnReceive::Data { peer: peer(), payload: b"\xD3from-peer" }
    );
    let tx = [9; 12];
    let indication = build(
        DATA_INDICATION,
        tx,
        &[(XOR_PEER_ADDRESS, xor_addr(peer(), &tx)), (DATA, b"\xD3x".to_vec())],
        None,
    );
    assert_eq!(
        client.on_packet(&indication, 5_000),
        TurnReceive::Data { peer: peer(), payload: b"\xD3x" }
    );
    // Data from a peer without a permission, or on an unknown channel, is dropped.
    let stranger: SocketAddr = "192.0.2.200:1".parse().unwrap();
    let foreign = build(
        DATA_INDICATION,
        tx,
        &[(XOR_PEER_ADDRESS, xor_addr(stranger, &tx)), (DATA, b"x".to_vec())],
        None,
    );
    assert_eq!(client.on_packet(&foreign, 5_000), TurnReceive::Handled);
    assert_eq!(client.on_packet(&channel_data(number + 1, b"x"), 5_000), TurnReceive::Handled);
    // A ChannelData longer than the datagram is dropped.
    let mut lying = channel_data(number, b"abc");
    lying[3] = 200;
    assert_eq!(client.on_packet(&lying, 5_000), TurnReceive::Handled);
    // Permissions are refreshed every 4 minutes.
    let refreshes: Vec<Msg> =
        client.poll_transmit(4_000 + 240_000_000).iter().map(|p| parse(p).unwrap()).collect();
    assert!(refreshes.iter().any(|m| m.kind == CREATE_PERMISSION), "permission refreshed");
}

#[test]
fn the_peer_table_is_bounded() {
    let mut client = allocated(600);
    let added = (0..100u16)
        .filter(|i| {
            client.add_peer(SocketAddr::new([10, 0, (i / 256) as u8, (i % 256) as u8].into(), 1), 0)
        })
        .count();
    assert_eq!(added, cmux_rd_link::turn::MAX_PEERS);
}

#[test]
fn hostile_input_never_panics_or_floods() {
    let key = key(USER, REALM_NAME, PASS);
    let mut rng = Rng(0x1234_5678_9ABC_DEF1);
    for round in 0..40u64 {
        let mut client = allocated(600);
        client.add_peer(peer(), 3_000);
        let pending: Vec<Msg> =
            client.poll_transmit(3_000).iter().map(|p| parse(p).unwrap()).collect();
        let tx = pending[0].tx;
        let tx2 = pending[1].tx;
        let bases = [
            unauthorized(tx),
            allocate_success(tx, 1, &key),
            build(CHANNEL_BIND | SUCCESS, tx2, &[], Some(&key)),
            build(
                CREATE_PERMISSION | ERROR,
                tx,
                &[(ERROR_CODE, error_code(438, "x")), (NONCE, vec![b'n'; 700])],
                None,
            ),
            build(
                DATA_INDICATION,
                tx,
                &[(XOR_PEER_ADDRESS, xor_addr(peer(), &tx)), (DATA, vec![0xD3; 64])],
                None,
            ),
            channel_data(0x4000, &[0xD3; 64]),
        ];
        let mut now = 3_000 + round;
        for _ in 0..2_000 {
            let base = &bases[rng.below(bases.len())];
            let packet = rng.mutate(base);
            let _ = client.on_packet(&packet, now);
            now += rng.below(50_000) as u64;
            let out = client.poll_transmit(now);
            assert!(
                out.len() <= 2 * cmux_rd_link::turn::MAX_PEERS + 4,
                "bounded output: {}",
                out.len()
            );
            // Everything due was served by that poll: no deadline in the past (no busy loop).
            if let Some(at) = client.next_deadline_us() {
                assert!(at > now, "deadline {at} not after {now}");
            }
            let _ = client.send(peer(), &[0xD3; 32], now);
            let _ = client.take_events();
        }
    }
}
