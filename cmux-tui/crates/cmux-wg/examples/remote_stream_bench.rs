//! A desktop-stream workload over each remote byte path, on real sockets.
//!
//! One process plays both ends: a host that sends a keyframe and then frames
//! at a fixed rate, and a viewer that sends an input event every 20 ms. The
//! host stamps the first frame it sends after an input with that input's send
//! time, so the viewer measures input to photon over the network (the host's
//! capture and encode are not part of it). Both ends share one clock.
//!
//! Paths:
//! - `tcp`: kernel TCP on loopback (RFB direct, an SSH forward, or the lower
//!   bound of a WebSocket relay).
//! - `wg-tcp`: one userspace TCP connection through cmux-wg over loopback UDP
//!   (RFB or the rd stream carrier through the Cloud tunnel).
//! - `wg-dgram`: cmux-wg's datagram service, frames cut into datagrams with
//!   no retransmission (the floor an rd media path could reach).
//! - `rd-link`: Cloud desktop media on the datagram path (cmuxterm-hq#7976):
//!   the rd media engine (FEC, NACK resends, recovery keyframes) and the Mac
//!   viewer's receiver and input channel, sealed by a `cmux-rd-link`
//!   endpoint on each side over UDP, with input and feedback going back as
//!   datagrams too (see `remote_stream_rd/link.rs`). `--rd-frames-in-flight`
//!   overrides the engine's frames in flight (default: the link host's rule)
//!   and `--rd-deadline-ms` the viewer's reassembly deadline (200).
//!
//! Fast-path selection (`wg-tcp` only):
//! - `--paths lan:1,relay:40` gives the viewer one multipath underlay with a
//!   path per entry (kind `lan`, `wan`, `region` or `relay`, then its round
//!   trip in ms), each over its own in-process link, probed inside the
//!   session; the host answers on whichever path last reached it.
//!   `--drop-at 4:0` cuts path 0 (both directions) 4 s into the stream, as a
//!   cable pulled or a Wi-Fi network left.
//! - Two hosts: `--role host --listen 0.0.0.0:51830` on one machine and
//!   `--role viewer --peer lan=192.168.1.20:51830 --peer tailnet=100.64.0.20:51830`
//!   on the other (any labels; `--seed` must match). The viewer dials every
//!   peer address as a path and reports which one carried the stream. Only
//!   viewer-clock numbers (input to photon, frame gaps, bulk) are reported.
//!   `--drop-at 4:0` on the viewer cuts its path to the first `--peer` 4 s in:
//!   the viewer drops that path's datagrams both ways, the host's
//!   interfaces stay as they are.
//!
//! - `--path wg-mesh` runs the same `--paths` and `--drop-at` through two
//!   `WgMesh` ends (the `cmux link` and acpmux engine) instead: the viewer's
//!   peer gets one candidate address per path, the host learns the viewer's
//!   addresses from its datagrams. The lines marked `bench: candidates` are
//!   all that needs a mesh with several addresses per peer; without them
//!   the mode runs against a mesh that holds one.
//!
//! `longest_frame_gap_ms` is the longest wait between two frames at the
//! viewer: a path that dropped shows up there as a stall.
//!
//! `CMUX_WG_ULTRA` (`auto`, `dup`, `fec:8:2`, `rs:4:4`, see `cmux_wg::UltraChoice`) turns on
//! ultra mode on both ends, and `CMUX_WG_ULTRA_HOST` gives the host its own
//! (`off`: the viewer alone asked for it); the note says what it sent and
//! rebuilt.
//!
//! `--rtt-ms` and `--loss-pct` put the WireGuard paths' UDP through an
//! in-process link with that round trip and that loss in each direction;
//! kernel TCP runs on plain loopback only. `--bulk-bytes 0` skips the bulk
//! transfer after the stream. `scripts/remote-stream-bench.sh`
//! runs the matrix, `scripts/remote-stream-ultra-bench.sh` the ultra-mode one,
//! `scripts/remote-stream-rd-link-bench.sh` `wg-tcp` against `rd-link`.
//! Prints one JSON object.
//!
//! ```text
//! cargo run --release -p cmux-wg --example remote_stream_bench -- \
//!     --path wg-tcp --rtt-ms 50 --loss-pct 1 --seconds 10
//! ```

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_wg::testing::{config_pair, random_keypair};
use cmux_wg::{
    Multipath, MultipathControl, PathId, PathKind, Priority, ProbeConfig, SocketPath, WgNet,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::time::{Instant, sleep_until, timeout, timeout_at};

const STREAM_PORT: u16 = 5900;
const BULK_PORT: u16 = 5901;
const MEDIA_PORT: u16 = 4103;
const INPUT_INTERVAL: Duration = Duration::from_millis(20);
/// A frame later than this behind its send time counts as late.
const LATE: Duration = Duration::from_millis(100);
const KIND_FRAME: u8 = 0;
const KIND_INPUT: u8 = 1;
/// kind, seq, sent_us, echo_us.
const HEADER: usize = 1 + 4 + 8 + 8;

// The Mac viewer's Rust (cmux-rd-ffi is its own workspace, built only for
// the app), compiled in from its source so the bench runs that exact code.
#[allow(dead_code)]
#[path = "../../cmux-rd-ffi/src/input.rs"]
mod input;
#[path = "remote_stream_rd/link.rs"]
mod rd_link;
#[allow(dead_code)]
#[path = "../../cmux-rd-ffi/src/receiver.rs"]
mod receiver;

#[derive(Clone)]
struct Args {
    path: String,
    keyframe_bytes: usize,
    frame_bytes: usize,
    fps: u32,
    seconds: u64,
    bulk_bytes: usize,
    /// Added round trip and loss on the WireGuard paths' UDP (see [`impair`]).
    rtt_ms: u64,
    loss_pct: f64,
    /// `--paths`: (kind, round trip ms) per viewer path.
    paths: Vec<(PathKind, u64)>,
    /// `--drop-at S:I`: cut path I S seconds into the stream.
    drop_at: Option<(u64, usize)>,
    /// `--role host|viewer` for a two-host run; empty: one process.
    role: String,
    listen: Option<SocketAddr>,
    /// `--peer LABEL=ADDR`, the viewer's paths in a two-host run.
    peers: Vec<(String, SocketAddr)>,
    seed: u64,
    /// `--rd-frames-in-flight`: the rd engine's frames in flight (0: the
    /// link host's rule).
    rd_frames_in_flight: u32,
    /// `--rd-deadline-ms`: how long the rd viewer waits for a frame's shards.
    rd_deadline_ms: u64,
}

fn args() -> Args {
    args_from(std::env::args().skip(1))
}

fn args_from(flags: impl IntoIterator<Item = String>) -> Args {
    let mut parsed = Args {
        path: "tcp".into(),
        keyframe_bytes: 200_000,
        frame_bytes: 3_500,
        fps: 60,
        seconds: 10,
        bulk_bytes: 16 << 20,
        rtt_ms: 0,
        loss_pct: 0.0,
        paths: Vec::new(),
        drop_at: None,
        role: String::new(),
        listen: None,
        peers: Vec::new(),
        seed: 1,
        rd_frames_in_flight: 0,
        rd_deadline_ms: 200,
    };
    let mut iter = flags.into_iter();
    while let Some(flag) = iter.next() {
        let value = iter.next().unwrap_or_default();
        let number = || value.parse::<u64>().unwrap_or(0);
        match flag.as_str() {
            "--path" => parsed.path = value.clone(),
            "--keyframe-bytes" => parsed.keyframe_bytes = number() as usize,
            "--frame-bytes" => parsed.frame_bytes = number() as usize,
            "--fps" => parsed.fps = number() as u32,
            "--seconds" => parsed.seconds = number(),
            "--bulk-bytes" => parsed.bulk_bytes = number() as usize,
            "--rtt-ms" => parsed.rtt_ms = number(),
            "--loss-pct" => parsed.loss_pct = value.parse().unwrap_or(0.0),
            "--paths" => parsed.paths = value.split(',').filter_map(parse_path).collect(),
            "--drop-at" => {
                parsed.drop_at = value
                    .split_once(':')
                    .and_then(|(at, index)| Some((at.parse().ok()?, index.parse().ok()?)));
            }
            "--role" => parsed.role = value.clone(),
            "--listen" => parsed.listen = value.parse().ok(),
            "--peer" => {
                if let Some((label, address)) = value.split_once('=')
                    && let Ok(address) = address.parse()
                {
                    parsed.peers.push((label.to_owned(), address));
                }
            }
            "--seed" => parsed.seed = number(),
            "--rd-frames-in-flight" => parsed.rd_frames_in_flight = number() as u32,
            "--rd-deadline-ms" => parsed.rd_deadline_ms = number(),
            other => eprintln!("ignoring unknown flag {other}"),
        }
    }
    parsed
}

/// `lan:1` -> (DirectLan, 1).
fn parse_path(text: &str) -> Option<(PathKind, u64)> {
    let (kind, rtt) = text.split_once(':')?;
    let kind = match kind {
        "lan" => PathKind::DirectLan,
        "wan" => PathKind::DirectWan,
        "region" => PathKind::ViaCloudRegion,
        "relay" => PathKind::DoRelay,
        _ => return None,
    };
    Some((kind, rtt.parse().ok()?))
}

/// What the viewer and host recorded, in microseconds.
#[derive(Default)]
struct Record {
    first_frame_us: Option<u64>,
    frame_us: Vec<u64>,
    input_us: Vec<u64>,
    photon_us: Vec<u64>,
    frames_sent: u64,
    inputs_sent: u64,
    late: u64,
    bulk_mbit_s: Option<f64>,
    note: String,
    /// When the viewer last received a frame, and the longest gap between two.
    last_frame_at_us: Option<u64>,
    longest_frame_gap_us: u64,
    /// The label of the path that carried the stream at its end.
    final_path: Option<String>,
}

type Shared = Arc<Mutex<Record>>;

fn lock(record: &Shared) -> std::sync::MutexGuard<'_, Record> {
    record.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Clock(Instant);

impl Clock {
    fn us(&self) -> u64 {
        u64::try_from(self.0.elapsed().as_micros()).unwrap_or(u64::MAX)
    }
}

/// The tick after `next` that is not already past: a stalled sender skips
/// the frames it missed, as an encoder does, instead of sending a burst.
fn next_tick(next: Instant, interval: Duration) -> Instant {
    let mut next = next + interval;
    let now = Instant::now();
    if next < now {
        let missed = (now - next).as_nanos() / interval.as_nanos().max(1);
        next += interval * u32::try_from(missed + 1).unwrap_or(u32::MAX);
    }
    next
}

fn header(kind: u8, seq: u32, sent_us: u64, echo_us: u64) -> [u8; HEADER] {
    let mut out = [0u8; HEADER];
    out[0] = kind;
    out[1..5].copy_from_slice(&seq.to_be_bytes());
    out[5..13].copy_from_slice(&sent_us.to_be_bytes());
    out[13..21].copy_from_slice(&echo_us.to_be_bytes());
    out
}

/// A message shorter than a header reads as kind 0 with zeros.
fn parse_header(bytes: &[u8]) -> (u8, u32, u64, u64) {
    let Some(bytes) = bytes.get(..HEADER) else { return (0, 0, 0, 0) };
    let word = |range: std::ops::Range<usize>| {
        let mut buf = [0u8; 8];
        buf.copy_from_slice(&bytes[range]);
        u64::from_be_bytes(buf)
    };
    let mut seq = [0u8; 4];
    seq.copy_from_slice(&bytes[1..5]);
    (bytes[0], u32::from_be_bytes(seq), word(5..13), word(13..21))
}

/// Host and viewer over one ordered byte stream, framed as length + header +
/// payload; input travels on the same stream, as RFB and the rd stream
/// carrier send it.
async fn stream_session<H, V>(host: H, viewer: V, args: &Args, clock: Arc<Clock>, record: Shared)
where
    H: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    V: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let end = Instant::now() + Duration::from_secs(args.seconds);
    let host = host_half(host, args, clock.clone(), record.clone(), end);
    let viewer = viewer_half(viewer, args, clock, record, end);
    tokio::join!(host, viewer);
}

