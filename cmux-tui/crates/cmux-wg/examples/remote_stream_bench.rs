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
//!   no FEC or retransmission (the floor an rd media path could reach).
//!
//! The link is whatever loopback is: `scripts/remote-stream-bench.sh` shapes
//! it with netem. Prints one JSON object.
//!
//! ```text
//! cargo run --release -p cmux-wg --example remote_stream_bench -- \
//!     --path wg-tcp --frame-bytes 3500 --fps 60 --seconds 10
//! ```

use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_wg::testing::loopback_pair;
use cmux_wg::{Priority, WgNet};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{Instant, sleep_until, timeout};

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

#[derive(Clone)]
struct Args {
    path: String,
    keyframe_bytes: usize,
    frame_bytes: usize,
    fps: u32,
    seconds: u64,
    bulk_bytes: usize,
}

fn args() -> Args {
    let mut parsed = Args {
        path: "tcp".into(),
        keyframe_bytes: 200_000,
        frame_bytes: 3_500,
        fps: 60,
        seconds: 10,
        bulk_bytes: 16 << 20,
    };
    let mut iter = std::env::args().skip(1);
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
            other => eprintln!("ignoring unknown flag {other}"),
        }
    }
    parsed
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

fn header(kind: u8, seq: u32, sent_us: u64, echo_us: u64) -> [u8; HEADER] {
    let mut out = [0u8; HEADER];
    out[0] = kind;
    out[1..5].copy_from_slice(&seq.to_be_bytes());
    out[5..13].copy_from_slice(&sent_us.to_be_bytes());
    out[13..21].copy_from_slice(&echo_us.to_be_bytes());
    out
}

fn parse_header(bytes: &[u8]) -> (u8, u32, u64, u64) {
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
    let (mut host_rx, mut host_tx) = tokio::io::split(host);
    let (mut viewer_rx, mut viewer_tx) = tokio::io::split(viewer);
    let pending_echo = Arc::new(Mutex::new(0u64));
    let end = Instant::now() + Duration::from_secs(args.seconds);

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
                let echo = std::mem::take(&mut *pending.lock().unwrap_or_else(PoisonError::into_inner));
                let mut frame = Vec::with_capacity(4 + HEADER + size);
                frame.extend_from_slice(&u32::try_from(HEADER + size).unwrap_or(0).to_be_bytes());
                frame.extend_from_slice(&header(KIND_FRAME, seq, clock.us(), echo));
                frame.resize(4 + HEADER + size, 0x5a);
                if host_tx.write_all(&frame).await.is_err() {
                    break;
                }
                lock(&record).frames_sent += 1;
                seq += 1;
                next += interval;
                sleep_until(next).await;
            }
            let _ = host_tx.shutdown().await;
        })
    };
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
                next += INPUT_INTERVAL;
            }
            viewer_tx
        })
    };
    let viewer_reader = {
        let (clock, record) = (clock.clone(), record.clone());
        tokio::spawn(async move {
            let mut len = [0u8; 4];
            let mut body = Vec::new();
            while viewer_rx.read_exact(&mut len).await.is_ok() {
                body.resize(u32::from_be_bytes(len) as usize, 0);
                if viewer_rx.read_exact(&mut body).await.is_err() {
                    break;
                }
                let now = clock.us();
                let (_, seq, sent, echo) = parse_header(&body);
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
        })
    };
    let drain = Duration::from_secs(args.seconds + 30);
    let _ = timeout(drain, async {
        let _ = host_writer.await;
        let _ = viewer_reader.await;
    })
    .await;
    if let Ok(Ok(mut tx)) = timeout(Duration::from_secs(5), viewer_writer).await {
        let _ = tx.shutdown().await;
    }
    host_reader.abort();
}

/// Time `bytes` from host to viewer on a fresh stream.
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
    let read = timeout(Duration::from_secs(120), async {
        while got < bytes {
            match viewer.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => got += n,
            }
        }
    })
    .await;
    writer.abort();
    (read.is_ok() && got == bytes)
        .then(|| (bytes as f64 * 8.0) / started.elapsed().as_secs_f64() / 1e6)
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

async fn start_wg() -> io::Result<(WgNet, WgNet, SocketAddr, SocketAddr)> {
    let pair = loopback_pair().await?;
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let viewer = WgNet::start(pair.client, pair.client_socket).await.map_err(err)?;
    let host = WgNet::start(pair.server, pair.server_socket).await.map_err(err)?;
    Ok((
        viewer,
        host,
        SocketAddr::new(pair.client_v4, MEDIA_PORT),
        SocketAddr::new(pair.server_v4, STREAM_PORT),
    ))
}

