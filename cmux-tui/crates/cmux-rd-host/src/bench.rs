//! `cmux-rd bench`: a Linux viewer that measures glass-to-glass latency with the marker
//! method (remote-desktop.md section 15.1) over `cmux.rd/1`: key press sent at t0 ->
//! first decoded frame whose marker shows the expected counter. Uses the real
//! reassembler, FEC, feedback and input path of `cmux-rd-core`.
//!
//! `--upstream mic|camera|screen [--upstream-frames N]` first sends N
//! synthetic frames upstream (rd change C4) the way the viewer app does:
//! `stream_open`, then `UpMedia` through `cmux-rd-core`'s `UpstreamSender`
//! with the host's feedback, then `stream_close`. The report's `upstream`
//! names the frames sent and acknowledged and an FNV-1a hash of the sent
//! bytes, which a host started with `--upstream-record DIR` logs for the
//! frames it received.

use crate::args::Opts;
use crate::clock::{now_ns, Rng};
use crate::fdwait::wait_readable;
use crate::marker;
use crate::wire::{
    write_control, write_frame, Control, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use crate::Res;
use cmux_rd_core::cc::{CcConfig, PathKind};
use cmux_rd_core::input::InputSender;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_core::service::caps;
use cmux_rd_core::upstream::{UpstreamConfig, UpstreamSender};
use cmux_rd_proto::control::StreamKind;
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, Feedback, InputEvent, Nack, HEADER_LEN, MAX_ARRIVALS,
    MAX_DATAGRAM_VPC,
};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;
use serde_json::json;
use std::io;
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::os::fd::AsRawFd;

const KEY_A: u32 = 0x0007_0004;
/// The bench's upstream stream id (any id the host does not use for a display).
const UP_STREAM: u16 = 100;

struct Viewer {
    tcp: TcpStream,
    udp: Option<(UdpSocket, SocketAddr)>,
    reader: FrameReader,
    reassembler: Reassembler,
    decoder: Decoder,
    sender: InputSender,
    arrivals: Vec<Arrival>,
    marker: Option<u16>,
    marker_at_ns: u64,
    /// Host capture time (host monotonic us) of the frame that showed the marker.
    marker_capture_us: u64,
    frames: u64,
    bytes: u64,
    decode_ms: Vec<f64>,
    decode_errors: u64,
    last_feedback_ns: u64,
    released_since_feedback: bool,
    stats: Vec<serde_json::Value>,
    ended: Option<String>,
    welcome: Option<serde_json::Value>,
    max_datagram: usize,
    /// The upstream sender once the host opened the stream.
    upstream: Option<UpstreamSender>,
    /// The host's answer to `stream_open`: opened, or the refusal reason.
    stream_answer: Option<Result<(), String>>,
    /// The host closed the upstream stream.
    upstream_closed_by_host: bool,
}

fn pct(xs: &mut [f64]) -> serde_json::Value {
    if xs.is_empty() {
        return json!(null);
    }
    xs.sort_by(f64::total_cmp);
    let q = |p: f64| xs[((p / 100.0) * (xs.len() - 1) as f64).round() as usize];
    json!({"n": xs.len(), "min": xs[0], "p50": q(50.0), "p95": q(95.0), "p99": q(99.0), "max": xs[xs.len() - 1]})
}

impl Viewer {
    fn send_datagram(&mut self, d: &[u8]) -> io::Result<()> {
        match &self.udp {
            Some((sock, host)) => sock.send_to(d, host).map(|_| ()),
            None => write_frame(&mut self.tcp, FRAME_DATAGRAM, d),
        }
    }