/// The host's end: frames at the target rate, each stamped with the input it
/// answers. Returns once the frames are sent and the stream closed.
async fn host_half<H>(host: H, args: &Args, clock: Arc<Clock>, record: Shared, end: Instant)
where
    H: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut host_rx, mut host_tx) = tokio::io::split(host);
    let pending_echo = Arc::new(Mutex::new(0u64));
    let host_reader = {
        let (clock, record, pending) = (clock.clone(), record.clone(), pending_echo.clone());
        tokio::spawn(async move {
            let mut buf = [0u8; 4 + HEADER];
            while host_rx.read_exact(&mut buf).await.is_ok() {
                let (_, _, sent, _) = parse_header(&buf[4..]);
                lock(&record).input_us.push(clock.us().saturating_sub(sent));
                let mut slot = pending.lock().unwrap_or_else(PoisonError::into_inner);
                if *slot == 0 {
                    *slot = sent;
                }
            }
        })
    };
    let host_writer = {
        let (clock, record, pending) = (clock.clone(), record.clone(), pending_echo.clone());
        let args = args.clone();
        tokio::spawn(async move {
            let interval = Duration::from_secs(1) / args.fps.max(1);
            let mut next = Instant::now();
            let mut seq = 0u32;
            while next < end {
                let size = if seq == 0 { args.keyframe_bytes } else { args.frame_bytes };
                let echo =
                    std::mem::take(&mut *pending.lock().unwrap_or_else(PoisonError::into_inner));
                let mut frame = Vec::with_capacity(4 + HEADER + size);
                frame.extend_from_slice(&u32::try_from(HEADER + size).unwrap_or(0).to_be_bytes());
                frame.extend_from_slice(&header(KIND_FRAME, seq, clock.us(), echo));
                frame.resize(4 + HEADER + size, 0x5a);
                if host_tx.write_all(&frame).await.is_err() {
                    break;
                }
                lock(&record).frames_sent += 1;
                seq += 1;
                next = next_tick(next, interval);
                sleep_until(next).await;
            }
            let _ = host_tx.shutdown().await;
        })
    };
    let host_writer_abort = host_writer.abort_handle();
    let drain = Duration::from_secs(args.seconds + 30);
    let _ = timeout(drain, host_writer).await;
    host_writer_abort.abort();
    host_reader.abort();
}

