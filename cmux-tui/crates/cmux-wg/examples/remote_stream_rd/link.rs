//! `--path rd-link`: the desktop stream as Cloud desktop media sends it on
//! the datagram path (cmuxterm-hq#7976), on real UDP sockets through the
//! bench's lossy link.
//!
//! - Host: `cmux_rd_engine::MediaEngine`, the engine every rd source runs
//!   (frame gate, packetizer with adaptive Reed-Solomon FEC, NACK history,
//!   recovery keyframes, exactly-once input), configured as the link host
//!   (`cmux-rd-host` `serve.rs`) configures it: 1126-byte datagrams and
//!   enough frames in flight to cover the round trip, at least two. The
//!   "encoder" returns an access unit of the bench's frame size (the
//!   keyframe size for every IDR, recovery keyframes too).
//! - Viewer: the Mac viewer's Rust, `cmux-rd-ffi`'s `Receiver` (reassembly,
//!   NACKs, feedback; 200 ms deadline, NACK after 5 ms) and `InputChannel`
//!   (input repeated until acknowledged, every 20 ms), compiled in from
//!   their source files.
//! - Between them: one `cmux_rd_link::Endpoint` per side (Noise_XX, sealed
//!   datagrams, replay window, path probes) over one UDP socket each.
//!   Frames, parity and resends go host to viewer; input and feedback
//!   (arrivals, acks, NACKs) go viewer to host, all as sealed datagrams.
//!
//! An input event carries its send time in the pointer's `x`, so the host
//! measures input delay when the engine injects it, and stamps the first
//! frame it encodes after that, as the stream paths do.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output};
use cmux_rd_link::{Endpoint, EndpointEvent, Event, KeyPair, LinkError, Role, Route, Transmit};
use cmux_rd_proto::{DatagramHeader, DatagramKind, InputEvent};
use cmux_wg::PathKind;
use tokio::net::UdpSocket;
use tokio::time::{Instant, sleep_until};

use crate::input::InputChannel;
use crate::receiver::{Carrier, Receiver};
use crate::{
    Args, Clock, HEADER, INPUT_INTERVAL, KIND_FRAME, LATE, Shared, header, impair, lock,
    next_tick, parse_header,
};

/// The link host's datagram size (`cmux-rd-host` `serve.rs` `MAX_DATAGRAM`):
/// a sealed packet fits the 1152-byte VPC budget.
pub const MAX_DATAGRAM: usize = cmux_rd_proto::MAX_DATAGRAM_VPC - cmux_rd_link::SEAL_OVERHEAD;
/// The Noise prologue both ends share (the hub's session id in a real session).
const SESSION: &[u8] = b"remote-stream-bench";
/// The Mac viewer's NACK delay (`RemoteRdSession` `nackAfterMicros`).
const NACK_AFTER_US: u64 = 5_000;
/// The Mac viewer's input resend interval (`RemoteRdInput` `resendMicros`).
const INPUT_RESEND_US: u64 = 20_000;
/// The surface size the engine is told; damage covers a small region of it.
const WIDTH: u32 = 1920;
const HEIGHT: u32 = 1080;
/// How long both ends keep running after the last frame, for resends.
const DRAIN: Duration = Duration::from_secs(1);

fn link_error(error: LinkError) -> io::Error {
    io::Error::other(error.to_string())
}

/// An input event that carries its send time (bench clock, microseconds)
/// and sequence: a pointer move to (`sent_us`, `seq`).
pub fn input_event(sent_us: u64, seq: u32) -> InputEvent {
    // 2^31 us is 35 minutes, far beyond a bench run.
    let x = i32::try_from(sent_us & 0x7fff_ffff).unwrap_or(i32::MAX);
    InputEvent::Pointer { x, y: i32::try_from(seq & 0x7fff_ffff).unwrap_or(i32::MAX) }
}