    fn on_datagram(&mut self, d: &[u8]) {
        let now = now_ns();
        let Ok((h, payload)) = DatagramHeader::decode(d) else { return };
        match h.kind {
            DatagramKind::Video | DatagramKind::Fec => {
                self.bytes += d.len() as u64;
                self.arrivals.push(Arrival {
                    transport_seq: h.transport_seq,
                    arrival_us: (now / 1000) as u32,
                });
                for frame in self.reassembler.push(&h, payload, now / 1000) {
                    self.released_since_feedback = true;
                    self.frames += 1;
                    let t0 = now_ns();
                    let decoded = self.decoder.decode(&frame.body.access_unit);
                    let t1 = now_ns();
                    self.decode_ms.push((t1 - t0) as f64 / 1e6);
                    match decoded {
                        Ok(Some(yuv)) => {
                            if let Some(v) = marker::decode_luma(yuv.y(), yuv.strides().0, true) {
                                if self.marker != Some(v) {
                                    self.marker = Some(v);
                                    self.marker_at_ns = t1;
                                    self.marker_capture_us = frame.body.t_capture_us;
                                }
                            }
                        }
                        Ok(None) => {}
                        Err(_) => self.decode_errors += 1,
                    }
                }
            }
            DatagramKind::Feedback if h.stream == UP_STREAM => {
                let resends = match self.upstream.as_mut() {
                    Some(up) => up.on_datagram(d, now / 1000).unwrap_or_default(),
                    None => Vec::new(),
                };
                for datagram in resends {
                    let _ = self.send_datagram(&datagram);
                }
            }
            DatagramKind::InputAck if payload.len() >= 4 => {
                self.sender
                    .ack(u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]));
            }
            _ => {}
        }
    }

    fn pump(&mut self, timeout_ns: u64) -> Res<()> {
        let mut fds = vec![self.tcp.as_raw_fd()];
        if let Some((s, _)) = &self.udp {
            fds.push(s.as_raw_fd());
        }
        wait_readable(&fds, Some(timeout_ns))?;
        if let Err(e) = self.reader.fill(&mut self.tcp) {
            self.ended.get_or_insert(format!("host closed: {e}"));
        }
        while let Some((ty, payload)) = self.reader.next()? {
            match ty {
                FRAME_DATAGRAM => self.on_datagram(&payload),
                FRAME_CONTROL => match serde_json::from_slice::<Control>(&payload)? {
                    Control::Stats { .. } => self.stats.push(serde_json::from_slice(&payload)?),
                    Control::Welcome { max_datagram, .. } => {
                        // Upstream datagrams use the size the host agreed to.
                        self.max_datagram = max_datagram;
                        self.welcome = Some(serde_json::from_slice(&payload)?)
                    }
                    Control::Refused { reason } | Control::Ended { reason } => {
                        self.ended.get_or_insert(reason);
                    }
                    Control::StreamOpened { stream } if stream == UP_STREAM => {
                        self.stream_answer = Some(Ok(()));
                    }
                    Control::StreamRefused { stream, reason } if stream == UP_STREAM => {
                        self.stream_answer = Some(Err(reason));
                    }
                    Control::StreamClose { stream } if stream == UP_STREAM => {
                        self.upstream_closed_by_host = true;
                    }
                    _ => {}
                },
                _ => {}
            }
        }
        if let Some((sock, _)) = &self.udp {
            let sock = sock.try_clone()?;
            let mut buf = vec![0u8; 65536];
            loop {
                match sock.recv_from(&mut buf) {
                    Ok((n, _)) => {
                        let d = buf[..n].to_vec();
                        self.on_datagram(&d);
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e.into()),
                }
            }
        }
        self.reassembler.tick(now_ns() / 1000);
        self.maybe_feedback()?;
        self.send_input()?;
        Ok(())
    }

    fn send_input(&mut self) -> Res<()> {
        if let Some(packet) = self.sender.packet() {
            let mut d = Vec::new();
            DatagramHeader {
                flags: 0,
                kind: DatagramKind::Input,
                stream: 0,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode_into(&mut d);
            d.extend_from_slice(&packet.encode());
            self.send_datagram(&d)?;
        }
        Ok(())
    }

    fn maybe_feedback(&mut self) -> Res<()> {
        let now = now_ns();
        let due = now.saturating_sub(self.last_feedback_ns) >= 50_000_000;
        // At least one feedback per second keeps the session alive on an idle desktop.
        let keepalive = now.saturating_sub(self.last_feedback_ns) >= 1_000_000_000;
        if !(self.released_since_feedback
            || keepalive
            || (due && (!self.arrivals.is_empty() || self.reassembler.need_recovery())))
        {
            return Ok(());
        }
        let nacks = self
            .reassembler
            .missing(now / 1000, 5_000)
            .into_iter()
            .take(4)
            .map(|(frame, indexes)| Nack { frame, indexes: indexes.into_iter().take(32).collect() })
            .collect();
        let mut sorted = self.decode_ms.iter().rev().take(30).copied().collect::<Vec<_>>();
        sorted.sort_by(f64::total_cmp);
        // Arrivals beyond one message go in extra feedback messages first.
        while self.arrivals.len() > MAX_ARRIVALS {
            let rest = self.arrivals.split_off(MAX_ARRIVALS);
            let head = std::mem::replace(&mut self.arrivals, rest);
            let fb = Feedback {
                acked_frame: self.reassembler.last_released(),
                arrivals: head,
                ..Feedback::default()
            };
            self.send_feedback(&fb)?;
        }
        let fb = Feedback {
            acked_frame: self.reassembler.last_released(),
            decode_us: sorted.get(sorted.len() / 2).map_or(0, |m| (m * 1000.0) as u32),
            need_recovery: self.reassembler.need_recovery(),
            arrivals: std::mem::take(&mut self.arrivals),
            nacks,
        };
        self.send_feedback(&fb)?;
        self.last_feedback_ns = now;
        self.released_since_feedback = false;
        Ok(())
    }
}