/// The viewer's end: an input every 20 ms, and every frame timed on arrival.
async fn viewer_half<V>(viewer: V, args: &Args, clock: Arc<Clock>, record: Shared, end: Instant)
where
    V: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut viewer_rx, mut viewer_tx) = tokio::io::split(viewer);
    let viewer_writer = {
        let (clock, record) = (clock.clone(), record.clone());
        tokio::spawn(async move {
            let mut seq = 0u32;
            let mut next = Instant::now() + INPUT_INTERVAL;
            while next < end {
                sleep_until(next).await;
                let mut event = Vec::with_capacity(4 + HEADER);
                event.extend_from_slice(&u32::try_from(HEADER).unwrap_or(0).to_be_bytes());
                event.extend_from_slice(&header(KIND_INPUT, seq, clock.us(), 0));
                if viewer_tx.write_all(&event).await.is_err() {
                    break;
                }
                lock(&record).inputs_sent += 1;
                seq += 1;
                next = next_tick(next, INPUT_INTERVAL);
            }
            viewer_tx
        })
    };
    let max_message = HEADER + args.keyframe_bytes.max(args.frame_bytes);
    let viewer_reader = {
        let (clock, record) = (clock.clone(), record.clone());
        tokio::spawn(async move {
            let mut len = [0u8; 4];
            let mut body = Vec::new();
            while viewer_rx.read_exact(&mut len).await.is_ok() {
                let len = u32::from_be_bytes(len) as usize;
                if !(HEADER..=max_message).contains(&len) {
                    break;
                }
                body.resize(len, 0);
                if viewer_rx.read_exact(&mut body).await.is_err() {
                    break;
                }
                let now = clock.us();
                let (_, seq, sent, echo) = parse_header(&body);
                let mut record = lock(&record);
                if let Some(last) = record.last_frame_at_us {
                    record.longest_frame_gap_us = record.longest_frame_gap_us.max(now - last);
                }
                record.last_frame_at_us = Some(now);
                if seq == 0 {
                    record.first_frame_us = Some(now);
                } else {
                    record.frame_us.push(now.saturating_sub(sent));
                    if now.saturating_sub(sent) > LATE.as_micros() as u64 {
                        record.late += 1;
                    }
                }
                if echo != 0 {
                    record.photon_us.push(now.saturating_sub(echo));
                }
            }
        })
    };
    let viewer_reader_abort = viewer_reader.abort_handle();
    let drain = Duration::from_secs(args.seconds + 30);
    let _ = timeout(drain, viewer_reader).await;
    // A run that did not drain in time leaves nothing behind for the bulk run.
    viewer_reader_abort.abort();
    let viewer_writer_abort = viewer_writer.abort_handle();
    if let Ok(Ok(mut tx)) = timeout(Duration::from_secs(5), viewer_writer).await {
        let _ = tx.shutdown().await;
    }
    viewer_writer_abort.abort();
}

/// Mbit/s from host to viewer on a fresh stream, over `bytes` or 60 s.
async fn bulk<H, V>(mut host: H, mut viewer: V, bytes: usize) -> Option<f64>
where
    H: AsyncWrite + Unpin + Send + 'static,
    V: AsyncRead + Unpin,
{
    let started = Instant::now();
    let writer = tokio::spawn(async move {
        let chunk = vec![0xa5u8; 64 * 1024];
        let mut left = bytes;
        while left > 0 {
            let n = left.min(chunk.len());
            host.write_all(&chunk[..n]).await?;
            left -= n;
        }
        host.shutdown().await
    });
    let mut buf = vec![0u8; 64 * 1024];
    let mut got = 0usize;
    let read = timeout(Duration::from_secs(60), async {
        while got < bytes {
            match viewer.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => got += n,
            }
        }
    })
    .await;
    writer.abort();
    // A transfer still going at the limit reports what arrived by then.
    let _ = read;
    (got > 0).then(|| (got as f64 * 8.0) / started.elapsed().as_secs_f64() / 1e6)
}