/// The send time an [`input_event`] carries.
pub fn input_sent_us(event: &InputEvent) -> Option<u64> {
    match event {
        InputEvent::Pointer { x, .. } => u64::try_from(*x).ok(),
        _ => None,
    }
}

/// One bench frame as the encoder's access unit: the stream paths' header,
/// then filler to `size` payload bytes.
pub fn access_unit(seq: u32, sent_us: u64, echo_us: u64, size: usize) -> Vec<u8> {
    let mut unit = Vec::with_capacity(HEADER + size);
    unit.extend_from_slice(&header(KIND_FRAME, seq, sent_us, echo_us));
    unit.resize(HEADER + size, 0x5a);
    unit
}

/// Frames in flight for the engine: `--rd-frames-in-flight`, else the link
/// host's rule (cover the round trip, at least two).
pub fn frames_in_flight(args: &Args) -> u32 {
    if args.rd_frames_in_flight > 0 {
        return args.rd_frames_in_flight;
    }
    let rtt_us = args.rtt_ms * 1000;
    if rtt_us == 0 {
        2
    } else {
        cmux_rd_engine::frames_in_flight_for(rtt_us, args.fps).max(2)
    }
}

/// What the host sent, for the note.
#[derive(Default)]
struct HostCounts {
    /// Frame shards that went out again on a NACK.
    resent: u64,
    /// Parity shards sent with frames.
    parity: u64,
    /// Data shards sent with frames.
    data: u64,
    keyframes: u64,
    loss: f64,
    target_kbps: u64,
}

/// What the viewer saw, for the note.
#[derive(Default)]
struct ViewerCounts {
    released: u64,
    lost: u64,
}

/// One side's socket and endpoint.
struct Side {
    socket: UdpSocket,
    endpoint: Endpoint,
}

impl Side {
    async fn send(&self, transmits: Vec<Transmit>) {
        for transmit in transmits {
            if let Route::Udp(address) = transmit.route {
                let _ = self.socket.send_to(&transmit.packet, address).await;
            }
        }
    }

    async fn send_datagram(&mut self, datagram: &[u8]) {
        if let Ok(transmits) = self.endpoint.send_datagram(datagram) {
            self.send(transmits).await;
        }
    }

    async fn flush(&mut self, now_us: u64) -> io::Result<()> {
        let transmits = self.endpoint.poll_transmit(now_us).map_err(link_error)?;
        self.send(transmits).await;
        Ok(())
    }
}

fn at(clock: &Clock, us: u64) -> Instant {
    clock.0 + Duration::from_micros(us)
}

fn kind_of(datagram: &[u8]) -> Option<DatagramKind> {
    DatagramHeader::decode(datagram).ok().map(|(header, _)| header.kind)
}

/// The host: the media engine behind its endpoint. Frames start when the
/// handshake finishes and stop at `end`; resends go on for [`DRAIN`].
struct Host {
    side: Side,
    engine: Option<MediaEngine>,
    config: EngineConfig,
    args: Args,
    clock: Arc<Clock>,
    record: Shared,
    end: Instant,
    pending_echo: u64,
    seq: u32,
    counts: HostCounts,
}

