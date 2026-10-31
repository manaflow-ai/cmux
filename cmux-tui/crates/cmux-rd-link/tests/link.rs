//! Two links over an in-memory network that loses, duplicates and reorders
//! packets: the handshake finishes, datagrams open, control records arrive
//! once and in order, and a peer with a key the hub did not vouch for, a
//! tampered packet or a replay gets nothing.

use cmux_rd_link::{Event, KeyPair, Link, LinkError, Role};

const SESSION: &[u8] = b"session-7f3a";

/// A deterministic lossy, reordering, duplicating pipe.
struct Net {
    seed: u64,
    loss_percent: u64,
}

impl Net {
    fn rand(&mut self) -> u64 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 7;
        self.seed ^= self.seed << 17;
        self.seed
    }

    fn carry(&mut self, packets: Vec<Vec<u8>>) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        for p in packets {
            if self.rand() % 100 < self.loss_percent {
                continue;
            }
            if self.rand().is_multiple_of(10) {
                out.push(p.clone()); // duplicate
            }
            out.push(p);
        }
        if out.len() > 1 && self.rand().is_multiple_of(2) {
            out.reverse(); // reorder
        }
        out
    }
}

fn pair() -> (Link, Link, u64) {
    let (viewer_keys, host_keys) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let viewer = Link::new(Role::Initiator, SESSION, &viewer_keys, host_keys.public, 0).unwrap();
    let host = Link::new(Role::Responder, SESSION, &host_keys, viewer_keys.public, 0).unwrap();
    (viewer, host, 0)
}

/// Runs both links for `steps` ticks of 10 ms, collecting each side's events.
fn run(
    viewer: &mut Link,
    host: &mut Link,
    net: &mut Net,
    now: &mut u64,
    steps: usize,
) -> (Vec<Event>, Vec<Event>) {
    let (mut at_viewer, mut at_host) = (Vec::new(), Vec::new());
    for _ in 0..steps {
        *now += 10_000;
        for p in net.carry(viewer.poll_transmit(*now).unwrap()) {
            at_host.extend(host.on_packet(&p, *now).unwrap());
        }
        for p in net.carry(host.poll_transmit(*now).unwrap()) {
            at_viewer.extend(viewer.on_packet(&p, *now).unwrap());
        }
    }
    (at_viewer, at_host)
}

#[test]
fn handshake_control_and_datagrams_survive_a_lossy_reordering_path() {
    let (mut viewer, mut host, mut now) = pair();
    let mut net = Net { seed: 0x9e37_79b9_7f4a_7c15, loss_percent: 20 };
    for i in 0..50u32 {
        viewer.send_control(format!("viewer {i}").into_bytes(), now).unwrap();
    }
    let (at_viewer, at_host) = run(&mut viewer, &mut host, &mut net, &mut now, 400);
    assert!(viewer.is_established() && host.is_established());
    assert!(at_viewer.contains(&Event::Established) && at_host.contains(&Event::Established));
    let records: Vec<_> = at_host
        .iter()
        .filter_map(|e| match e {
            Event::Control(r) => Some(r.clone()),
            _ => None,
        })
        .collect();
    let expected: Vec<_> = (0..50u32).map(|i| format!("viewer {i}").into_bytes()).collect();
    assert_eq!(records, expected, "every control record once, in order, despite 20 % loss");

    // Datagrams are best effort: what arrives opens to the bytes sent, never twice.
    let mut sent = Vec::new();
    for i in 0..200u32 {
        let d = i.to_le_bytes().to_vec();
        sent.push(d.clone());
        let p = host.seal_datagram(&d).unwrap();
        for p in net.carry(vec![p]) {
            for e in viewer.on_packet(&p, now).unwrap() {
                if let Event::Datagram(got) = e {
                    assert!(sent.contains(&got));
                    sent.retain(|s| s != &got);
                }
            }
        }
    }
    assert!(sent.len() < 80, "most datagrams arrive: {} of 200 lost", sent.len());
}

#[test]
fn a_peer_the_hub_did_not_vouch_for_is_refused() {
    let (viewer_keys, host_keys, stranger) =
        (KeyPair::generate().unwrap(), KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    // The viewer expects `host_keys`, but a stranger answers.
    let mut viewer =
        Link::new(Role::Initiator, SESSION, &viewer_keys, host_keys.public, 0).unwrap();
    let mut impostor =
        Link::new(Role::Responder, SESSION, &stranger, viewer_keys.public, 0).unwrap();
    let hello = viewer.poll_transmit(0).unwrap();
    impostor.on_packet(&hello[0], 0).unwrap();
    let reply = impostor.poll_transmit(0).unwrap();
    assert!(matches!(viewer.on_packet(&reply[0], 0), Err(LinkError::WrongPeer)));
    assert!(!viewer.is_established());
}

#[test]
fn another_sessions_handshake_does_not_complete() {
    let (viewer_keys, host_keys) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut viewer =
        Link::new(Role::Initiator, b"session-a", &viewer_keys, host_keys.public, 0).unwrap();
    let mut host =
        Link::new(Role::Responder, b"session-b", &host_keys, viewer_keys.public, 0).unwrap();
    let mut net = Net { seed: 7, loss_percent: 0 };
    let mut now = 0;
    run(&mut viewer, &mut host, &mut net, &mut now, 20);
    assert!(!viewer.is_established() && !host.is_established());
}

#[test]
fn tampered_and_replayed_packets_are_dropped() {
    let (mut viewer, mut host, mut now) = pair();
    let mut net = Net { seed: 3, loss_percent: 0 };
    run(&mut viewer, &mut host, &mut net, &mut now, 5);
    let packet = host.seal_datagram(b"frame").unwrap();
    assert_eq!(viewer.on_packet(&packet, now).unwrap(), vec![Event::Datagram(b"frame".to_vec())]);
    assert!(viewer.on_packet(&packet, now).unwrap().is_empty(), "a replay opens nothing");
    let mut tampered = host.seal_datagram(b"frame").unwrap();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    assert!(viewer.on_packet(&tampered, now).unwrap().is_empty(), "a changed packet opens nothing");
}

#[test]
fn a_handshake_with_no_answer_times_out() {
    let keys = KeyPair::generate().unwrap();
    let mut viewer = Link::new(Role::Initiator, SESSION, &keys, [7; 32], 0).unwrap();
    let mut resent = 0;
    let mut now = 0;
    let result = loop {
        now += 250_000;
        match viewer.poll_transmit(now) {
            Ok(p) => resent += p.len(),
            Err(e) => break e,
        }
    };
    assert!(matches!(result, LinkError::HandshakeTimeout));
    assert!(resent >= 30, "message 1 was retried until the timeout ({resent})");
}