impl Viewer {
    fn send_feedback(&mut self, fb: &Feedback) -> Res<()> {
        let mut d = Vec::with_capacity(HEADER_LEN + 64);
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::Feedback,
            stream: 0,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        }
        .encode_into(&mut d);
        d.extend_from_slice(&fb.encode());
        self.send_datagram(&d)?;
        Ok(())
    }
}

/// One synthetic upstream frame: an Opus-sized packet, or a keyframe-sized
/// or delta-sized access unit; every byte depends on the frame number.
fn synthetic_frame(index: usize, audio: bool, independent: bool) -> Vec<u8> {
    let len = if audio {
        120
    } else if independent {
        8000
    } else {
        1200 + index % 7 * 100
    };
    (0..len).map(|i| (index.wrapping_mul(31).wrapping_add(i) & 0xff) as u8).collect()
}

/// Opens one upstream stream, sends `frames` synthetic frames at the media's
/// rate, waits for the host to acknowledge the last one, and closes it.
fn run_upstream(v: &mut Viewer, which: &str, frames: usize) -> Res<serde_json::Value> {
    let (kind, codec, interval_ns, audio) = match which {
        "mic" => (StreamKind::UpAudio, "opus", 10_000_000u64, true),
        "camera" | "screen" => (StreamKind::UpVideo, "h264", 33_333_333u64, false),
        other => return Err(format!("--upstream {other}: expected mic, camera or screen").into()),
    };
    write_control(
        &mut v.tcp,
        &Control::StreamOpen { stream: UP_STREAM, kind, codec: codec.into(), of: None },
    )?;
    let asked = now_ns();
    while v.stream_answer.is_none() {
        v.pump(5_000_000)?;
        if let Some(e) = &v.ended {
            return Err(format!("ended before the answer to stream_open: {e}").into());
        }
        if now_ns() - asked > 5_000_000_000 {
            return Err("no answer to stream_open within 5 s".into());
        }
    }
    if let Some(Err(reason)) = v.stream_answer.take() {
        return Err(format!("upstream {which} refused by the host: {reason}").into());
    }
    v.upstream = Some(UpstreamSender::new(UpstreamConfig {
        stream: UP_STREAM,
        max_datagram: v.max_datagram,
        cc: CcConfig::default(),
        path: PathKind::DirectLan,
        // Opus carries its own FEC; video gets block FEC.
        fec: !audio,
    }));
    let (mut hash, mut bytes, mut sent) = (crate::upstream::FNV_OFFSET, 0u64, 0u32);
    let begin = now_ns();
    for index in 0..frames {
        let due = begin + index as u64 * interval_ns;
        while now_ns() < due {
            v.pump(due.saturating_sub(now_ns()).max(1_000_000))?;
        }
        let Some(up) = v.upstream.as_mut() else { break };
        let independent = audio || index % 30 == 0 || up.keyframe_requested();
        let frame = synthetic_frame(index, audio, independent);
        let now_us = now_ns() / 1000;
        let datagrams = up
            .send_frame(&frame, now_us, independent, now_us)
            .map_err(|e| format!("upstream packetize: {e:?}"))?;
        if let Some(datagrams) = datagrams {
            for d in &datagrams {
                v.send_datagram(d)?;
            }
            hash = crate::upstream::fnv1a(hash, &frame);
            bytes += frame.len() as u64;
            sent += 1;
        }
        if v.ended.is_some() || v.upstream_closed_by_host {
            break;
        }
    }
    // The sender numbers sent frames from 1, so the last one is `sent`.
    let waited = now_ns();
    while v.upstream.as_ref().is_some_and(|up| up.stats().acked_frame < sent)
        && now_ns() - waited < 3_000_000_000
        && v.ended.is_none()
    {
        v.pump(5_000_000)?;
    }
    let _ = write_control(&mut v.tcp, &Control::StreamClose { stream: UP_STREAM });
    let stats = v.upstream.take().map(|up| up.stats());
    Ok(json!({
        "kind": which,
        "frames_asked": frames,
        "frames_sent": sent,
        "frames_dropped": stats.map(|s| s.frames_dropped),
        "acked_frame": stats.map(|s| s.acked_frame),
        "loss": stats.map(|s| s.loss),
        "bytes_sent": bytes,
        "fnv1a": format!("{hash:016x}"),
        "closed_by_host": v.upstream_closed_by_host,
        "all_acked": stats.is_some_and(|s| s.acked_frame == sent && sent > 0),
    }))
}