impl Host {
    async fn run(mut self) -> io::Result<HostCounts> {
        let interval = Duration::from_secs(1) / self.args.fps.max(1);
        let stop = self.end + DRAIN;
        let mut next_damage: Option<Instant> = None;
        let mut buf = vec![0u8; 65_535];
        loop {
            let deadline = [
                self.side.endpoint.next_deadline_us(),
                self.engine.as_ref().and_then(MediaEngine::next_deadline_us),
            ]
            .into_iter()
            .flatten()
            .min()
            .map_or(stop, |us| at(&self.clock, us));
            let wake = next_damage.map_or(deadline, |d| d.min(deadline)).min(stop);
            tokio::select! {
                got = self.side.socket.recv_from(&mut buf) => {
                    let (n, source) = got?;
                    let now = self.clock.us();
                    let events = match self.side.endpoint.on_packet(Route::Udp(source), &buf[..n], now) {
                        Ok(events) => events,
                        Err(_) => Vec::new(),
                    };
                    for event in events {
                        match event {
                            EndpointEvent::Link(Event::Established) if self.engine.is_none() => {
                                let mut engine = MediaEngine::new(self.config, now);
                                let request = engine.start(now);
                                self.engine = Some(engine);
                                self.encode(request).await;
                                next_damage = Some(Instant::now() + interval);
                            }
                            EndpointEvent::Link(Event::Datagram(datagram)) => {
                                let Some(engine) = self.engine.as_mut() else { continue };
                                let out = engine.on_datagram(&datagram, true, now);
                                self.output(out).await;
                            }
                            _ => {}
                        }
                    }
                }
                () = sleep_until(wake) => {}
            }
            if Instant::now() >= stop {
                break;
            }
            let now = self.clock.us();
            if let Some(engine) = self.engine.as_mut() {
                let mut requests = Vec::new();
                if let Some(due) = next_damage
                    && due <= Instant::now()
                {
                    let damage = Rect { x: 0, y: 0, width: 256, height: 64 };
                    requests.extend(engine.damage(0, damage, now));
                    next_damage = Some(next_tick(due, interval)).filter(|next| *next < self.end);
                }
                requests.extend(engine.poll(now));
                let out = engine.tick(true, now);
                for request in requests {
                    self.encode(Some(request)).await;
                }
                self.output(out).await;
            }
            self.side.flush(now).await?;
        }
        if let Some(engine) = &self.engine {
            let stats = engine.stats();
            self.counts.keyframes = stats.keyframes;
            self.counts.loss = stats.loss;
            self.counts.target_kbps = stats.target_bps / 1000;
        }
        Ok(self.counts)
    }

    /// Sends what the engine answered: resends and input acks, injected
    /// input (timed here), and a frame it asks for.
    async fn output(&mut self, out: Output) {
        for datagram in &out.datagrams {
            if matches!(kind_of(datagram), Some(DatagramKind::Video | DatagramKind::Fec)) {
                self.counts.resent += 1;
            }
            self.side.send_datagram(datagram).await;
        }
        let now = self.clock.us();
        for event in &out.inject {
            let Some(sent) = input_sent_us(event) else { continue };
            lock(&self.record).input_us.push(now.saturating_sub(sent));
            if self.pending_echo == 0 {
                self.pending_echo = sent;
            }
        }
        if out.encode.is_some() {
            self.encode(out.encode).await;
        }
    }

    /// "Encodes" the frame the engine asked for and sends its datagrams.
    async fn encode(&mut self, request: Option<EncodeRequest>) {
        let Some(request) = request else { return };
        let Some(engine) = self.engine.as_mut() else { return };
        let now = self.clock.us();
        if Instant::now() >= self.end {
            // Past the run: no new frames, and the gate opens again.
            let _ = engine.encoded(&request, None, now);
            return;
        }
        let size =
            if request.force_idr { self.args.keyframe_bytes } else { self.args.frame_bytes };
        let echo = std::mem::take(&mut self.pending_echo);
        let encoded = Encoded {
            access_unit: access_unit(self.seq, now, echo, size),
            idr: request.force_idr,
            t_capture_us: now,
        };
        let Ok(out) = engine.encoded(&request, Some(encoded), now) else { return };
        if !out.datagrams.is_empty() {
            self.seq += 1;
            lock(&self.record).frames_sent += 1;
        }
        for datagram in &out.datagrams {
            match kind_of(datagram) {
                Some(DatagramKind::Fec) => self.counts.parity += 1,
                Some(DatagramKind::Video) => self.counts.data += 1,
                _ => {}
            }
            self.side.send_datagram(datagram).await;
        }
    }
}

/// The viewer: an input every 20 ms from the start (queued until the
/// handshake finishes), every released frame timed on arrival.
struct Viewer {
    side: Side,
    clock: Arc<Clock>,
    record: Shared,
    end: Instant,
    deadline_us: u64,
}

