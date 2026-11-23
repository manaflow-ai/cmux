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
use crate::scaled::Scale;
use crate::wire::{
    write_control, write_frame, Control, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use crate::Res;
use cmux_rd_core::cc::{CcConfig, PathKind};
use cmux_rd_core::clock::ClockEstimator;
use cmux_rd_core::input::InputSender;
use cmux_rd_core::ledger::StageLedger;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_core::service::caps;
use cmux_rd_core::upstream::{UpstreamConfig, UpstreamSender};
use cmux_rd_proto::control::StreamKind;
use cmux_rd_proto::{
    Arrival, ClockPong, DatagramHeader, DatagramKind, Feedback, FrameTimes, InputEvent, HEADER_LEN,
    MAX_ARRIVALS, MAX_DATAGRAM_VPC,
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
/// The most `--marker-log` entries kept (about 28 minutes at 60 fps).
const MARKER_LOG_MAX: usize = 100_000;

#[cfg(all(test, any(feature = "vp9", feature = "av1")))]
#[path = "bench_eval_tests.rs"]
mod eval_tests;

/// How the bench reaches the host: the development sockets, or a device hub
/// session's secure link (`--link`, the same path `cmux-rd serve` serves).
enum ViewerIo {
    Socket {
        tcp: TcpStream,
        reader: FrameReader,
        udp: Option<(UdpSocket, SocketAddr)>,
    },
    #[cfg(feature = "link")]
    Link(LinkIo),
}

/// `--link`'s driver and its connect times on this Mac's protocol clock (µs), printed once
/// as `{"link":{..}}` on stdout when the link comes up or fails: the connect a person waits
/// for, without the time a measuring script's relay adds (scripts/screen-share-vs.py).
#[cfg(feature = "link")]
struct LinkIo {
    net: cmux_rd_link::net::Net,
    /// The answer line (the host's key and candidates) was read.
    answer_us: u64,
    /// The host's candidates reached the link driver. Message 1 is queued at start and
    /// goes out on the driver's next turn, once a route exists, so this is its send time
    /// to within one thread wake.
    first_send_us: u64,
    reported: bool,
}

#[cfg(feature = "link")]
impl LinkIo {
    /// The `{"link":{..}}` line, once: `established_us` when the link came up, else the
    /// failure (`heard 0` and the like), so a link that never answers still has its times.
    fn report(&mut self, failed: Option<&str>) {
        if self.reported {
            return;
        }
        self.reported = true;
        println!("{}", link_line(self.answer_us, self.first_send_us, now_ns() / 1000, failed));
    }
}

/// `{"link":{"answer_us","first_send_us","established_us"}}`, or with `failed_us` and
/// `failed` in place of `established_us` when the link failed.
#[cfg(feature = "link")]
fn link_line(
    answer_us: u64,
    first_send_us: u64,
    now_us: u64,
    failed: Option<&str>,
) -> serde_json::Value {
    let mut link = json!({"answer_us": answer_us, "first_send_us": first_send_us});
    match failed {
        None => link["established_us"] = json!(now_us),
        Some(reason) => {
            link["failed_us"] = json!(now_us);
            link["failed"] = json!(reason);
        }
    }
    json!({ "link": link })
}

/// One control record or datagram that arrived.
enum Arrived {
    Control(Vec<u8>),
    Datagram(Vec<u8>),
    Closed(String),
}

impl ViewerIo {
    fn send_datagram(&mut self, d: &[u8]) -> io::Result<()> {
        match self {
            Self::Socket { udp: Some((sock, host)), .. } => sock.send_to(d, *host).map(|_| ()),
            Self::Socket { tcp, .. } => write_frame(tcp, FRAME_DATAGRAM, d),
            #[cfg(feature = "link")]
            Self::Link(link) => {
                link.net.send_datagram(d.to_vec());
                Ok(())
            }
        }
    }

    fn send_control(&mut self, c: &Control) -> io::Result<()> {
        match self {
            Self::Socket { tcp, .. } => write_control(tcp, c),
            #[cfg(feature = "link")]
            Self::Link(link) => {
                link.net.send_control(serde_json::to_vec(c).map_err(io::Error::other)?);
                Ok(())
            }
        }
    }

    fn fds(&self) -> Vec<std::os::fd::RawFd> {
        match self {
            Self::Socket { tcp, udp, .. } => {
                let mut fds = vec![tcp.as_raw_fd()];
                if let Some((s, _)) = udp {
                    fds.push(s.as_raw_fd());
                }
                fds
            }
            #[cfg(feature = "link")]
            Self::Link(link) => vec![link.net.event_fd()],
        }
    }

    fn receive(&mut self, out: &mut Vec<Arrived>) -> Res<()> {
        match self {
            Self::Socket { tcp, reader, udp } => {
                if let Err(e) = reader.fill(tcp) {
                    out.push(Arrived::Closed(format!("host closed: {e}")));
                }
                while let Some((ty, payload)) = reader.next()? {
                    match ty {
                        FRAME_DATAGRAM => out.push(Arrived::Datagram(payload)),
                        FRAME_CONTROL => out.push(Arrived::Control(payload)),
                        _ => {}
                    }
                }
                if let Some((sock, _)) = udp {
                    let mut buf = vec![0u8; 65536];
                    loop {
                        match sock.recv_from(&mut buf) {
                            Ok((n, _)) => out.push(Arrived::Datagram(buf[..n].to_vec())),
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                            Err(e) => return Err(e.into()),
                        }
                    }
                }
            }
            #[cfg(feature = "link")]
            Self::Link(link) => {
                use cmux_rd_link::net::NetEvent;
                use cmux_rd_link::{EndpointEvent, Event};
                for event in link.net.events() {
                    if let Some(line) = event.phase_line() {
                        println!("{line}");
                    }
                    match event {
                        NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                            out.push(Arrived::Datagram(d))
                        }
                        NetEvent::Endpoint(EndpointEvent::Link(Event::Control(r))) => {
                            out.push(Arrived::Control(r))
                        }
                        NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                            out.push(Arrived::Closed("host closed the link".into()))
                        }
                        NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                            link.report(None)
                        }
                        NetEvent::Failed(e) => {
                            link.report(Some(&e));
                            out.push(Arrived::Closed(format!("link failed: {e}")))
                        }
                        NetEvent::Endpoint(EndpointEvent::PathChanged { kind, rtt_us, .. }) => {
                            eprintln!(
                                "{}",
                                json!({"path": {"kind": kind.map(|k| k.wire_name()), "rtt_ms": rtt_us.map(|u| u as f64 / 1000.0)}})
                            );
                        }
                        _ => {}
                    }
                }
            }
        }
        Ok(())
    }
}