async fn run_tcp(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let target = listener.local_addr()?;
    let (viewer, accepted) = tokio::join!(TcpStream::connect(target), listener.accept());
    let (viewer, (host, _)) = (viewer?, accepted?);
    viewer.set_nodelay(true)?;
    host.set_nodelay(true)?;
    stream_session(host, viewer, args, clock, record.clone()).await;
    let (viewer, accepted) = tokio::join!(TcpStream::connect(target), listener.accept());
    let (viewer, (host, _)) = (viewer?, accepted?);
    lock(&record).bulk_mbit_s = bulk(host, viewer, args.bulk_bytes).await;
    Ok(())
}

/// A tiny xorshift generator, so loss needs no dependency.
struct Rng(u64);

impl Rng {
    fn chance(&mut self, pct: f64) -> bool {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 % 1_000_000) as f64 / 10_000.0 < pct
    }
}

/// Forward datagrams from `from` to wherever `to` says, each after a fixed
/// delay and each lost with probability `loss_pct`. The delay line is FIFO,
/// so the link never reorders, like netem with a fixed delay.
/// How one direction of a link misbehaves.
struct Shape {
    delay: Duration,
    loss_pct: f64,
    seed: u64,
    /// Drop everything while set (a pulled cable).
    cut: Arc<AtomicBool>,
}

fn impair_direction(
    from: Arc<UdpSocket>,
    out: Arc<UdpSocket>,
    to: Arc<Mutex<Option<SocketAddr>>>,
    learn: Option<Arc<Mutex<Option<SocketAddr>>>>,
    shape: Shape,
) {
    let Shape { delay, loss_pct, seed, cut } = shape;
    let (line_tx, mut line_rx) = tokio::sync::mpsc::unbounded_channel::<(Instant, Vec<u8>)>();
    tokio::spawn(async move {
        let mut rng = Rng(seed);
        let mut buf = vec![0u8; 65_535];
        while let Ok((n, source)) = from.recv_from(&mut buf).await {
            if let Some(learn) = &learn {
                *learn.lock().unwrap_or_else(PoisonError::into_inner) = Some(source);
            }
            if !cut.load(Ordering::Relaxed)
                && !rng.chance(loss_pct)
                && line_tx.send((Instant::now() + delay, buf[..n].to_vec())).is_err()
            {
                break;
            }
        }
    });
    tokio::spawn(async move {
        while let Some((due, datagram)) = line_rx.recv().await {
            sleep_until(due).await;
            let target = *to.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(target) = target {
                let _ = out.send_to(&datagram, target).await;
            }
        }
    });
}

/// A lossy, delayed UDP link between a WireGuard client and `server`. The
/// client dials the returned address; half the round trip is added each way.
/// The tasks end with the process.
async fn impair(server: SocketAddr, rtt_ms: u64, loss_pct: f64) -> io::Result<SocketAddr> {
    impair_cuttable(server, rtt_ms, loss_pct, Arc::default()).await
}

/// [`impair`] that drops everything, both ways, while `cut` is set.
async fn impair_cuttable(
    server: SocketAddr,
    rtt_ms: u64,
    loss_pct: f64,
    cut: Arc<AtomicBool>,
) -> io::Result<SocketAddr> {
    let front = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
    let back = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
    let address = front.local_addr()?;
    let delay = Duration::from_micros(rtt_ms * 500);
    let client = Arc::new(Mutex::new(None));
    let server = Arc::new(Mutex::new(Some(server)));
    impair_direction(
        front.clone(),
        back.clone(),
        server,
        Some(client.clone()),
        Shape { delay, loss_pct, seed: 0x9e37_79b9_7f4a_7c15, cut: cut.clone() },
    );
    let shape = Shape { delay, loss_pct, seed: 0xd1b5_4a32_d192_ed03, cut };
    impair_direction(back, front, client, None, shape);
    Ok(address)
}

async fn start_wg(args: &Args) -> io::Result<(WgNet, WgNet, SocketAddr, SocketAddr)> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let server_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let client_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let server_addr = server_socket.local_addr()?;
    let shaped = args.rtt_ms > 0 || args.loss_pct > 0.0;
    let dial =
        if shaped { impair(server_addr, args.rtt_ms, args.loss_pct).await? } else { server_addr };
    let pair = config_pair(dial);
    let viewer = WgNet::start(pair.client, client_socket).await.map_err(err)?;
    // `CMUX_WG_ULTRA_HOST` starts the host in its own mode (`off`: only the
    // viewer turned ultra mode on, as with an app setting).
    let host = match std::env::var("CMUX_WG_ULTRA_HOST")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .and_then(|v| cmux_wg::UltraChoice::parse(&v))
    {
        Some(choice) => {
            WgNet::start_with_choice(pair.server, SocketPath::new(server_socket, None), choice)
                .map_err(err)?
        }
        None => WgNet::start(pair.server, server_socket).await.map_err(err)?,
    };
    Ok((
        viewer,
        host,
        SocketAddr::new(pair.client_v4, MEDIA_PORT),
        SocketAddr::new(pair.server_v4, STREAM_PORT),
    ))
}