impl Viewer {
    async fn run(mut self) -> io::Result<ViewerCounts> {
        let mut receiver = Receiver::new(Carrier::Datagram, self.deadline_us, NACK_AFTER_US);
        let mut input = InputChannel::new(Carrier::Datagram, INPUT_RESEND_US);
        let mut established = false;
        let mut next_input = Instant::now() + INPUT_INTERVAL;
        let mut input_seq = 0u32;
        let stop = self.end + DRAIN;
        let mut buf = vec![0u8; 65_535];
        loop {
            let session = established
                .then(|| [Some(receiver.next_deadline_us()), input.next_deadline_us()])
                .into_iter()
                .flatten();
            let deadline = std::iter::once(self.side.endpoint.next_deadline_us())
                .chain(session)
                .flatten()
                .min()
                .map_or(stop, |us| at(&self.clock, us));
            let mut wake = deadline.min(stop);
            if next_input < self.end {
                wake = wake.min(next_input);
            }
            tokio::select! {
                got = self.side.socket.recv_from(&mut buf) => {
                    let (n, source) = got?;
                    let now = self.clock.us();
                    let events = match self.side.endpoint.on_packet(Route::Udp(source), &buf[..n], now) {
                        Ok(events) => events,
                        Err(_) => Vec::new(),
                    };
                    for event in events {
                        match event {
                            EndpointEvent::Link(Event::Established) => established = true,
                            EndpointEvent::Link(Event::Datagram(datagram)) => {
                                match kind_of(&datagram) {
                                    Some(DatagramKind::InputAck) => {
                                        let _ = input.on_ack(&datagram);
                                    }
                                    Some(DatagramKind::Video | DatagramKind::Fec) => {
                                        let _ = receiver.push_datagram(&datagram, now);
                                    }
                                    _ => {}
                                }
                            }
                            _ => {}
                        }
                    }
                }
                () = sleep_until(wake) => {}
            }
            if Instant::now() >= stop {
                break;
            }
            let now = self.clock.us();
            if next_input <= Instant::now() && next_input < self.end {
                input.push(input_event(now, input_seq));
                lock(&self.record).inputs_sent += 1;
                input_seq += 1;
                next_input = next_tick(next_input, INPUT_INTERVAL);
            }
            if established {
                receiver.tick(now);
                while let Some(frame) = receiver.pop_frame() {
                    self.on_frame(&frame.body.access_unit);
                }
                while let Some(feedback) = receiver.feedback(now) {
                    self.side.send_datagram(&feedback).await;
                }
                while let Some(packet) = input.packet(now) {
                    self.side.send_datagram(&packet).await;
                }
            }
            self.side.flush(now).await?;
        }
        let stats = receiver.stats();
        Ok(ViewerCounts { released: stats.frames_released, lost: stats.frames_lost })
    }

