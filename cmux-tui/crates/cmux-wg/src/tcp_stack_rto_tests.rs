//! The RTO a connection starts with before its first RTT sample: twice the
//! path's round trip, at least 300 ms, so a SYN, SYN-ACK or first data
//! segment on a long path is not resent before its answer can arrive.

use std::collections::VecDeque;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use tokio::io::AsyncWrite;
use tokio::sync::{Notify, oneshot};
use tokio::time::Instant;

use super::{TCP_INITIAL_RTO, TCP_UNKNOWN_PATH_RTO, TcpStack, rto_for_path};
use crate::config::InterfaceAddress;
use crate::pacing::segment;

const PORT: u16 = 7002;
const MTU: u16 = 1380;
const CLIENT_IP: Ipv4Addr = Ipv4Addr::new(10, 202, 0, 1);
const SERVER_IP: Ipv4Addr = Ipv4Addr::new(10, 202, 0, 2);

fn stack(own: Ipv4Addr) -> TcpStack {
    let addresses = [InterfaceAddress { address: IpAddr::V4(own), prefix: 32 }];
    TcpStack::new(&addresses, MTU, Arc::new(Notify::new()), false).expect("stack")
}

#[test]
fn the_initial_rto_is_twice_the_path_rtt_above_300_ms() {
    assert_eq!(rto_for_path(None), TCP_UNKNOWN_PATH_RTO);
    assert_eq!(rto_for_path(Some(Duration::from_millis(10))), TCP_INITIAL_RTO);
    assert_eq!(rto_for_path(Some(Duration::from_millis(150))), TCP_INITIAL_RTO);
    assert_eq!(rto_for_path(Some(Duration::from_millis(400))), Duration::from_millis(800));
}

/// What crossed a link of `rtt` while a client dialed and wrote once.
struct Dial {
    /// When the client's stream opened, from the dial.
    opened: Duration,
    /// SYNs the client sent.
    syns: usize,
    /// SYN-ACKs the server sent.
    syn_acks: usize,
    /// Data segments the client sent, by sequence number.
    data: Vec<u32>,
}

/// A client dials a server through a link of `rtt`, both stacks told the
/// path's round trip (`path_rtt`; the server only after its listener made
/// its spares), writes one small frame once open, and runs for 3 s.
async fn dial(rtt: Duration, path_rtt: Option<Duration>) -> Dial {
    let one_way = rtt / 2;
    let start = Instant::now();
    let mut client = stack(CLIENT_IP);
    let mut server = stack(SERVER_IP);
    let mut accept = server.begin_listen(PORT).expect("listen");
    server.set_path_rtt(path_rtt);
    client.set_path_rtt(path_rtt);
    let (reply, mut connected) = oneshot::channel();
    client.begin_connect(
        IpAddr::V4(CLIENT_IP),
        SocketAddr::new(IpAddr::V4(SERVER_IP), PORT),
        None,
        reply,
    );
    let mut to_server: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
    let mut to_client: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
    let mut cx = Context::from_waker(Waker::noop());
    let mut writer = None;
    let mut reader = None;
    let mut seen = Dial { opened: Duration::ZERO, syns: 0, syn_acks: 0, data: Vec::new() };
    while start.elapsed() < Duration::from_secs(3) {
        let now = Instant::now();
        while to_server.front().is_some_and(|(due, _)| *due <= now) {
            let (_, packet) = to_server.pop_front().expect("due");
            server.push_rx(packet, None);
        }
        while to_client.front().is_some_and(|(due, _)| *due <= now) {
            let (_, packet) = to_client.pop_front().expect("due");
            client.push_rx(packet, None);
        }
        client.step();
        server.step();
        if writer.is_none()
            && let Ok(Ok(mut stream)) = connected.try_recv()
        {
            seen.opened = start.elapsed();
            let written = Pin::new(&mut stream).poll_write(&mut cx, b"first frame");
            assert!(matches!(written, Poll::Ready(Ok(_))), "write: {written:?}");
            writer = Some(stream);
            client.step();
        }
        if reader.is_none()
            && let Ok((stream, _)) = accept.try_recv()
        {
            reader = Some(stream);
        }
        while let Some(packet) = client.pop_tx() {
            let parsed = segment(&packet).expect("a TCP segment");
            if parsed.syn {
                seen.syns += 1;
            } else if parsed.len > 0 {
                seen.data.push(parsed.seq);
            }
            to_server.push_back((now + one_way, packet));
        }
        while let Some(packet) = server.pop_tx() {
            let parsed = segment(&packet).expect("a TCP segment");
            if parsed.syn && parsed.ack.is_some() {
                seen.syn_acks += 1;
            }
            to_client.push_back((now + one_way, packet));
        }
        tokio::time::advance(Duration::from_millis(1)).await;
    }
    assert!(writer.is_some(), "the dial never opened");
    assert!(reader.is_some(), "the server never accepted");
    seen
}

#[tokio::test(start_paused = true)]
async fn a_400_ms_path_resends_no_syn_syn_ack_or_first_data() {
    let rtt = Duration::from_millis(400);
    let seen = dial(rtt, Some(rtt)).await;
    assert_eq!(seen.syns, 1, "the SYN was resent before its answer could arrive");
    assert_eq!(seen.syn_acks, 1, "the SYN-ACK was resent before its answer could arrive");
    assert_eq!(seen.data.len(), 1, "the first data was resent: {:?}", seen.data);
    assert!(
        seen.opened < rtt + Duration::from_millis(50),
        "open after {:?}, not one round trip",
        seen.opened
    );
}

/// The fixed 300 ms RTO this replaces: on the same path the SYN and the
/// SYN-ACK each go twice, and Karn takes no RTT sample from either.
#[tokio::test(start_paused = true)]
async fn a_300_ms_rto_resends_the_syn_on_a_400_ms_path() {
    let rtt = Duration::from_millis(400);
    let seen = dial(rtt, Some(Duration::from_millis(10))).await;
    assert!(seen.syns >= 2, "a 300 ms RTO resent no SYN on a 400 ms path");
}