/// The viewer's multipath underlay over one in-process link per `--paths`
/// entry, all to the host's one socket. Returns the cut switch of each link.
async fn start_wg_paths(
    args: &Args,
) -> io::Result<(WgNet, WgNet, SocketAddr, MultipathControl, Vec<Arc<AtomicBool>>)> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let server_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let server_addr = server_socket.local_addr()?;
    let pair = config_pair(server_addr);
    let (underlay, control) =
        Multipath::with_probes(cmux_transport::SelectorConfig::default(), ProbeConfig::default());
    let mut cuts = Vec::new();
    for (kind, rtt_ms) in &args.paths {
        let cut = Arc::new(AtomicBool::new(false));
        let front = impair_cuttable(server_addr, *rtt_ms, args.loss_pct, cut.clone()).await?;
        let socket = UdpSocket::bind("127.0.0.1:0").await?;
        control.add_path(*kind, SocketPath::new(socket, Some(front)));
        cuts.push(cut);
    }
    let viewer = WgNet::start_with_underlay(pair.client, underlay).map_err(err)?;
    let host = WgNet::start(pair.server, server_socket).await.map_err(err)?;
    Ok((viewer, host, SocketAddr::new(pair.server_v4, STREAM_PORT), control, cuts))
}

/// The label of the path carrying the session now (`--paths` index or
/// `--peer` label), or `every` while datagrams go on every path.
fn path_label(control: &MultipathControl, labels: &[(PathId, String)]) -> String {
    let current = control.current();
    labels
        .iter()
        .find(|(id, _)| Some(*id) == current)
        .map_or_else(|| "every".to_owned(), |(_, label)| label.clone())
}

async fn run_wg_paths(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let (viewer_net, host_net, target, control, cuts) = start_wg_paths(args).await?;
    let labels: Vec<(PathId, String)> = control
        .paths()
        .iter()
        .enumerate()
        .map(|(index, path)| (path.view.id, index.to_string()))
        .collect();
    if let Some((at, index)) = args.drop_at
        && let Some(cut) = cuts.get(index).cloned()
    {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(at)).await;
            cut.store(true, Ordering::Relaxed);
        });
    }
    let mut listener = host_net.listen(STREAM_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(target).await.map_err(err)?;
    let host = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    stream_session(host, viewer, args, clock, record.clone()).await;
    lock(&record).final_path = Some(path_label(&control, &labels));
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    // Bulk on a fresh tunnel over the same path set, nothing cut.
    let (viewer_net, host_net, target, _control, _cuts) = start_wg_paths(args).await?;
    let mut listener = host_net.listen(BULK_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(SocketAddr::new(target.ip(), BULK_PORT)).await.map_err(err)?;
    let host = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    lock(&record).bulk_mbit_s = bulk(host, viewer, args.bulk_bytes).await;
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    Ok(())
}

/// One key pair per role from `seed`, so two hosts agree on keys with no
/// exchange. Bench only: anyone who knows the seed can join.
fn seeded_pair(seed: u64, server: SocketAddr) -> cmux_wg::testing::ConfigPair {
    let mut pair = config_pair(server);
    let secret = |role: u8| {
        let mut bytes = [0u8; 32];
        bytes[..8].copy_from_slice(&seed.to_le_bytes());
        bytes[8] = role;
        x25519_dalek::StaticSecret::from(bytes)
    };
    let (client, host) = (secret(1), secret(2));
    pair.client.private_key = zeroize::Zeroizing::new(client.to_bytes());
    pair.server.private_key = zeroize::Zeroizing::new(host.to_bytes());
    pair.client.peer_public_key = x25519_dalek::PublicKey::from(&host).to_bytes();
    pair.server.peer_public_key = x25519_dalek::PublicKey::from(&client).to_bytes();
    pair
}

/// The host end of a two-host run: one UDP socket, the stream, then bulk.
async fn run_remote_host(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let listen = args.listen.ok_or_else(|| io::Error::other("--role host needs --listen"))?;
    let socket = UdpSocket::bind(listen).await?;
    let pair = seeded_pair(args.seed, listen);
    let net = WgNet::start(pair.server, socket).await.map_err(err)?;
    let mut stream = net.listen(STREAM_PORT).await.map_err(err)?;
    let mut bulk_listener = net.listen(BULK_PORT).await.map_err(err)?;
    let host = stream.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    let end = Instant::now() + Duration::from_secs(args.seconds);
    host_half(host, args, clock, record, end).await;
    let mut host = bulk_listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    let chunk = vec![0xa5u8; 64 * 1024];
    let mut left = args.bulk_bytes;
    while left > 0 {
        let n = left.min(chunk.len());
        host.write_all(&chunk[..n]).await?;
        left -= n;
    }
    host.shutdown().await?;
    // Let the last segments drain before the tunnel goes.
    tokio::time::sleep(Duration::from_secs(2)).await;
    net.shutdown().await;
    Ok(())
}

/// A viewer socket `--drop-at` can cut: once cut, it drops what it would send
/// and discards what arrives, as a pulled cable does to both directions, with
/// no change to the machine's interfaces.
struct CutSocket {
    socket: UdpSocket,
    cut: Arc<AtomicBool>,
}

impl cmux_wg::DatagramSocket for CutSocket {
    fn poll_recv_from(
        &mut self,
        cx: &mut std::task::Context<'_>,
        buffer: &mut [u8],
    ) -> std::task::Poll<io::Result<(usize, SocketAddr)>> {
        loop {
            let ready = cmux_wg::DatagramSocket::poll_recv_from(&mut self.socket, cx, buffer);
            if !self.cut.load(Ordering::Relaxed) || !matches!(ready, std::task::Poll::Ready(Ok(_)))
            {
                return ready;
            }
        }
    }

    fn poll_send_ready(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        cmux_wg::DatagramSocket::poll_send_ready(&mut self.socket, cx)
    }

    fn try_send_to(&mut self, datagram: &[u8], target: SocketAddr) -> io::Result<usize> {
        if self.cut.load(Ordering::Relaxed) {
            return Ok(datagram.len());
        }
        cmux_wg::DatagramSocket::try_send_to(&mut self.socket, datagram, target)
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.socket.local_addr()
    }

    fn grow_receive_buffer(&self) {
        cmux_wg::DatagramSocket::grow_receive_buffer(&self.socket);
    }
}

/// The viewer end of a two-host run: a path per `--peer`, chosen by the
/// selector.
async fn run_remote_viewer(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let first = args.peers.first().ok_or_else(|| io::Error::other("--role viewer needs --peer"))?;
    let pair = seeded_pair(args.seed, first.1);
    // A cut needs another path to move to: with the cut path alone, the
    // bulk phase after the stream would only wait out its timeout.
    if let Some((_, index)) = args.drop_at
        && (index >= args.peers.len() || args.peers.len() < 2)
    {
        return Err(io::Error::other(
            "--drop-at S:I needs a --peer at index I and at least one other --peer",
        ));
    }
    let (underlay, control) =
        Multipath::with_probes(cmux_transport::SelectorConfig::default(), ProbeConfig::default());
    let mut labels = Vec::new();
    let mut cut = None;
    for (index, (label, address)) in args.peers.iter().enumerate() {
        let bind = if address.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
        let socket = CutSocket { socket: UdpSocket::bind(bind).await?, cut: Arc::default() };
        if args.drop_at.is_some_and(|(_, cut_index)| cut_index == index) {
            cut = Some(socket.cut.clone());
        }
        let kind = if label.starts_with("lan") || label.starts_with("tb") {
            PathKind::DirectLan
        } else {
            PathKind::DirectWan
        };
        labels
            .push((control.add_path(kind, SocketPath::new(socket, Some(*address))), label.clone()));
    }
    let net = WgNet::start_with_underlay(pair.client, underlay).map_err(err)?;
    let target = SocketAddr::new(pair.server_v4, STREAM_PORT);
    let viewer = net.connect(target).await.map_err(err)?;
    // The cut's clock starts with the stream, not with the process: across
    // two hosts the handshake and connect take a varying part of a second.
    if let (Some((at, _)), Some(cut)) = (args.drop_at, cut) {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(at)).await;
            cut.store(true, Ordering::Relaxed);
        });
    }
    let end = Instant::now() + Duration::from_secs(args.seconds);
    viewer_half(viewer, args, clock, record.clone(), end).await;
    lock(&record).final_path = Some(path_label(&control, &labels));
    let host_stub = net.connect(SocketAddr::new(pair.server_v4, BULK_PORT)).await.map_err(err)?;
    let started = Instant::now();
    let mut viewer = host_stub;
    let mut buf = vec![0u8; 64 * 1024];
    let mut got = 0usize;
    let _ = timeout(Duration::from_secs(60), async {
        while got < args.bulk_bytes {
            match viewer.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => got += n,
            }
        }
    })
    .await;
    lock(&record).bulk_mbit_s =
        (got > 0).then(|| (got as f64 * 8.0) / started.elapsed().as_secs_f64() / 1e6);
    net.shutdown().await;
    Ok(())
}