    /// Times one released frame, as the stream paths' viewer does.
    fn on_frame(&self, unit: &[u8]) {
        let now = self.clock.us();
        let (_, seq, sent, echo) = parse_header(unit);
        let mut record = lock(&self.record);
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
}

/// `--path rd-link`: host and viewer over the rd link, through the bench's
/// in-process link when `--rtt-ms` or `--loss-pct` is set.
pub async fn run(args: &Args, clock: Arc<Clock>, record: Shared) -> io::Result<()> {
    let host_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let viewer_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let host_address = host_socket.local_addr()?;
    let shaped = args.rtt_ms > 0 || args.loss_pct > 0.0;
    let dial =
        if shaped { impair(host_address, args.rtt_ms, args.loss_pct).await? } else { host_address };
    let (host_keys, viewer_keys) =
        (KeyPair::generate().map_err(link_error)?, KeyPair::generate().map_err(link_error)?);
    let now = clock.us();
    let mut viewer_endpoint =
        Endpoint::new(Role::Initiator, SESSION, &viewer_keys, host_keys.public, now)
            .map_err(link_error)?;
    // The viewer knows the host's candidate from signaling; the host learns
    // the viewer's route from its handshake.
    viewer_endpoint.add_path(Route::Udp(dial), PathKind::DirectWan, now);
    let host_endpoint = Endpoint::new(Role::Responder, SESSION, &host_keys, viewer_keys.public, now)
        .map_err(link_error)?;
    let in_flight = frames_in_flight(args);
    let config = EngineConfig {
        width: WIDTH,
        height: HEIGHT,
        max_fps: args.fps.max(1),
        max_datagram: MAX_DATAGRAM,
        frames_in_flight: in_flight,
        ..EngineConfig::default()
    };
    let end = Instant::now() + Duration::from_secs(args.seconds);
    let host = Host {
        side: Side { socket: host_socket, endpoint: host_endpoint },
        engine: None,
        config,
        args: args.clone(),
        clock: clock.clone(),
        record: record.clone(),
        end,
        pending_echo: 0,
        seq: 0,
        counts: HostCounts::default(),
    };
    let viewer = Viewer {
        side: Side { socket: viewer_socket, endpoint: viewer_endpoint },
        clock,
        record: record.clone(),
        end,
        deadline_us: args.rd_deadline_ms * 1000,
    };
    let (host, viewer) = tokio::join!(host.run(), viewer.run());
    let (host, viewer) = (host?, viewer?);
    lock(&record).note = format!(
        "rd-link: frames in flight {in_flight}, deadline {} ms; host data {} parity {} resent {} keyframes {} loss {:.3} target {} kbps; viewer released {} lost {}",
        args.rd_deadline_ms,
        host.data,
        host.parity,
        host.resent,
        host.keyframes,
        host.loss,
        host.target_kbps,
        viewer.released,
        viewer.lost,
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_event_round_trips_its_send_time() {
        let event = input_event(12_345_678, 7);
        assert_eq!(input_sent_us(&event), Some(12_345_678));
        assert_eq!(input_sent_us(&InputEvent::Key { usage: 4, down: true }), None);
    }

    #[test]
    fn access_unit_carries_the_stream_header() {
        let unit = access_unit(3, 1_000, 900, 100);
        assert_eq!(unit.len(), HEADER + 100);
        assert_eq!(parse_header(&unit), (KIND_FRAME, 3, 1_000, 900));
    }

    #[test]
    fn frames_in_flight_follow_the_link_host() {
        let mut args = crate::args_from(Vec::new());
        assert_eq!(frames_in_flight(&args), 2);
        args.rtt_ms = 100;
        assert_eq!(frames_in_flight(&args), 6);
        args.rtt_ms = 30;
        assert_eq!(frames_in_flight(&args), 3);
        args.rd_frames_in_flight = 9;
        assert_eq!(frames_in_flight(&args), 9);
    }

    /// The whole path on a lossy link: frames still arrive (FEC and NACKs
    /// repair them), and input reaches the host and comes back as photons.
    #[tokio::test(flavor = "multi_thread")]
    async fn frames_and_input_cross_a_lossy_link() {
        let mut args = crate::args_from(Vec::new());
        args.path = "rd-link".into();
        args.seconds = 2;
        args.rtt_ms = 20;
        args.loss_pct = 3.0;
        let clock = Arc::new(Clock(Instant::now()));
        let record: Shared = Arc::default();
        run(&args, clock, record.clone()).await.unwrap();
        let record = lock(&record);
        assert!(record.first_frame_us.is_some(), "the keyframe arrived");
        // 2 s at 60 fps is 120 frames; at 3 % loss nearly all must arrive.
        assert!(record.frame_us.len() >= 90, "{} frames", record.frame_us.len());
        assert!(record.input_us.len() >= 50, "{} inputs", record.input_us.len());
        assert!(!record.photon_us.is_empty());
        assert!(record.note.contains("resent") && record.note.contains("parity"));
    }
}