struct Viewer {
    io: ViewerIo,
    reassembler: Reassembler,
    decoder: Decoder,
    /// Refuses frames under a High-profile SPS, which OpenH264 decodes to wrong pictures with
    /// no error (cmux#50591): they count as decode errors, and the first one is printed.
    h264_gate: cmux_encode::h264_profile::ProfileGate,
    h264_gate_said: bool,
    sender: InputSender,
    arrivals: Vec<Arrival>,
    marker: Option<u16>,
    marker_at_ns: u64,
    /// Linux `--present`: when the frame that showed the marker was on the X display (this
    /// machine's clock, ns; `Presenter::show` returns once the server copied it), else 0.
    marker_shown_ns: u64,
    /// When the newest decoded frame was on the display (0: not shown).
    last_shown_ns: u64,
    /// Host capture time (host monotonic us) of the frame that showed the marker.
    marker_capture_us: u64,
    /// The frame that showed the marker, when its first datagram arrived and when the
    /// datagram that completed it arrived (this Mac's clock, ns): with `marker_at_ns`, the
    /// viewer's share of a key press's time (`sample_times`, scripts/screen-share-vs.py).
    marker_frame: u32,
    marker_first_rx_ns: u64,
    marker_complete_ns: u64,
    /// Times the marker changed (`--input none`: the fps of a ticking marker).
    marker_changes: u64,
    /// `--marker-log 1` (passive runs): every marker change, as (decoded µs on the protocol
    /// clock, marker), so a script can time recovery after a stall frame by frame.
    marker_log: Option<Vec<(u64, u16)>>,
    /// The first datagram's arrival of the newest video frames (frame, ns).
    first_rx: std::collections::VecDeque<(u32, u64)>,
    frames: u64,
    decoded_frames: u64,
    eval_decode: Option<crate::eval::DecodeLog>,
    eval_quality: Option<crate::eval::Quality>,
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
    /// `--snapshot PATH`: the newest decoded frame as a binary PPM, written when the run ends.
    snapshot: Option<(usize, usize, Vec<u8>)>,
    /// The newest hardware-decoded picture for `--snapshot`, converted to RGB once, at the end.
    #[cfg(target_os = "macos")]
    newest_picture: Option<crate::vtdecode::Picture>,
    want_snapshot: bool,
    /// `--record PATH`: every received access unit (Annex-B), the stream the viewer decoded.
    record: Option<std::fs::File>,
    /// `--marker-origin X,Y`: the marker's top-left in stream pixels (default 0,0).
    marker_origin: (usize, usize),
    /// The stream's size once the host negotiated cap `video.scaled` (`--caps video.scaled`):
    /// a decoded picture smaller than it is read scaled up to it (src/scaled.rs).
    scaled_stream: Option<(usize, usize)>,
    /// macOS: the hardware decoder the viewer pane uses (`--decoder videotoolbox`, the
    /// default there); OpenH264 decodes constrained baseline only.
    #[cfg(target_os = "macos")]
    vt: Option<crate::vtdecode::VtDecoder>,
    /// Linux `--present :N`: every decoded frame drawn in a window on that X display.
    #[cfg(target_os = "linux")]
    presenter: Option<crate::present::Presenter>,
    /// The conversion the stream's last SPS asks for (untagged until the first SPS).
    color: cmux_encode::color::Yuv,
    present_errors: u64,
    /// Every frame's stage times (D8), from the host's `FrameTimes` and this viewer.
    ledger: StageLedger,
    /// The session clock (C8), once the welcome lists cap `clock`.
    clock: Option<ClockEstimator>,
    /// `--decoder vp9|av1` (features `vp9`, `av1`): a royalty-free codec's decoder, for a
    /// host started with the same `--codec`, and the picture it decodes into.
    #[cfg(any(feature = "vp9", feature = "av1"))]
    alt: Option<(Box<dyn cmux_encode::VideoDecoder>, cmux_encode::I420)>,
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
        self.io.send_datagram(d)
    }

    /// A decoded frame (`frame`, captured at host `t_capture_us`, completed at `complete_ns`,
    /// decoded at `decoded_ns`) read `read` from the marker.
    fn saw_marker(
        &mut self,
        read: Option<u16>,
        frame: u32,
        t_capture_us: u64,
        complete_ns: u64,
        decoded_ns: u64,
    ) {
        let Some(v) = read else { return };
        if self.marker == Some(v) {
            return;
        }
        self.marker_changes += u64::from(self.marker.is_some());
        if let Some(log) = self.marker_log.as_mut().filter(|log| log.len() < MARKER_LOG_MAX) {
            log.push((decoded_ns / 1000, v));
        }
        self.marker = Some(v);
        self.marker_at_ns = decoded_ns;
        self.marker_shown_ns = self.last_shown_ns;
        self.marker_capture_us = t_capture_us;
        self.marker_frame = frame;
        self.marker_complete_ns = complete_ns;
        self.marker_first_rx_ns =
            self.first_rx.iter().find(|(f, _)| *f == frame).map_or(complete_ns, |(_, at)| *at);
    }

    fn on_datagram(&mut self, d: &[u8]) {
        let now = now_ns();
        let Ok((h, payload)) = DatagramHeader::decode(d) else { return };
        match h.kind {
            DatagramKind::Video | DatagramKind::Fec => {
                self.bytes += d.len() as u64;
                self.ledger.on_shard(h.stream, h.frame, d.len(), now / 1000);
                self.arrivals.push(Arrival {
                    transport_seq: h.transport_seq,
                    arrival_us: (now / 1000) as u32,
                });
                if !self.first_rx.iter().any(|(f, _)| *f == h.frame) {
                    if self.first_rx.len() >= 64 {
                        self.first_rx.pop_front();
                    }
                    self.first_rx.push_back((h.frame, now));
                }
                for frame in self.reassembler.push(&h, payload, now / 1000) {
                    self.ledger.on_released(
                        h.stream,
                        frame.frame,
                        frame.last_shard_us,
                        frame.released_us,
                    );
                    self.released_since_feedback = true;
                    self.frames += 1;
                    if let Some(file) = self.record.as_mut() {
                        let _ = io::Write::write_all(file, &frame.body.access_unit);
                    }
                    let t0 = now_ns();
                    #[cfg(target_os = "macos")]
                    if let Some(vt) = self.vt.as_mut() {
                        let decoded = vt.decode(&frame.body.access_unit);
                        let t1 = now_ns();
                        self.decode_ms.push((t1 - t0) as f64 / 1e6);
                        match decoded {
                            Ok(Some(picture)) => {
                                self.decoded_frames += 1;
                                self.ledger.on_decoded(h.stream, frame.frame, t1 / 1000);
                                if let Some(log) = self.eval_decode.as_mut() {
                                    log.record(frame.frame, frame.body.t_capture_us, t1 / 1000);
                                }
                                let scale = scale_of(self.scaled_stream, picture.size());
                                if let Some(quality) = self.eval_quality.as_mut() {
                                    if let Some(pixels) =
                                        picture.with_luma(|y, stride| quality_roi(scale, y, stride))
                                    {
                                        quality.decoded(
                                            u64::from(frame.frame),
                                            frame.body.t_capture_us,
                                            &frame.body.access_unit,
                                            &pixels,
                                        );
                                    }
                                }
                                let origin = self.marker_origin;
                                let read = picture
                                    .with_luma(|y, stride| read_marker(scale, y, stride, origin));
                                self.saw_marker(
                                    read,
                                    frame.frame,
                                    frame.body.t_capture_us,
                                    now,
                                    t1,
                                );
                                if self.want_snapshot {
                                    self.newest_picture = Some(picture);
                                }
                            }
                            Ok(None) => {}
                            Err(_) => self.decode_errors += 1,
                        }
                        continue;
                    }
                    #[cfg(any(feature = "vp9", feature = "av1"))]
                    if let Some((dec, pic)) = self.alt.as_mut() {
                        let decoded = dec.decode(&frame.body.access_unit, pic);
                        let t1 = now_ns();
                        self.decode_ms.push((t1 - t0) as f64 / 1e6);
                        match decoded {
                            Ok(true) => {
                                self.decoded_frames += 1;
                                self.ledger.on_decoded(h.stream, frame.frame, t1 / 1000);
                                if let Some(log) = self.eval_decode.as_mut() {
                                    log.record(frame.frame, frame.body.t_capture_us, t1 / 1000);
                                }
                                let scale = scale_of(
                                    self.scaled_stream,
                                    (pic.width, pic.y.len() / pic.width.max(1)),
                                );
                                if let Some(quality) = self.eval_quality.as_mut() {
                                    if let Some(pixels) = quality_roi(scale, &pic.y, pic.width) {
                                        quality.decoded(
                                            u64::from(frame.frame),
                                            frame.body.t_capture_us,
                                            &frame.body.access_unit,
                                            &pixels,
                                        );
                                    }
                                }
                                let read =
                                    read_marker(scale, &pic.y, pic.width, self.marker_origin);
                                self.saw_marker(
                                    read,
                                    frame.frame,
                                    frame.body.t_capture_us,
                                    now,
                                    t1,
                                );
                            }
                            Ok(false) => {}
                            Err(_) => self.decode_errors += 1,
                        }
                        continue;
                    }
                    let t1;
                    // A block, so the decoder's borrowed picture ends before saw_marker.
                    if let Some(vui) = cmux_encode::color::sps_vui(&frame.body.access_unit) {
                        self.color = vui.yuv();
                    }
                    if let Err(why) = self.h264_gate.check(&frame.body.access_unit) {
                        self.decode_errors += 1;
                        if !std::mem::replace(&mut self.h264_gate_said, true) {
                            eprintln!("bench: {why}");
                        }
                        continue;
                    }
                    let read = {
                        let decoded = self.decoder.decode(&frame.body.access_unit);
                        t1 = now_ns();
                        self.decode_ms.push((t1 - t0) as f64 / 1e6);
                        match decoded {
                            Ok(Some(yuv)) => {
                                #[cfg(target_os = "linux")]
                                {
                                    self.last_shown_ns = 0;
                                    if let Some(p) = self.presenter.as_mut() {
                                        if p.show(&yuv, self.color).is_err() {
                                            self.present_errors += 1;
                                        } else {
                                            self.last_shown_ns = now_ns();
                                        }
                                    }
                                }
                                self.decoded_frames += 1;
                                self.ledger.on_decoded(h.stream, frame.frame, t1 / 1000);
                                if let Some(log) = self.eval_decode.as_mut() {
                                    log.record(frame.frame, frame.body.t_capture_us, t1 / 1000);
                                }
                                let scale = scale_of(self.scaled_stream, yuv.dimensions());
                                if let Some(quality) = self.eval_quality.as_mut() {
                                    if let Some(pixels) =
                                        quality_roi(scale, yuv.y(), yuv.strides().0)
                                    {
                                        quality.decoded(
                                            u64::from(frame.frame),
                                            frame.body.t_capture_us,
                                            &frame.body.access_unit,
                                            &pixels,
                                        );
                                    }
                                }
                                // OpenH264 lends its picture only for this call, so a snapshot
                                // converts every frame: use --snapshot for pictures, not timing.
                                if self.want_snapshot {
                                    let (w, h) = yuv.dimensions();
                                    // The stream's own matrix and range (openh264's
                                    // write_rgb8 is BT.601 whatever the stream says).
                                    let mut bgrx = vec![0u8; w * h * 4];
                                    cmux_encode::color::i420_to_bgrx(
                                        yuv.y(),
                                        yuv.u(),
                                        yuv.v(),
                                        yuv.strides(),
                                        w,
                                        h,
                                        self.color,
                                        &mut bgrx,
                                    );
                                    let rgb: Vec<u8> = bgrx
                                        .chunks_exact(4)
                                        .flat_map(|p| [p[2], p[1], p[0]])
                                        .collect();
                                    self.snapshot = Some((w, h, rgb));
                                }
                                read_marker(scale, yuv.y(), yuv.strides().0, self.marker_origin)
                            }
                            Ok(None) => None,
                            Err(_) => {
                                self.decode_errors += 1;
                                None
                            }
                        }
                    };
                    self.saw_marker(read, frame.frame, frame.body.t_capture_us, now, t1);
                }
            }
            // An ultra capacity probe: only its arrival goes back, in the media feedback.
            DatagramKind::Probe => {
                self.arrivals.push(Arrival {
                    transport_seq: h.transport_seq,
                    arrival_us: (now / 1000) as u32,
                });
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
            DatagramKind::FrameTimes => {
                if let Ok(times) = FrameTimes::decode(payload) {
                    self.ledger.on_host(h.stream, h.frame, times);
                }
            }
            DatagramKind::ClockPong => {
                if let (Some(clock), Ok(pong)) = (self.clock.as_mut(), ClockPong::decode(payload)) {
                    clock.on_pong(&pong, now / 1000);
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
        let timeout_ns =
            self.reassembler.next_nack_us(5_000, 50_000).map_or(timeout_ns, |deadline| {
                timeout_ns.min(deadline.saturating_mul(1000).saturating_sub(now_ns()))
            });
        #[allow(unused_mut)]
        let mut fds = self.io.fds();
        // A key typed into the `--present` window wakes the wait, so it leaves at once. Keys the
        // connection already read (during a frame's put) wake nothing, so they go first.
        #[cfg(target_os = "linux")]
        if let Some(p) = &self.presenter {
            fds.push(p.fd());
        }
        #[cfg(target_os = "linux")]
        self.forward_present_keys()?;
        wait_readable(&fds, Some(timeout_ns))?;
        #[cfg(target_os = "linux")]
        self.forward_present_keys()?;
        let mut arrived = Vec::new();
        self.io.receive(&mut arrived)?;
        for item in arrived {
            let payload = match item {
                Arrived::Datagram(d) => {
                    self.on_datagram(&d);
                    continue;
                }
                Arrived::Closed(reason) => {
                    self.ended.get_or_insert(reason);
                    continue;
                }
                Arrived::Control(payload) => payload,
            };
            match serde_json::from_slice::<Control>(&payload)? {
                Control::Stats { .. } => self.stats.push(serde_json::from_slice(&payload)?),
                Control::Welcome { max_datagram, width, height, caps: ref negotiated, .. } => {
                    // Upstream datagrams use the size the host agreed to.
                    self.max_datagram = max_datagram;
                    if negotiated.iter().any(|c| c == caps::VIDEO_SCALED) {
                        self.scaled_stream = Some((width as usize, height as usize));
                    }
                    let welcome: serde_json::Value = serde_json::from_slice(&payload)?;
                    // An older host refuses the probe kinds: ping only when it lists `clock`.
                    let lists = |cap: &str| {
                        welcome["caps"].as_array().is_some_and(|c| c.iter().any(|v| v == cap))
                    };
                    if lists(caps::CLOCK) {
                        self.clock.get_or_insert_with(ClockEstimator::new);
                    }
                    self.welcome = Some(welcome);
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
            }
        }
        self.reassembler.tick(now_ns() / 1000);
        self.maybe_feedback()?;
        self.send_clock_ping()?;
        self.send_input()?;
        Ok(())
    }

    /// The clock probe due now, if the session clock runs (cap `clock`).
    fn send_clock_ping(&mut self) -> Res<()> {
        let Some(ping) = self.clock.as_mut().and_then(|c| c.ping(now_ns() / 1000)) else {
            return Ok(());
        };
        let mut d = Vec::with_capacity(HEADER_LEN + 32);
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::ClockPing,
            stream: 0,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        }
        .encode_into(&mut d);
        d.extend_from_slice(&ping.encode());
        self.send_datagram(&d)?;
        Ok(())
    }

    /// The run's stage ledger (`cmux.rd-stage-ledger/1`) on the host's clock. The bench
    /// decodes but draws nothing on glass, so Present (and Total, which ends there) stay
    /// empty with that reason; `display_to_decoded` is the bench's end-to-end row.
    fn stage_ledger(&self) -> serde_json::Value {
        const NO_GLASS: &str =
            "cmux-rd bench decodes but has no on-glass present time; the app's drawable presented time fills it";
        let offset = self.clock.as_ref().and_then(ClockEstimator::estimate).map(|e| e.offset_us);
        let json =
            self.ledger.summary(offset, &[("Present", NO_GLASS), ("Total", NO_GLASS)]).to_json();
        serde_json::from_str(&json).unwrap_or(serde_json::Value::Null)
    }

    /// Sends the keys typed into the `--present` window to the host, as the app's viewer does.
    #[cfg(target_os = "linux")]
    fn forward_present_keys(&mut self) -> Res<()> {
        let Some(p) = self.presenter.as_mut() else {
            return Ok(());
        };
        let mut any = false;
        for (code, down) in p.take_keys()? {
            if let Some(usage) = crate::keymap::x_to_hid(code) {
                self.sender.push(InputEvent::Key { usage, down });
                any = true;
            }
        }
        if any {
            self.send_input()?;
        }
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
        let nack_due = self
            .reassembler
            .next_nack_us(5_000, 50_000)
            .is_some_and(|deadline| now / 1000 >= deadline);
        if !(self.released_since_feedback
            || keepalive
            || nack_due
            || (due && (!self.arrivals.is_empty() || self.reassembler.need_recovery())))
        {
            return Ok(());
        }
        let nacks = self.reassembler.take_nacks(now / 1000, 5_000, 50_000);
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
    v.io.send_control(&Control::StreamOpen {
        stream: UP_STREAM,
        kind,
        codec: codec.into(),
        of: None,
    })?;
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
    let _ = v.io.send_control(&Control::StreamClose { stream: UP_STREAM });
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

/// Whether the bench decodes H.264 with OpenH264 for `--decoder` (default: VideoToolbox on
/// macOS, OpenH264 elsewhere; `vp9` or `av1` is not H.264).
fn bench_decodes_with_openh264(decoder: Option<&str>) -> bool {
    match decoder {
        None => !cfg!(target_os = "macos"),
        Some(name) => name == "openh264",
    }
}

pub fn run(opts: &Opts) -> Res<()> {
    // The first decoder session in a process is the slow one: create a throwaway one now,
    // in parallel with connecting, so the first IDR does not pay for it.
    #[cfg(target_os = "macos")]
    if opts.str_or("decoder", "videotoolbox") == "videotoolbox"
        && opts.num_or("vt-prewarm", 1u8)? == 1
    {
        crate::vtdecode::prewarm_in_background();
    }
    let addr: SocketAddr = opts.str_or("addr", "127.0.0.1:4103").parse()?;
    let samples: usize = opts.num_or("samples", 300)?;
    let carrier = opts.str_or("carrier", "udp");
    let eval_local = opts.num_or("eval-local", 0u8)? == 1;
    let eval_relay = opts.num_or("eval-netem-relay", 0u8)? == 1;
    if (eval_local || eval_relay) && (!addr.ip().is_loopback() || opts.get("link").is_some()) {
        return Err("local eval requires a loopback socket address, without --link".into());
    }
    if eval_relay && carrier != "udp" {
        return Err("--eval-netem-relay requires --carrier udp".into());
    }
    // key (default) | click | scroll: which input moves the marker (cloud browser page);
    // none: a passive window (`run_passive`).
    let input = opts.str_or("input", "key");
    let (io, udp_port) = if opts.get("link").is_some() {
        #[cfg(feature = "link")]
        {
            (link_io()?, None)
        }
        #[cfg(not(feature = "link"))]
        return Err("--link needs a build with the link feature".into());
    } else {
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
        let udp_port = udp
            .as_ref()
            .map(|(s, _)| -> io::Result<u16> {
                if eval_relay {
                    // Teach the local relay our actual endpoint before Hello. The relay
                    // consumes this empty probe; advertise its port for downstream media.
                    s.send_to(&[], addr)?;
                    Ok(addr.port())
                } else {
                    Ok(s.local_addr()?.port())
                }
            })
            .transpose()?;
        (ViewerIo::Socket { tcp, reader: FrameReader::default(), udp }, udp_port)
    };
    let mut v = Viewer {
        io,
        reassembler: {
            let mut r = Reassembler::new(opts.num_or("deadline-ms", 200u64)? * 1000);
            // `--rtt-nack-retry 1`: NACK retries a measured repair round trip apart
            // instead of every 50 ms (design D6). Off by default.
            r.set_rtt_nack_retry(opts.num_or("rtt-nack-retry", 0u8)? == 1);
            r
        },
        decoder: Decoder::new()?,
        h264_gate: Default::default(),
        h264_gate_said: false,
        sender: InputSender::new(),
        arrivals: Vec::new(),
        marker: None,
        marker_at_ns: 0,
        marker_shown_ns: 0,
        last_shown_ns: 0,
        marker_capture_us: 0,
        marker_frame: 0,
        marker_first_rx_ns: 0,
        marker_complete_ns: 0,
        marker_changes: 0,
        marker_log: (opts.num_or("marker-log", 0u8)? == 1).then(Vec::new),
        first_rx: std::collections::VecDeque::new(),
        frames: 0,
        decoded_frames: 0,
        eval_decode: eval_local.then(crate::eval::DecodeLog::default),
        eval_quality: if eval_local { crate::eval::Quality::from_env() } else { None },
        bytes: 0,
        decode_ms: Vec::new(),
        decode_errors: 0,
        last_feedback_ns: 0,
        released_since_feedback: false,
        stats: Vec::new(),
        ended: None,
        welcome: None,
        max_datagram: opts.num_or("max-datagram", MAX_DATAGRAM_VPC)?,
        upstream: None,
        stream_answer: None,
        upstream_closed_by_host: false,
        snapshot: None,
        #[cfg(target_os = "macos")]
        newest_picture: None,
        want_snapshot: opts.get("snapshot").is_some(),
        record: opts.get("record").map(std::fs::File::create).transpose()?,
        #[cfg(target_os = "macos")]
        vt: match opts.str_or("decoder", "videotoolbox").as_str() {
            "videotoolbox" => Some(crate::vtdecode::VtDecoder::new()),
            "openh264" => None,
            other => return Err(format!("--decoder {other}: use videotoolbox or openh264").into()),
        },
        #[cfg(any(feature = "vp9", feature = "av1"))]
        alt: match opts.get("decoder").and_then(cmux_encode::Codec::parse) {
            Some(codec @ (cmux_encode::Codec::Vp9 | cmux_encode::Codec::Av1)) => Some((
                cmux_codecs::open_decoder(codec, 2)?
                    .ok_or(format!("--decoder {}: not in this build", codec.wire_name()))?,
                cmux_encode::I420::new(2, 2),
            )),
            _ => None,
        },
        marker_origin: match opts.get("marker-origin") {
            Some(at) => {
                let (x, y) = at.split_once(',').ok_or("--marker-origin takes X,Y")?;
                (x.trim().parse()?, y.trim().parse()?)
            }
            None => (0, 0),
        },
        scaled_stream: None,
        #[cfg(target_os = "linux")]
        presenter: opts.get("present").map(crate::present::Presenter::open).transpose()?,
        color: cmux_encode::color::UNTAGGED.yuv(),
        present_errors: 0,
        ledger: StageLedger::new(),
        clock: None,
    };
    #[cfg(not(target_os = "linux"))]
    if opts.get("present").is_some() {
        return Err("--present needs Linux (X11)".into());
    }
    // `--at X,Y`: where click and scroll input lands, in stream pixels.
    let (at_x, at_y) = match opts.get("at") {
        Some(at) => {
            let (x, y) = at.split_once(',').ok_or("--at takes X,Y")?;
            (x.trim().parse::<i32>()?, y.trim().parse::<i32>()?)
        }
        None => (960, 600),
    };
    let upstream = opts.get("upstream").map(str::to_owned);
    let pid = std::process::id();
    let user = opts.str_or("user", "owner");
    v.io.send_control(&Control::Hello {
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
        // Upstream media needs both caps (rd change C4). This reassembler rebuilds frames in
        // interleaved FEC blocks. `--caps A,B` offers more, such as `video.scaled` (the
        // resolution ladder).
        caps: {
            let mut offered =
                vec![caps::CLOCK.into(), caps::LEDGER.into(), caps::FEC_BLOCKS.into()];
            // Decoding with OpenH264 (Linux's only H.264 decoder, `--decoder openh264` on macOS):
            // ask an H.264 host for Constrained Baseline, the profile it shows correctly.
            if bench_decodes_with_openh264(opts.get("decoder")) {
                offered.push(caps::H264_BASELINE.into());
            }
            if upstream.is_some() {
                offered.extend([caps::UP_MEDIA.into(), caps::STREAM_OPEN.into()]);
            }
            offered.extend(opts.get("caps").into_iter().flat_map(|list| {
                list.split(',').map(str::trim).filter(|c| !c.is_empty()).map(str::to_owned)
            }));
            offered
        },
    })?;
    v.io.send_control(&Control::Start {
        key: format!("bench-{pid}-{}", now_ns()),
        mode: "control".into(),
    })?;
    // `--input none` (a passive window): no marker on screen, so wait for the first frame.
    if input == "none" {
        return run_passive(opts, &mut v, addr, &carrier);
    }
    // Wait for the first decoded marker (the first frame is an IDR). With `--link` the
    // clock starts when the viewer has the host's answer, so it covers the link's
    // handshake, hello and start, the first keyframe's encode, transfer and decode.
    let start = now_ns();
    while v.marker.is_none() {
        v.pump(5_000_000)?;
        if let Some(e) = &v.ended {
            return Err(format!("ended before the first frame: {e}").into());
        }
        if now_ns() - start > 15_000_000_000 {
            write_snapshot(opts, &v)?;
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
    let first_frame_ms = (v.marker_at_ns.saturating_sub(start)) as f64 / 1e6;
    // The first frame's own times, so a script can split first_frame_ms with the host's log.
    let first_frame_times = json!({
        "start_ns": start,
        "capture_us": v.marker_capture_us,
        "first_rx_ns": v.marker_first_rx_ns,
        "complete_ns": v.marker_complete_ns,
        "decoded_ns": v.marker_at_ns,
        "presented_ns": v.marker_shown_ns,
    });
    // `--present`: connect start to the first frame on the display, and key to the frame on it.
    let first_frame_presented_ms = (v.marker_shown_ns >= start && v.marker_shown_ns > 0)
        .then(|| (v.marker_shown_ns - start) as f64 / 1e6);
    let mut presented = Vec::new();
    let (b0, f0, c0, t_begin) = (v.bytes, v.frames, cpu_s(), now_ns());
    // A stall is a run of lost samples: from the first lost key press to the next one
    // that showed. A link blip shows up here as its length plus the recovery time.
    let mut stall_from: Option<u64> = None;
    let mut stalls_ms = Vec::new();
    let mut rng = Rng::new(u64::from(pid) ^ now_ns());
    let mut g2g = Vec::new();
    // Same-machine runs share CLOCK_MONOTONIC, so these split the sample at the host capture.
    let mut to_capture = Vec::new();
    let mut capture_to_decoded = Vec::new();
    // Each shown sample on this Mac's clock (ns) with the host's capture time (µs), for a
    // breakdown against the host's CMUX_RD_TIMING_LOG (scripts/screen-share-vs.py).
    let mut sample_times = Vec::new();
    let mut lost = 0usize;
    while g2g.len() + lost < samples && v.ended.is_none() {
        let expected = v.marker.unwrap_or(0).wrapping_add(1);
        let t0 = now_ns();
        match input.as_str() {
            // The cloud browser's marker page counts mousedown and wheel as well as keydown.
            "click" => {
                v.sender.push(InputEvent::Pointer { x: at_x, y: at_y });
                v.sender.push(InputEvent::Button { button: 0, down: true });
                v.sender.push(InputEvent::Button { button: 0, down: false });
            }
            "scroll" => {
                v.sender.push(InputEvent::Pointer { x: at_x, y: at_y });
                let dy = if g2g.len() % 2 == 0 { -300 } else { 300 };
                v.sender.push(InputEvent::Scroll { dx: 0, dy, precise: false });
            }
            _ => {
                v.sender.push(InputEvent::Key { usage: KEY_A, down: true });
                v.sender.push(InputEvent::Key { usage: KEY_A, down: false });
            }
        }
        // Send at once; pump() resends until the host acknowledges.
        v.send_input()?;
        loop {
            v.pump(2_000_000)?;
            if v.marker == Some(expected) {
                if let Some(from) = stall_from.take() {
                    stalls_ms.push((v.marker_at_ns - from) as f64 / 1e6);
                }
                g2g.push((v.marker_at_ns - t0) as f64 / 1e6);
                if v.marker_shown_ns >= v.marker_at_ns && v.marker_shown_ns > 0 {
                    presented.push((v.marker_shown_ns - t0) as f64 / 1e6);
                }
                to_capture.push((v.marker_capture_us as f64 * 1000.0 - t0 as f64) / 1e6);
                capture_to_decoded
                    .push((v.marker_at_ns as f64 - v.marker_capture_us as f64 * 1000.0) / 1e6);
                sample_times.push(json!({
                    "sent_ns": t0,
                    "frame": v.marker_frame,
                    "capture_us": v.marker_capture_us,
                    "first_rx_ns": v.marker_first_rx_ns,
                    "complete_ns": v.marker_complete_ns,
                    "decoded_ns": v.marker_at_ns,
                    "presented_ns": v.marker_shown_ns,
                }));
                break;
            }
            if now_ns() - t0 > 1_000_000_000 {
                lost += 1;
                stall_from.get_or_insert(t0);
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
        "input": input,
        "welcome": v.welcome,
        "first_frame_ms": first_frame_ms,
        "first_frame_times": first_frame_times,
        "stalls_ms": stalls_ms,
        "g2g_ms": pct(&mut g2g),
        "presented_ms": pct(&mut presented.clone()),
        "presented_n": presented.len(),
        "first_frame_presented_ms": first_frame_presented_ms,
        "lost": lost,
        "same_clock_input_to_capture_ms": pct(&mut to_capture),
        "same_clock_capture_to_decoded_ms": pct(&mut capture_to_decoded),
        "sample_times": sample_times,
        "frames_per_s": (v.frames - f0) as f64 / secs,
        "mbit_per_s": (v.bytes - b0) as f64 * 8.0 / secs / 1e6,
        "decode_ms": pct(&mut v.decode_ms.clone()),
        "decode_errors": v.decode_errors,
        "present_errors": v.present_errors,
        "client_cpu_pct": (cpu_s() - c0) / secs * 100.0,
        "host_stats_last": v.stats.last(),
        "upstream": upstream_report,
        "stage_ledger": v.stage_ledger(),
        "ended": v.ended,
    });
    println!("{report}");
    write_snapshot(opts, &v)?;
    let _ = v.io.send_control(&Control::Stop);
    Ok(())
}

/// The fine bucket of [`run_passive`]'s `series_100ms`.
const FINE_NS: u64 = 100_000_000;

/// `--input none --duration-s N`: sends no input and only receives for N seconds, reporting
/// the bytes, frames and newest host stats of every second against the wall clock (Unix ms),
/// so a script can cut the run into the phases a workload on the host logged on the same clock
/// (scripts/measure/screen-stream-g0.sh). `--snapshot` writes the last decoded frame.
fn run_passive(opts: &Opts, v: &mut Viewer, addr: SocketAddr, carrier: &str) -> Res<()> {
    let duration_ns = opts.num_or("duration-s", 30u64)? * 1_000_000_000;
    let start = now_ns();
    while v.decoded_frames == 0 {
        v.pump(5_000_000)?;
        if let Some(e) = &v.ended {
            return Err(format!("ended before the first frame: {e}").into());
        }
        if now_ns() - start > 15_000_000_000 {
            return Err(format!("no frame within 15 s (bytes {})", v.bytes).into());
        }
    }
    eprintln!("passive: first frame");
    // `--type TEXT`: send TEXT as one text event (the viewer's text route) once the
    // picture is up, to check a host types it as its characters (CMUX-572).
    if let Some(text) = opts.get("type") {
        v.sender.push(InputEvent::Text(text.to_owned()));
        v.send_input()?;
        eprintln!("passive: typed {} characters as text", text.chars().count());
    }
    let first_frame_ms = (now_ns().saturating_sub(start)) as f64 / 1e6;
    let unix_ms = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64)
    };
    let (c0, t_begin) = (cpu_s(), now_ns());
    let frames_start = v.frames;
    let decoded_start = v.decoded_frames;
    let marker_changes_start = v.marker_changes;
    let bytes_start = v.bytes;
    // The measured window starts after first frame. Preserve that distinction.
    if let Some(log) = v.eval_decode.as_mut() {
        log.records.clear();
        log.truncated = false;
    }
    let mut series = Vec::new();
    let (mut bytes, mut frames, mut decode_from) = (v.bytes, v.frames, v.decode_ms.len());
    let mut bucket_start = t_begin;
    let mut decoded = v.decoded_frames;
    let mut next = t_begin + 1_000_000_000;
    // Every 100 ms: [ms since the window began, bytes received in it, newest host target kbps],
    // so the time to a rate reads below the 1 s buckets (the host's stats come as often as
    // its `--stats-every-ms`).
    let mut fine = Vec::new();
    let (mut fine_bytes, mut next_fine) = (v.bytes, t_begin + FINE_NS);
    while now_ns() - t_begin < duration_ns && v.ended.is_none() {
        v.pump(next.min(next_fine).saturating_sub(now_ns()).max(1_000_000))?;
        if now_ns() >= next_fine {
            let kbps = v.stats.last().and_then(|s| s.get("kbps")).cloned();
            fine.push(json!([(now_ns() - t_begin) / 1_000_000, v.bytes - fine_bytes, kbps]));
            fine_bytes = v.bytes;
            next_fine += FINE_NS;
        }
        if now_ns() < next {
            continue;
        }
        next += 1_000_000_000;
        series.push(json!({
            "unix_ms": unix_ms(),
            "bytes": v.bytes - bytes,
            "frames": v.frames - frames,
            "decoded_frames": v.decoded_frames - decoded,
            "duration_ms": (now_ns() - bucket_start) as f64 / 1e6,
            "decode_ms": pct(&mut v.decode_ms[decode_from..].to_vec()),
            "host_stats": v.stats.last(),
        }));
        (bytes, frames, decode_from) = (v.bytes, v.frames, v.decode_ms.len());
        decoded = v.decoded_frames;
        bucket_start = now_ns();
    }
    let secs = (now_ns() - t_begin) as f64 / 1e9;
    let fps = v.frames.saturating_sub(frames_start) as f64 / secs.max(f64::EPSILON);
    let report = json!({
        "addr": addr.to_string(),
        "carrier": carrier,
        "input": "none",
        "welcome": v.welcome,
        "seconds": secs,
        "bytes": v.bytes - bytes_start,
        "decoded_frames": v.decoded_frames - decoded_start,
        "eval_clock": v.eval_decode.as_ref().map(|_| "same-host protocol monotonic microseconds"),
        "eval_begin_us": v.eval_decode.as_ref().map(|_| t_begin / 1000),
        "eval_end_us": v.eval_decode.as_ref().map(|_| now_ns() / 1000),
        "decode_records": v.eval_decode.as_ref().map(|log| &log.records),
        "decode_records_truncated": v.eval_decode.as_ref().map(|log| log.truncated),
        "quality_samples": v.eval_quality.as_ref().map(|quality| &quality.samples),
        "first_frame_ms": first_frame_ms,
        "fps": fps,
        // A host marker that counts every refresh (cmux-rd-marker --tick) changes once per
        // frame that shows something new: the fps a person sees, not the frames sent.
        "marker_changes": v.marker_changes - marker_changes_start,
        "marker_fps": (v.marker_changes - marker_changes_start) as f64 / secs.max(f64::EPSILON),
        "series": series,
        "series_100ms": fine,
        "marker_log": v.marker_log.as_ref(),
        "decode_errors": v.decode_errors,
        "present_errors": v.present_errors,
        "client_cpu_pct": (cpu_s() - c0) / secs * 100.0,
        "stage_ledger": v.stage_ledger(),
        "ended": v.ended,
    });
    println!("{report}");
    write_snapshot(opts, v)?;
    let _ = v.io.send_control(&Control::Stop);
    Ok(())
}

/// How a decoded picture of size `picture` maps onto the stream, when the host negotiated cap
/// `video.scaled` (`stream`) and sent a picture smaller than it; `None`: read it directly.
fn scale_of(stream: Option<(usize, usize)>, picture: (usize, usize)) -> Option<Scale> {
    stream.map(|stream| Scale::new(picture, stream)).filter(|scale| !scale.is_identity())
}

/// The quality region (`eval::RECT`, stream pixels) of a decoded luma plane.
fn quality_roi(scale: Option<Scale>, y: &[u8], stride: usize) -> Option<Vec<u8>> {
    match scale {
        Some(scale) => scale.luma_rect(y, stride, crate::eval::RECT),
        None => crate::eval::roi(y, stride),
    }
}

/// The marker (at `origin`, stream pixels) of a decoded luma plane.
fn read_marker(
    scale: Option<Scale>,
    y: &[u8],
    stride: usize,
    origin: (usize, usize),
) -> Option<u16> {
    match scale {
        Some(scale) => marker::decode_with(true, origin, |x, row| scale.luma(y, stride, x, row)),
        None => marker::decode_luma_at(y, stride, true, origin),
    }
}

/// `--snapshot PATH`: the newest decoded frame, so a run shows what the viewer received.
fn write_snapshot(opts: &Opts, v: &Viewer) -> Res<()> {
    #[cfg(target_os = "macos")]
    let converted = v.newest_picture.as_ref().map(crate::vtdecode::Picture::rgb);
    #[cfg(not(target_os = "macos"))]
    let converted: Option<(usize, usize, Vec<u8>)> = None;
    if let (Some(path), Some((w, h, rgb))) =
        (opts.get("snapshot"), converted.as_ref().or(v.snapshot.as_ref()))
    {
        // A smaller picture (cap `video.scaled`) is written as a viewer shows it: stream size.
        let scaled = scale_of(v.scaled_stream, (*w, *h)).map(|scale| scale.rgb(rgb));
        let (w, h, rgb) = scaled
            .as_ref()
            .map_or((*w, *h, rgb.as_slice()), |(w, h, rgb)| (*w, *h, rgb.as_slice()));
        let mut ppm = format!("P6\n{w} {h}\n255\n").into_bytes();
        ppm.extend_from_slice(rgb);
        std::fs::write(path, ppm)?;
    }
    Ok(())
}

/// `--link`: the viewer side of a device hub session, set up in JSON lines on
/// stdin and stdout the way the app does it (a test stands in for the hub):
/// prints {"key"}, reads {"session","peer_key","stun":[..],"candidates":[..]},
/// then prints {"candidate"} lines while it connects.
#[cfg(feature = "link")]
fn link_io() -> Res<ViewerIo> {
    use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
    use cmux_rd_link::{KeyPair, Role};
    use std::io::BufRead;
    #[derive(serde::Deserialize)]
    struct Answer {
        session: String,
        peer_key: String,
        #[serde(default)]
        stun: Vec<String>,
        #[serde(default)]
        candidates: Vec<String>,
    }
    let keys = KeyPair::generate()?;
    println!(
        "{}",
        json!({"key": keys.public.iter().map(|b| format!("{b:02x}")).collect::<String>()})
    );
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let answer_us = now_ns() / 1000;
    let answer: Answer = serde_json::from_str(&line).map_err(|e| format!("answer line: {e}"))?;
    let mut peer = [0u8; 32];
    if answer.peer_key.len() != 64 {
        return Err("peer_key must be 64 hex characters".into());
    }
    for (i, b) in peer.iter_mut().enumerate() {
        *b = u8::from_str_radix(&answer.peer_key[2 * i..2 * i + 2], 16)?;
    }
    let stun = answer
        .stun
        .iter()
        .filter_map(|s| std::net::ToSocketAddrs::to_socket_addrs(s).ok()?.find(SocketAddr::is_ipv4))
        .collect();
    let net = Net::start(NetConfig {
        role: Role::Initiator,
        session: answer.session.into_bytes(),
        local: keys,
        expected_remote: peer,
        stun,
        bind: "0.0.0.0:0".parse()?,
        turn: Vec::new(),
        relay_only: false,
    })?;
    // A host that dies without a close ends this viewer instead of freezing it.
    net.set_peer_lost(Some(std::time::Duration::from_micros(cmux_rd_link::PEER_LOST_US)));
    for c in answer.candidates.iter().filter_map(|c| Candidate::from_wire(c)) {
        net.add_remote_candidate(c);
    }
    let first_send_us = now_ns() / 1000;
    // This side's candidates go out through the test's stand-in hub.
    for event in net.events() {
        if let Some(line) = event.phase_line() {
            println!("{line}");
        }
        if let NetEvent::Candidate(c) = event {
            println!("{}", json!({"candidate": c.to_wire()}));
        }
    }
    Ok(ViewerIo::Link(LinkIo { net, answer_us, first_send_us, reported: false }))
}

#[cfg(all(test, feature = "link"))]
mod link_line_tests {
    use super::link_line;
    use serde_json::json;

    #[test]
    fn an_established_link_reports_its_three_times() {
        assert_eq!(
            link_line(100, 150, 900, None),
            json!({"link": {"answer_us": 100, "first_send_us": 150, "established_us": 900}})
        );
    }

    #[test]
    fn a_failed_link_still_reports_when_it_sent_and_why_it_failed() {
        let reason = "the secure handshake timed out (local host 3; heard 0)";
        assert_eq!(
            link_line(100, 150, 10_150, Some(reason)),
            json!({"link": {"answer_us": 100, "first_send_us": 150, "failed_us": 10_150, "failed": reason}})
        );
    }
}

#[cfg(test)]
mod h264_baseline_cap_tests {
    /// The bench asks for Constrained Baseline exactly when it decodes with OpenH264.
    #[test]
    fn offers_the_cap_when_openh264_decodes() {
        assert_eq!(super::bench_decodes_with_openh264(None), !cfg!(target_os = "macos"));
        assert!(super::bench_decodes_with_openh264(Some("openh264")));
        assert!(!super::bench_decodes_with_openh264(Some("videotoolbox")));
        assert!(!super::bench_decodes_with_openh264(Some("vp9")));
    }
}