async fn run_wg_tcp(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    if !args.paths.is_empty() {
        return run_wg_paths(args, clock, record).await;
    }
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let (viewer_net, host_net, _, target) = start_wg(args).await?;
    let mut listener = host_net.listen(STREAM_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(target).await.map_err(err)?;
    let host = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    stream_session(host, viewer, args, clock, record.clone()).await;
    lock(&record).note = ultra_note(&viewer_net, &host_net);
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    if args.bulk_bytes == 0 {
        return Ok(());
    }
    // A fresh tunnel, so frames still queued from the stream cannot share it.
    let (viewer_net, host_net, _, target) = start_wg(args).await?;
    let mut listener = host_net.listen(BULK_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(SocketAddr::new(target.ip(), BULK_PORT)).await.map_err(err)?;
    let host = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    lock(&record).bulk_mbit_s = bulk(host, viewer, args.bulk_bytes).await;
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    Ok(())
}

/// Frames cut into media datagrams, input as interactive datagrams; nothing
/// is retransmitted, so a frame missing one piece never completes.
async fn run_wg_dgram(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let (viewer_net, host_net, viewer_addr, host_stream) = start_wg(args).await?;
    let host_addr = SocketAddr::new(host_stream.ip(), MEDIA_PORT);
    let mut viewer = viewer_net.bind_datagram(MEDIA_PORT).await.map_err(err)?;
    let mut host = host_net.bind_datagram(MEDIA_PORT).await.map_err(err)?;
    let chunk = viewer_net.max_datagram().saturating_sub(HEADER + 8).max(64);
    let end = Instant::now() + Duration::from_secs(args.seconds);
    let pending_echo = Arc::new(Mutex::new(0u64));

    let host_task = {
        let (clock, record, pending, args) =
            (clock.clone(), record.clone(), pending_echo.clone(), args.clone());
        tokio::spawn(async move {
            // The stream starts on the viewer's first input, as a viewer's
            // request starts one; before the handshake a datagram is lost.
            // With no input by the end of the run (100 % loss, no handshake),
            // the host sends nothing and the run still ends.
            if !matches!(timeout_at(end, host.recv_from()).await, Ok(Some(_))) {
                return;
            }
            let interval = Duration::from_secs(1) / args.fps.max(1);
            let mut next = Instant::now();
            let mut seq = 0u32;
            while next < end {
                let size = if seq == 0 { args.keyframe_bytes } else { args.frame_bytes };
                let echo =
                    std::mem::take(&mut *pending.lock().unwrap_or_else(PoisonError::into_inner));
                let pieces = size.div_ceil(chunk).max(1);
                let sent = clock.us();
                for index in 0..pieces {
                    let mut datagram = header(KIND_FRAME, seq, sent, echo).to_vec();
                    datagram.extend_from_slice(&u32::try_from(index).unwrap_or(0).to_be_bytes());
                    datagram.extend_from_slice(&u32::try_from(pieces).unwrap_or(0).to_be_bytes());
                    let piece = chunk.min(size.saturating_sub(index * chunk));
                    datagram.resize(HEADER + 8 + piece, 0x5a);
                    let _ = host.send_to(&datagram, viewer_addr, Priority::Media).await;
                }
                lock(&record).frames_sent += 1;
                seq += 1;
                next = next_tick(next, interval);
                tokio::select! {
                    () = sleep_until(next) => {}
                    Some((input, _)) = host.recv_from() => {
                        let (_, _, sent, _) = parse_header(&input);
                        lock(&record).input_us.push(clock.us().saturating_sub(sent));
                        {
                            let mut slot = pending.lock().unwrap_or_else(PoisonError::into_inner);
                            if *slot == 0 {
                                *slot = sent;
                            }
                        }
                        sleep_until(next).await;
                    }
                }
            }
        })
    };
    let viewer_task = {
        let (clock, record) = (clock.clone(), record.clone());
        tokio::spawn(async move {
            let mut partial: HashMap<u32, u32> = HashMap::new();
            let mut next_input = Instant::now() + INPUT_INTERVAL;
            let mut input_seq = 0u32;
            let stop = end + Duration::from_secs(1);
            loop {
                tokio::select! {
                    () = sleep_until(next_input), if next_input < end => {
                        let event = header(KIND_INPUT, input_seq, clock.us(), 0);
                        let _ = viewer.send_to(&event, host_addr, Priority::Interactive).await;
                        lock(&record).inputs_sent += 1;
                        input_seq += 1;
                        next_input = next_tick(next_input, INPUT_INTERVAL);
                    }
                    () = sleep_until(stop) => break,
                    got = viewer.recv_from() => {
                        let Some((datagram, _)) = got else { break };
                        let now = clock.us();
                        let Some(count) = datagram.get(HEADER + 4..HEADER + 8) else { continue };
                        let pieces = u32::from_be_bytes([count[0], count[1], count[2], count[3]]);
                        let (_, seq, sent, echo) = parse_header(&datagram);
                        let have = partial.entry(seq).or_insert(0);
                        *have += 1;
                        if *have == pieces {
                            let mut record = lock(&record);
                            if seq == 0 {
                                record.first_frame_us = Some(now);
                            } else {
                                record.frame_us.push(now.saturating_sub(sent));
                                if now.saturating_sub(sent) > LATE.as_micros() as u64 {
                                    record.late += 1;
                                }
                            }
                            if echo != 0 {
                                record.photon_us.push(now.saturating_sub(echo));
                            }
                        }
                    }
                }
            }
        })
    };
    let _ = tokio::join!(host_task, viewer_task);
    let drops = host_net.datagram_drops();
    lock(&record).note = format!(
        "no retransmit; sender drops stale {} full {}; {}",
        drops.media_stale,
        drops.media_full,
        ultra_note(&viewer_net, &host_net)
    );
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    Ok(())
}

/// What ultra mode (`CMUX_WG_ULTRA`) sent and rebuilt on each end of the
/// stream run.
fn ultra_note(viewer: &WgNet, host: &WgNet) -> String {
    let (viewer, host) = (viewer.ultra_stats(), host.ultra_stats());
    format!(
        "ultra {}: host parity {} copies {} overhead {} B of {} B rebuilt {} auto-on {}, viewer parity {} copies {} overhead {} B of {} B rebuilt {} auto-on {}",
        std::env::var("CMUX_WG_ULTRA").unwrap_or_default(),
        host.parity_sent,
        host.copies_sent,
        host.overhead_bytes,
        host.data_bytes,
        host.recovered,
        host.auto_on,
        viewer.parity_sent,
        viewer.copies_sent,
        viewer.overhead_bytes,
        viewer.data_bytes,
        viewer.recovered,
        viewer.auto_on,
    )
}

fn percentiles(values: &mut [u64]) -> String {
    if values.is_empty() {
        return "null".into();
    }
    values.sort_unstable();
    let at = |p: f64| values[((values.len() as f64 - 1.0) * p).round() as usize] as f64 / 1000.0;
    format!(
        "{{\"n\":{},\"p50\":{:.2},\"p95\":{:.2},\"p99\":{:.2},\"max\":{:.2}}}",
        values.len(),
        at(0.5),
        at(0.95),
        at(0.99),
        at(1.0)
    )
}

fn json_number(value: Option<f64>) -> String {
    value.map_or_else(|| "null".into(), |value| format!("{value:.2}"))
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let args = args();
    let clock = Arc::new(Clock(Instant::now()));
    let record: Shared = Arc::default();
    match (args.role.as_str(), args.path.as_str()) {
        ("host", _) => return run_remote_host(&args, clock, record.clone()).await,
        ("viewer", _) => run_remote_viewer(&args, clock, record.clone()).await?,
        (_, path) => run_one_process(&args, path, clock, record.clone()).await?,
    }
    print_record(&args, &record);
    Ok(())
}

/// One overlay address of a bench mesh end.
fn mesh_address(last: u16) -> cmux_wg::InterfaceAddress {
    cmux_wg::InterfaceAddress {
        address: IpAddr::V6(Ipv6Addr::new(0xfd7c, 0x6d78, 0, 0, 0, 0, 0, last)),
        prefix: 128,
    }
}

fn mesh_end(socket: UdpSocket, private: [u8; 32], last: u16) -> io::Result<cmux_wg::WgMesh> {
    let config = cmux_wg::WgMeshConfig {
        private_key: zeroize::Zeroizing::new(private),
        addresses: vec![mesh_address(last)],
        mtu: cmux_wg::DEFAULT_MTU,
    };
    cmux_wg::WgMesh::start(config, socket).map_err(|error| io::Error::other(error.to_string()))
}

/// Two mesh ends: the host on one loopback socket behind one in-process
/// link per `--paths` entry, and the viewer, whose host peer has a
/// candidate per link. Returns the cut switch of each link.
async fn start_wg_mesh(
    args: &Args,
) -> io::Result<(cmux_wg::WgMesh, cmux_wg::WgMesh, SocketAddr, Vec<Arc<AtomicBool>>)> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let host_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let host_udp = host_socket.local_addr()?;
    let (host_private, host_public) = random_keypair();
    let (viewer_private, viewer_public) = random_keypair();
    let host = mesh_end(host_socket, host_private, 2)?;
    let viewer = mesh_end(UdpSocket::bind("127.0.0.1:0").await?, viewer_private, 1)?;
    let mut cuts = Vec::new();
    let mut fronts = Vec::new();
    for (kind, rtt_ms) in &args.paths {
        let cut = Arc::new(AtomicBool::new(false));
        fronts.push((*kind, impair_cuttable(host_udp, *rtt_ms, args.loss_pct, cut.clone()).await?));
        cuts.push(cut);
    }
    let first =
        fronts.first().map(|(_, front)| *front).ok_or_else(|| io::Error::other("--paths"))?;
    // bench: candidates begin
    let candidates = fronts
        .iter()
        .map(|(kind, address)| cmux_wg::PeerCandidate { address: *address, kind: Some(*kind) })
        .collect();
    // bench: candidates end
    let host_network =
        cmux_wg::IpNetwork::new(mesh_address(2).address, 128).map_err(io::Error::other)?;
    let viewer_network =
        cmux_wg::IpNetwork::new(mesh_address(1).address, 128).map_err(io::Error::other)?;
    viewer
        .add_peer(cmux_wg::WgPeer {
            public_key: host_public,
            preshared_key: None,
            allowed_ips: vec![host_network],
            route: Some(first.into()),
            candidates, // bench: candidates
            persistent_keepalive: None,
        })
        .await
        .map_err(err)?;
    host.add_peer(cmux_wg::WgPeer {
        public_key: viewer_public,
        preshared_key: None,
        allowed_ips: vec![viewer_network],
        route: None,
        candidates: Vec::new(), // bench: candidates
        persistent_keepalive: None,
    })
    .await
    .map_err(err)?;
    Ok((viewer, host, SocketAddr::new(mesh_address(2).address, STREAM_PORT), cuts))
}

/// `--path wg-mesh`: the `--paths` stream, cut and bulk runs through two
/// mesh ends.
async fn run_wg_mesh(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    if args.paths.is_empty() {
        return Err(io::Error::other("--path wg-mesh needs --paths"));
    }
    let (viewer_net, host_net, target, cuts) = start_wg_mesh(args).await?;
    if let Some((at, index)) = args.drop_at
        && let Some(cut) = cuts.get(index).cloned()
    {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(at)).await;
            cut.store(true, Ordering::Relaxed);
        });
    }
    let mut listener = host_net.listen(STREAM_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(target).await.map_err(err)?;
    let (host, _) = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    stream_session(host, viewer, args, clock, record.clone()).await;
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    // Bulk on a fresh pair over the same path set, nothing cut.
    let (viewer_net, host_net, target, _cuts) = start_wg_mesh(args).await?;
    let mut listener = host_net.listen(BULK_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(SocketAddr::new(target.ip(), BULK_PORT)).await.map_err(err)?;
    let (host, _) = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    lock(&record).bulk_mbit_s = bulk(host, viewer, args.bulk_bytes).await;
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    Ok(())
}

async fn run_one_process(
    args: &Args,
    path: &str,
    clock: Arc<Clock>,
    record: Shared,
) -> io::Result<()> {
    let args = args.clone();
    match path {
        "tcp" if args.rtt_ms > 0 || args.loss_pct > 0.0 => {
            return Err(io::Error::other("--rtt-ms and --loss-pct shape only the WireGuard paths"));
        }
        "tcp" => run_tcp(&args, clock, record.clone()).await?,
        "wg-tcp" => run_wg_tcp(&args, clock, record.clone()).await?,
        "wg-dgram" => run_wg_dgram(&args, clock, record.clone()).await?,
        "wg-mesh" => run_wg_mesh(&args, clock, record.clone()).await?,
        "rd-link" => rd_link::run(&args, clock, record.clone()).await?,
        other => return Err(io::Error::other(format!("unknown path {other}"))),
    }
    Ok(())
}

fn print_record(args: &Args, record: &Shared) {
    let mut record = lock(record);
    let received = record.frame_us.len() as u64 + u64::from(record.first_frame_us.is_some());
    let fps = received as f64 / args.seconds.max(1) as f64;
    let on_time = (received.saturating_sub(record.late)) as f64 / args.seconds.max(1) as f64;
    let note = std::mem::take(&mut record.note);
    let frame_ms = percentiles(&mut record.frame_us);
    let input_ms = percentiles(&mut record.input_us);
    let photon_ms = percentiles(&mut record.photon_us);
    println!(
        "{{\"path\":\"{}\",\"rtt_ms\":{},\"loss_pct\":{},\"frame_bytes\":{},\"fps_target\":{},\"seconds\":{},\
         \"first_frame_ms\":{},\"frames_sent\":{},\"frames_received\":{},\"fps\":{:.1},\
         \"fps_on_time\":{:.1},\"frame_ms\":{},\"inputs_sent\":{},\"input_ms\":{},\
         \"input_to_photon_ms\":{},\"bulk_mbit_s\":{},\"longest_frame_gap_ms\":{:.1},\
         \"final_path\":\"{}\",\"paths\":\"{}\",\"drop_at\":\"{}\",\"note\":\"{}\"}}",
        args.path,
        args.rtt_ms,
        args.loss_pct,
        args.frame_bytes,
        args.fps,
        args.seconds,
        json_number(record.first_frame_us.map(|us| us as f64 / 1000.0)),
        record.frames_sent,
        received,
        fps,
        on_time,
        frame_ms,
        record.inputs_sent,
        input_ms,
        photon_ms,
        json_number(record.bulk_mbit_s),
        record.longest_frame_gap_us as f64 / 1000.0,
        record.final_path.as_deref().unwrap_or(""),
        if args.peers.is_empty() {
            args.paths
                .iter()
                .map(|(kind, rtt)| format!("{}:{rtt}", kind.wire_name()))
                .collect::<Vec<_>>()
                .join(",")
        } else {
            args.peers
                .iter()
                .map(|(label, address)| format!("{label}={address}"))
                .collect::<Vec<_>>()
                .join(",")
        },
        args.drop_at.map(|(at, index)| format!("{at}:{index}")).unwrap_or_default(),
        note,
    );
}