fn cpu_s() -> f64 {
    // SAFETY: rusage is plain old data; all-zero is a valid value.
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: getrusage fills the struct we own.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    ru.ru_utime.tv_sec as f64
        + ru.ru_utime.tv_usec as f64 / 1e6
        + ru.ru_stime.tv_sec as f64
        + ru.ru_stime.tv_usec as f64 / 1e6
}

pub fn run(opts: &Opts) -> Res<()> {
    let addr: SocketAddr = opts.str_or("addr", "127.0.0.1:4103").parse()?;
    let samples: usize = opts.num_or("samples", 300)?;
    let carrier = opts.str_or("carrier", "udp");
    let tcp = TcpStream::connect(addr)?;
    tcp.set_nodelay(true)?;
    tcp.set_nonblocking(true)?;
    let udp = if carrier == "udp" {
        let s = UdpSocket::bind("0.0.0.0:0")?;
        s.set_nonblocking(true)?;
        crate::wire::grow_udp_buffers(&s);
        Some((s, addr))
    } else {
        None
    };
    let mut v = Viewer {
        tcp,
        reader: FrameReader::default(),
        reassembler: Reassembler::new(opts.num_or("deadline-ms", 200u64)? * 1000),
        decoder: Decoder::new()?,
        sender: InputSender::new(),
        arrivals: Vec::new(),
        marker: None,
        marker_at_ns: 0,
        marker_capture_us: 0,
        frames: 0,
        bytes: 0,
        decode_ms: Vec::new(),
        decode_errors: 0,
        last_feedback_ns: 0,
        released_since_feedback: false,
        stats: Vec::new(),
        ended: None,
        welcome: None,
        udp: None,
        max_datagram: opts.num_or("max-datagram", MAX_DATAGRAM_VPC)?,
        upstream: None,
        stream_answer: None,
        upstream_closed_by_host: false,
    };
    let upstream = opts.get("upstream").map(str::to_owned);
    let udp_port = udp.as_ref().map(|(s, _)| s.local_addr().map(|a| a.port())).transpose()?;
    v.udp = udp;
    let pid = std::process::id();
    let user = opts.str_or("user", "owner");
    write_control(
        &mut v.tcp,
        &Control::Hello {
            user,
            install: format!("bench-{pid}"),
            class: "user".into(),
            interactive: true,
            udp_port,
            max_datagram: v.max_datagram,
            token: match opts.get("token-fd") {
                Some(fd) => Some(cmux_rd_proto::control::SecretHex(
                    crate::token::Token::read_fd(fd.parse()?)?.to_hex(),
                )),
                None => None,
            },
            service: cmux_rd_core::service::SERVICE_DESKTOP.into(),
            // Upstream media needs both caps (rd change C4).
            caps: if upstream.is_some() {
                vec![caps::UP_MEDIA.into(), caps::STREAM_OPEN.into()]
            } else {
                Vec::new()
            },
        },
    )?;
    write_control(
        &mut v.tcp,
        &Control::Start { key: format!("bench-{pid}-{}", now_ns()), mode: "control".into() },
    )?;
    // Wait for the first decoded marker (the first frame is an IDR).
    let start = now_ns();
    while v.marker.is_none() {
        v.pump(5_000_000)?;
        if let Some(e) = &v.ended {
            return Err(format!("ended before the first frame: {e}").into());
        }
        if now_ns() - start > 15_000_000_000 {
            return Err(format!(
                "no marker within 15 s (bytes {}, frames released {}, decode errors {}, losses {:?})",
                v.bytes,
                v.frames,
                v.decode_errors,
                v.reassembler.take_losses().into_iter().take(5).collect::<Vec<_>>()
            )
            .into());
        }
    }
    let upstream_report = match &upstream {
        Some(which) => {
            let report = run_upstream(&mut v, which, opts.num_or("upstream-frames", 100)?)?;
            println!("{}", json!({ "upstream": report }));
            if report["all_acked"] != json!(true) {
                return Err(format!(
                    "upstream {which}: the host did not acknowledge every sent frame"
                )
                .into());
            }
            Some(report)
        }
        None => None,
    };
    let (b0, f0, c0, t_begin) = (v.bytes, v.frames, cpu_s(), now_ns());
    let mut rng = Rng::new(u64::from(pid) ^ now_ns());
    let mut g2g = Vec::new();
    // Same-machine runs share CLOCK_MONOTONIC, so these split the sample at the host capture.
    let mut to_capture = Vec::new();
    let mut capture_to_decoded = Vec::new();
    let mut lost = 0usize;
    while g2g.len() + lost < samples && v.ended.is_none() {
        let expected = v.marker.unwrap_or(0).wrapping_add(1);
        let t0 = now_ns();
        v.sender.push(InputEvent::Key { usage: KEY_A, down: true });
        v.sender.push(InputEvent::Key { usage: KEY_A, down: false });
        // Send at once; pump() resends until the host acknowledges.
        v.send_input()?;
        loop {
            v.pump(2_000_000)?;
            if v.marker == Some(expected) {
                g2g.push((v.marker_at_ns - t0) as f64 / 1e6);
                to_capture.push((v.marker_capture_us as f64 * 1000.0 - t0 as f64) / 1e6);
                capture_to_decoded
                    .push((v.marker_at_ns as f64 - v.marker_capture_us as f64 * 1000.0) / 1e6);
                break;
            }
            if now_ns() - t0 > 1_000_000_000 {
                lost += 1;
                break;
            }
        }
        let gap_end = now_ns() + rng.range(40, 160) * 1_000_000;
        while now_ns() < gap_end {
            v.pump(gap_end.saturating_sub(now_ns()).max(1_000_000))?;
        }
    }
    let secs = (now_ns() - t_begin) as f64 / 1e9;
    let report = json!({
        "addr": addr.to_string(),
        "carrier": carrier,
        "welcome": v.welcome,
        "g2g_ms": pct(&mut g2g),
        "lost": lost,
        "same_clock_input_to_capture_ms": pct(&mut to_capture),
        "same_clock_capture_to_decoded_ms": pct(&mut capture_to_decoded),
        "frames_per_s": (v.frames - f0) as f64 / secs,
        "mbit_per_s": (v.bytes - b0) as f64 * 8.0 / secs / 1e6,
        "decode_ms": pct(&mut v.decode_ms.clone()),
        "decode_errors": v.decode_errors,
        "client_cpu_pct": (cpu_s() - c0) / secs * 100.0,
        "host_stats_last": v.stats.last(),
        "upstream": upstream_report,
        "ended": v.ended,
    });
    println!("{report}");
    let _ = write_control(&mut v.tcp, &Control::Stop);
    Ok(())
}