async fn run_wg_tcp(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let (viewer_net, host_net, _, target) = start_wg().await?;
    let mut listener = host_net.listen(STREAM_PORT).await.map_err(err)?;
    let mut bulk_listener = host_net.listen(BULK_PORT).await.map_err(err)?;
    let viewer = viewer_net.connect(target).await.map_err(err)?;
    let host = listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    stream_session(host, viewer, args, clock, record.clone()).await;
    let viewer = viewer_net.connect(SocketAddr::new(target.ip(), BULK_PORT)).await.map_err(err)?;
    let host = bulk_listener.accept().await.ok_or_else(|| io::Error::other("no accept"))?;
    lock(&record).bulk_mbit_s = bulk(host, viewer, args.bulk_bytes).await;
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    Ok(())
}

/// Frames cut into media datagrams, input as interactive datagrams; nothing
/// is retransmitted, so a frame missing one piece never completes.
async fn run_wg_dgram(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let err = |error: cmux_wg::WgError| io::Error::other(error.to_string());
    let (viewer_net, host_net, viewer_addr, host_stream) = start_wg().await?;
    let host_addr = SocketAddr::new(host_stream.ip(), MEDIA_PORT);
    let mut viewer = viewer_net.bind_datagram(MEDIA_PORT).await.map_err(err)?;
    let mut host = host_net.bind_datagram(MEDIA_PORT).await.map_err(err)?;
    let chunk = viewer_net.max_datagram().saturating_sub(HEADER + 4).max(64);
    let end = Instant::now() + Duration::from_secs(args.seconds);
    let pending_echo = Arc::new(Mutex::new(0u64));

    let host_task = {
        let (clock, record, pending, args) =
            (clock.clone(), record.clone(), pending_echo.clone(), args.clone());
        tokio::spawn(async move {
            let interval = Duration::from_secs(1) / args.fps.max(1);
            let mut next = Instant::now();
            let mut seq = 0u32;
            while next < end {
                let size = if seq == 0 { args.keyframe_bytes } else { args.frame_bytes };
                let echo = std::mem::take(&mut *pending.lock().unwrap_or_else(PoisonError::into_inner));
                let pieces = size.div_ceil(chunk).max(1);
                let sent = clock.us();
                for index in 0..pieces {
                    let mut datagram = header(KIND_FRAME, seq, sent, echo).to_vec();
                    datagram.extend_from_slice(&u16::try_from(index).unwrap_or(0).to_be_bytes());
                    datagram.extend_from_slice(&u16::try_from(pieces).unwrap_or(0).to_be_bytes());
                    let piece = chunk.min(size.saturating_sub(index * chunk));
                    datagram.resize(HEADER + 4 + piece, 0x5a);
                    let _ = host.send_to(&datagram, viewer_addr, Priority::Media).await;
                }
                lock(&record).frames_sent += 1;
                seq += 1;
                next += interval;
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
            let mut partial: HashMap<u32, u16> = HashMap::new();
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
                        next_input += INPUT_INTERVAL;
                    }
                    () = sleep_until(stop) => break,
                    got = viewer.recv_from() => {
                        let Some((datagram, _)) = got else { break };
                        let now = clock.us();
                        let (_, seq, sent, echo) = parse_header(&datagram);
                        let pieces = u16::from_be_bytes([datagram[HEADER + 2], datagram[HEADER + 3]]);
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
        "no FEC or retransmit; sender drops stale {} full {}",
        drops.media_stale, drops.media_full
    );
    viewer_net.shutdown().await;
    host_net.shutdown().await;
    Ok(())
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
    match args.path.as_str() {
        "tcp" => run_tcp(&args, clock, record.clone()).await?,
        "wg-tcp" => run_wg_tcp(&args, clock, record.clone()).await?,
        "wg-dgram" => run_wg_dgram(&args, clock, record.clone()).await?,
        other => return Err(io::Error::other(format!("unknown path {other}"))),
    }
    let mut record = lock(&record);
    let received = record.frame_us.len() as u64 + u64::from(record.first_frame_us.is_some());
    let fps = received as f64 / args.seconds.max(1) as f64;
    let on_time = (received.saturating_sub(record.late)) as f64 / args.seconds.max(1) as f64;
    let note = std::mem::take(&mut record.note);
    let frame_ms = percentiles(&mut record.frame_us);
    let input_ms = percentiles(&mut record.input_us);
    let photon_ms = percentiles(&mut record.photon_us);
    println!(
        "{{\"path\":\"{}\",\"frame_bytes\":{},\"fps_target\":{},\"seconds\":{},\
         \"first_frame_ms\":{},\"frames_sent\":{},\"frames_received\":{},\"fps\":{:.1},\
         \"fps_on_time\":{:.1},\"frame_ms\":{},\"inputs_sent\":{},\"input_ms\":{},\
         \"input_to_photon_ms\":{},\"bulk_mbit_s\":{},\"note\":\"{}\"}}",
        args.path,
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
        note,
    );
    Ok(())
}
