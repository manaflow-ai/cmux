//! The send gate ([`crate::send_gate`]) between two real stacks over a
//! simulated link: a writer that schedules by priority (a latency-bound
//! "echo" before a flood, as cmux-mobile-link's link writer does) gets its
//! echo out within a few milliseconds of data, not behind every byte the
//! stream would otherwise have queued, and the flood keeps its throughput.
//!
//! The link is a fixed one-way delay, no loss, on Tokio's paused clock, so a
//! run is deterministic and takes milliseconds.

use std::collections::VecDeque;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{Notify, oneshot};
use tokio::time::Instant;

use crate::config::InterfaceAddress;
use crate::stream::WgStream;
use crate::tcp_stack::TcpStack;

const PORT: u16 = 7001;
const MTU: u16 = 1380;
const CLIENT_IP: Ipv4Addr = Ipv4Addr::new(10, 201, 0, 1);
const SERVER_IP: Ipv4Addr = Ipv4Addr::new(10, 201, 0, 2);
/// The flood's writes: the link writer's data frame size.
const CHUNK: usize = 16 * 1024;
const FLOOD_BYTE: u8 = 0x5a;
const ECHO_BYTE: u8 = 0xee;
const ECHO_BYTES: usize = 64;

fn stack(own: Ipv4Addr) -> TcpStack {
    let addresses = [InterfaceAddress { address: IpAddr::V4(own), prefix: 32 }];
    TcpStack::new(&addresses, MTU, Arc::new(Notify::new()), false).expect("stack")
}

/// What one run measured.
struct Run {
    /// From queueing the echo at the writer to its first byte at the reader.
    echo: Duration,
    /// Flood bytes the reader got in the second before the echo.
    flood_bytes_per_second: usize,
}

/// A server floods a client through a link of `rtt`; at `echo_at` the
/// server's writer queues a small echo, which it writes before any more of
/// the flood.
async fn flood_then_echo(rtt: Duration, echo_at: Duration) -> Run {
    let one_way = rtt / 2;
    let start = Instant::now();
    let mut client = stack(CLIENT_IP);
    let mut server = stack(SERVER_IP);
    let mut accept = server.begin_listen(PORT).expect("listen");
    let (reply, mut connected) = oneshot::channel();
    client.begin_connect(
        IpAddr::V4(CLIENT_IP),
        SocketAddr::new(IpAddr::V4(SERVER_IP), PORT),
        None,
        reply,
    );
    let mut to_server: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
    let mut to_client: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
    let mut reader: Option<WgStream> = None;
    let mut writer: Option<WgStream> = None;
    let mut cx = Context::from_waker(Waker::noop());
    // The writer's scheduler: the echo goes before the rest of the flood.
    let mut echo_queued: Option<Instant> = None;
    let mut echo_left = 0usize;
    let mut flood_left = 0usize;
    let mut echo_seen: Option<Instant> = None;
    let mut flood_window = 0usize;
    let flood = vec![FLOOD_BYTE; CHUNK];
    let echo = [ECHO_BYTE; ECHO_BYTES];
    let mut buffer = vec![0u8; 64 * 1024];
    while echo_seen.is_none() {
        let now = Instant::now();
        assert!(now - start < echo_at + Duration::from_secs(10), "the echo never arrived");
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
        if reader.is_none()
            && let Ok(Ok(stream)) = connected.try_recv()
        {
            reader = Some(stream);
        }
        if writer.is_none()
            && let Ok((stream, _)) = accept.try_recv()
        {
            writer = Some(stream);
        }
        if let Some(stream) = writer.as_mut() {
            if echo_queued.is_none() && now - start >= echo_at {
                echo_queued = Some(now);
                echo_left = ECHO_BYTES;
            }
            loop {
                // A frame already started finishes first, as on a byte stream.
                let (bytes, left) = if flood_left > 0 && flood_left < CHUNK {
                    (&flood[CHUNK - flood_left..], &mut flood_left)
                } else if echo_left > 0 {
                    (&echo[ECHO_BYTES - echo_left..], &mut echo_left)
                } else {
                    if flood_left == 0 {
                        flood_left = CHUNK;
                    }
                    (&flood[CHUNK - flood_left..], &mut flood_left)
                };
                match Pin::new(&mut *stream).poll_write(&mut cx, bytes) {
                    Poll::Ready(Ok(count)) => *left -= count,
                    Poll::Ready(Err(error)) => panic!("write: {error}"),
                    Poll::Pending => break,
                }
            }
        }
        if let Some(stream) = reader.as_mut() {
            loop {
                let mut read = ReadBuf::new(&mut buffer);
                match Pin::new(&mut *stream).poll_read(&mut cx, &mut read) {
                    Poll::Ready(Ok(())) if !read.filled().is_empty() => {
                        let filled = read.filled();
                        if filled.contains(&ECHO_BYTE) {
                            echo_seen = Some(now);
                        }
                        if now - start + Duration::from_secs(1) >= echo_at && echo_queued.is_none()
                        {
                            flood_window +=
                                filled.iter().filter(|byte| **byte == FLOOD_BYTE).count();
                        }
                    }
                    Poll::Ready(Ok(())) => panic!("the flood ended"),
                    Poll::Ready(Err(error)) => panic!("read: {error}"),
                    Poll::Pending => break,
                }
            }
        }
        client.step();
        server.step();
        while let Some(packet) = client.pop_tx() {
            to_server.push_back((now + one_way, packet));
        }
        while let Some(packet) = server.pop_tx() {
            to_client.push_back((now + one_way, packet));
        }
        tokio::time::advance(Duration::from_micros(500)).await;
    }
    Run {
        echo: echo_seen.expect("seen") - echo_queued.expect("queued"),
        flood_bytes_per_second: flood_window,
    }
}

/// Over a 40 ms round trip, an echo queued behind a flood used to wait for
/// the stream's channel (32 writes) and the socket's 256 KiB send buffer to
/// drain (200 ms, and 25 Mbit/s of flood); with the gate it waits for a few
/// milliseconds of unsent bytes and the flood's burst in flight, and the flood loses no
/// throughput: the window, not the gate, still bounds it.
#[tokio::test(start_paused = true)]
async fn an_echo_queued_behind_a_flood_waits_milliseconds_not_the_whole_backlog() {
    let rtt = Duration::from_millis(40);
    let run = flood_then_echo(rtt, Duration::from_secs(4)).await;
    eprintln!(
        "echo after {:?}; flood {:.1} Mbit/s",
        run.echo,
        run.flood_bytes_per_second as f64 * 8.0 / 1e6
    );
    // One way (20 ms), plus at most half a round trip for the window in flight.
    assert!(run.echo <= rtt * 3 / 2, "the echo waited {:?}", run.echo);
    // The receive window (256 KiB) per round trip is 52 Mbit/s; the flood
    // keeps most of it.
    assert!(
        run.flood_bytes_per_second as f64 * 8.0 / 1e6 >= 40.0,
        "the flood ran at {} bytes/s",
        run.flood_bytes_per_second
    );
}
